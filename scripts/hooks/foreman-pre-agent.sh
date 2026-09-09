#!/bin/sh
# PreToolUse hook, matcher Agent. Fences the foreman's dispatches.
#
# Only acts when the call comes from inside the foreman (agent_type matches
# ^(orchestrate:)?foreman$). Main-session and other agents' Agent calls are
# never touched. Denies the call (permissionDecision deny) when: no checkpoint
# exists under the git toplevel; dispatchMode is DIRECT; nextAction is
# complete; the dispatch cap is reached; or the checkpoint mtime is older than
# 20 minutes (refreshing it is the orchestrator's duty: `orchestrate handoff
# --to foreman` before a spawn, `orchestrate stall record` before a resume;
# a foreman denied as stale pauses and ends with the STATE line). Otherwise
# allows silently.
#
# Fail silent: any error exits 0 with no output. Never writes into the repo.

set +e
trap 'exit 0' EXIT

STALE_SECONDS=1200

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

# Cheap gate before touching git: only foreman calls matter.
IS_FOREMAN=$(printf '%s' "$INPUT" | python3 -c 'import json,re,sys
try:
    d = json.load(sys.stdin)
    t = d.get("agent_type")
    tool = d.get("tool_name")
    ok = t is not None and re.match(r"^(orchestrate:)?foreman$", str(t)) is not None
    ok = ok and (tool is None or tool == "Agent")
    print("1" if ok else "0")
except Exception:
    print("0")' 2>/dev/null)
[ "$IS_FOREMAN" = "1" ] || exit 0

CWD=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("cwd") or "")
except Exception:
    print("")' 2>/dev/null)
[ -n "$CWD" ] || CWD="${CLAUDE_PROJECT_DIR:-$PWD}"

find_checkpoint "$CWD"

PY=$(cat 2>/dev/null <<'PY_EOF'
import json, os, sys, time

ckpt = os.environ.get("HOOK_CKPT", "")
top = os.environ.get("HOOK_TOP", "") or os.getcwd()
stale_after = float(os.environ.get("HOOK_STALE_SECONDS", "1200"))

def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason}}))
    sys.exit(0)

if not ckpt:
    deny("orchestrate: no run archive under " + top + " (no .claude/orchestrate-runs/*/checkpoint.json): "
         "the orchestrator must run `orchestrate init`; you are not allowed to dispatch. Report and stop.")

with open(ckpt) as fh:
    cp = json.load(fh)

owner = cp.get("owner") or {}
if str(cp.get("dispatchMode", "")) == "DIRECT":
    deny("orchestrate: dispatchMode is DIRECT: ownership moved to the orchestrator (epoch "
         + str(owner.get("epoch", "")) + "); stop and report.")

next_action = str(cp.get("nextAction", ""))
if next_action == "complete":
    deny("orchestrate: checkpoint " + ckpt + " has nextAction=complete: the run is done; no dispatch is authorized. "
         "End with the STATE line.")

tally = cp.get("dispatchTally") or {}
used = int(tally.get("used", 0) or 0)
cap = int(tally.get("cap", 0) or 0)
if cap > 0 and used >= cap:
    deny("orchestrate: cap reached (tally " + str(used) + "/" + str(cap) + "): surface. "
         "Run `orchestrate pause --reason <text>` and end with the STATE line.")

age = time.time() - os.path.getmtime(ckpt)
if age > stale_after:
    deny("orchestrate: checkpoint stale (" + str(int(age // 60)) + " min since the last write, limit "
         + str(int(stale_after // 60)) + "): the orchestrator must refresh it before spawning or resuming you "
         "(`orchestrate handoff --to foreman` before a spawn, `orchestrate stall record` before a resume). "
         "Do not touch the lease: run `orchestrate pause --reason \"stale checkpoint at probe; orchestrator must "
         "refresh and resume\"` and end with the STATE line.")

# Allow silently.
PY_EOF
)

OUT=$(HOOK_CKPT="$CKPT" HOOK_TOP="$TOP" HOOK_STALE_SECONDS="$STALE_SECONDS" python3 -c "$PY" 2>/dev/null </dev/null) || exit 0
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
