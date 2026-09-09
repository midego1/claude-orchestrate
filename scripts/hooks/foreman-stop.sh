#!/bin/sh
# SubagentStop hook for the foreman (matcher ^(orchestrate:)?foreman$).
#
# Reads the newest run checkpoint. The stop is legitimate (exit 0, no output)
# when nextAction is `ship-gate` or `complete` or starts with `paused:`, when
# dispatchMode is DIRECT, or when owner.agentId is neither `foreman` nor empty
# (the run belongs to the orchestrator; the foreman stopping is correct).
# Otherwise, the first time (stop_hook_active false) block with a reason; when
# already continuing because of a stop hook (stop_hook_active true) allow the
# stop and warn the user with a systemMessage naming the take-over command
# `orchestrate lease take --agent orchestrator --expect <owner.epoch>`.
# Never blocks twice in a row.
#
# Fail silent: any error exits 0 with no output. Never writes into the repo.

set +e
trap 'exit 0' EXIT

if [ -t 0 ]; then INPUT=""; else INPUT=$(cat 2>/dev/null); fi

# find_checkpoint <cwd>: sets TOP (git toplevel of <cwd>) and CKPT (newest
# <toplevel>/.claude/orchestrate-runs/*/checkpoint.json by mtime, or empty).
find_checkpoint() {
  TOP=""; CKPT=""
  TOP=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || TOP=""
  [ -n "$TOP" ] || return 0
  CKPT=$(python3 - "$TOP" 2>/dev/null <<'PY_EOF'
import glob, os, sys
top = sys.argv[1]
paths = [p for p in glob.glob(os.path.join(top, ".claude", "orchestrate-runs", "*", "checkpoint.json")) if os.path.isfile(p)]
if paths:
    print(max(paths, key=os.path.getmtime))
PY_EOF
) || CKPT=""
}

CWD=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("cwd") or "")
except Exception:
    print("")' 2>/dev/null)
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

find_checkpoint "$CWD"
[ -n "$CKPT" ] || exit 0

PY=$(cat 2>/dev/null <<'PY_EOF'
import json, os, re, sys

raw = sys.stdin.read()
data = json.loads(raw) if raw.strip() else {}
agent_type = data.get("agent_type")
if agent_type is not None and not re.match(r"^(orchestrate:)?foreman$", str(agent_type)):
    sys.exit(0)

ckpt = os.environ.get("HOOK_CKPT", "")
with open(ckpt) as fh:
    cp = json.load(fh)

next_action = str(cp.get("nextAction", ""))
if next_action in ("complete", "ship-gate") or next_action.startswith("paused:"):
    sys.exit(0)

# Ownership: only a foreman-owned FOREMAN-mode run is guarded. After a
# take-over (dispatchMode DIRECT, owner.agentId orchestrator) the foreman is
# expected to stop and report without touching the lease.
owner = cp.get("owner") or {}
if str(cp.get("dispatchMode", "")) == "DIRECT":
    sys.exit(0)
if str(owner.get("agentId") or "") not in ("foreman", ""):
    sys.exit(0)

tally = cp.get("dispatchTally") or {}
used = tally.get("used", 0)
cap = tally.get("cap", 0)
run_id = str(cp.get("runId", ""))
take_over = "orchestrate lease take --agent orchestrator --expect " + str(owner.get("epoch", ""))

if not bool(data.get("stop_hook_active", False)):
    reason = (
        "orchestrate: checkpoint " + ckpt + " has nextAction=" + next_action
        + ", tally " + str(used) + "/" + str(cap) + "; authorized work remains. "
        "Either continue the loop (dispatch open -> Agent -> dispatch close) or, if you are genuinely "
        "blocked or winding down, run `orchestrate pause --reason <text>` (sets nextAction to paused: ...) "
        "and end with the STATE line. Do not touch the lease: only the orchestrator takes over "
        "(`" + take_over + "`)."
    )
    print(json.dumps({"decision": "block", "reason": reason}))
else:
    msg = (
        "orchestrate: foreman stopped with work left (run " + run_id + ", nextAction=" + next_action
        + ", tally " + str(used) + "/" + str(cap) + "): the orchestrator must resume it or take over "
        "(`" + take_over + "`)"
    )
    print(json.dumps({"systemMessage": msg}))
PY_EOF
)

OUT=$(printf '%s' "$INPUT" | HOOK_CKPT="$CKPT" python3 -c "$PY" 2>/dev/null) || exit 0
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
