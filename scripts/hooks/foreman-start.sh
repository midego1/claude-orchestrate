#!/bin/sh
# SubagentStart hook for the foreman (matcher ^(orchestrate:)?foreman$).
#
# Injects the newest run checkpoint's coordinates, the quoted plugin root
# (`orchestrate` in the injected text means "<plugin root>/bin/orchestrate")
# and the mandatory first actions (preflight, Agent probe, `harness set
# dispatch foreground|background`) into the foreman's context before its
# first prompt.
# Output: {"hookSpecificOutput":{"hookEventName":"SubagentStart","additionalContext":"..."}}
#
# Fail silent: any error exits 0 with no output. Never writes into the repo.

set +e
trap 'exit 0' EXIT

if [ -t 0 ]; then INPUT=""; else INPUT=$(cat 2>/dev/null); fi

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ]; then
  PLUGIN_ROOT=$(cd "$(dirname "$0" 2>/dev/null)/../.." 2>/dev/null && pwd 2>/dev/null)
fi

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

PY=$(cat 2>/dev/null <<'PY_EOF'
import json, os, re, sys

raw = sys.stdin.read()
data = json.loads(raw) if raw.strip() else {}
agent_type = data.get("agent_type")
if agent_type is not None and not re.match(r"^(orchestrate:)?foreman$", str(agent_type)):
    sys.exit(0)

ckpt = os.environ.get("HOOK_CKPT", "")
top = os.environ.get("HOOK_TOP", "") or data.get("cwd", "") or os.getcwd()
plugin = os.environ.get("HOOK_PLUGIN_ROOT", "") or "<plugin root>"
# Paths may contain spaces or apostrophes: the path is always double-quoted
# inside the backticks so the command can be pasted into a shell verbatim.
cli = '"' + plugin + '/bin/orchestrate"'

actions = (
    "Plugin root: " + plugin + " (quote it in every command; `orchestrate` below means `" + cli + "`). "
    "Mandatory first actions after reading this context (`orchestrate status` is the on-disk equivalent), in this order: "
    "(1) run `" + cli + " preflight` and record its verdict; "
    "(2) make the Agent probe: one Agent call (model haiku, prompt \"reply OK\", run_in_background: false); "
    "if the PreToolUse hook denies it as a stale checkpoint, do not touch the lease: run "
    "`orchestrate pause --reason \"stale checkpoint at probe; orchestrator must refresh and resume\"` and end with the STATE line; "
    "(3) record the probe result before anything else: `orchestrate harness set dispatch foreground` "
    "when the tool result carries the child's text inline, `orchestrate harness set dispatch background` "
    "when it says the agent was launched in the background or that you will be notified. "
    "Foreground: proceed with the loop. Background: do not run the loop, become the planner (degraded DIRECT mode) "
    "and report the verbatim probe result."
)

if not ckpt:
    ctx = (
        "orchestrate: no run archive under " + top + " (no .claude/orchestrate-runs/*/checkpoint.json): "
        "the orchestrator must run `orchestrate init` and `plan set` before you dispatch; do not init yourself; "
        "report and stop with STATE: ... STOPPED-AWAITING-RESUME."
    )
else:
    with open(ckpt) as fh:
        cp = json.load(fh)
    tally = cp.get("dispatchTally") or {}
    owner = cp.get("owner") or {}
    harness = cp.get("harness") or {}
    ctx = (
        "orchestrate: run archive found. checkpoint=" + ckpt
        + "; runId=" + str(cp.get("runId", ""))
        + "; nextAction=" + str(cp.get("nextAction", ""))
        + "; owner.epoch=" + str(owner.get("epoch", ""))
        + "; dispatchMode=" + str(cp.get("dispatchMode", ""))
        + "; dispatchTally=" + str(tally.get("used", 0)) + "/" + str(tally.get("cap", 0))
        + " (" + str(tally.get("capSource", "")) + ")"
        + "; harness.dispatch=" + str(harness.get("dispatch", "unknown"))
        + ". " + actions
    )

print(json.dumps({"hookSpecificOutput": {"hookEventName": "SubagentStart", "additionalContext": ctx}}))
PY_EOF
)

OUT=$(printf '%s' "$INPUT" | HOOK_CKPT="$CKPT" HOOK_TOP="$TOP" HOOK_PLUGIN_ROOT="$PLUGIN_ROOT" python3 -c "$PY" 2>/dev/null) || exit 0
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
