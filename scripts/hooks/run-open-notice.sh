#!/bin/sh
# Stop hook for the main session. Informational only, never blocks. Fires only
# when the main agent finishes a turn: it does not fire on a user interrupt
# (Ctrl+C) and API errors fire StopFailure instead, so an interrupted run gets
# no notice; `orchestrate status` is the fallback.
#
# If the newest run checkpoint under the git toplevel has a nextAction that is
# none of `ship-gate`, `complete` or `paused: ...` (the legitimate stops) and
# was written less than 6 hours ago, emit a systemMessage telling the user the
# run is still open.
#
# Fail silent: any error exits 0 with no output. Never writes into the repo.

set +e
trap 'exit 0' EXIT

RECENT_SECONDS=21600

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
import json, os, sys, time

raw = sys.stdin.read()
data = json.loads(raw) if raw.strip() else {}
ckpt = os.environ.get("HOOK_CKPT", "")
recent = float(os.environ.get("HOOK_RECENT_SECONDS", "21600"))

with open(ckpt) as fh:
    cp = json.load(fh)

next_action = str(cp.get("nextAction", ""))
if next_action in ("complete", "ship-gate") or next_action.startswith("paused:"):
    sys.exit(0)

age = time.time() - os.path.getmtime(ckpt)
if age >= recent:
    sys.exit(0)

tally = cp.get("dispatchTally") or {}
bg = data.get("background_tasks")
bg_count = str(len(bg)) if isinstance(bg, list) else "unknown"
msg = (
    "orchestrate: run " + str(cp.get("runId", "")) + " is open (nextAction=" + next_action
    + ", tally " + str(tally.get("used", 0)) + "/" + str(tally.get("cap", 0))
    + ", last checkpoint write " + str(int(age // 60)) + " min ago; background tasks in flight: " + bg_count + ")"
)
print(json.dumps({"systemMessage": msg}))
PY_EOF
)

OUT=$(printf '%s' "$INPUT" | HOOK_CKPT="$CKPT" HOOK_RECENT_SECONDS="$RECENT_SECONDS" python3 -c "$PY" 2>/dev/null) || exit 0
[ -n "$OUT" ] && printf '%s\n' "$OUT"
exit 0
