#!/bin/sh
# Harness preflight for the orchestrate plugin (called by `bin/orchestrate preflight`).
#
# Prints ONE JSON object on stdout: the checkpoint `harness` object
# (claudeCodeVersion, dispatch, backgroundTasksDisabled, forkModeDisabled,
# spawnDepth, subagentModelForce, foremanAllowed, checkedAt) plus
# "verdict" and "reasons". One human-readable verdict line goes to stderr
# unless --json is given.
#
# Sources, in precedence order: the process environment, then the "env"
# blocks of <root>/.claude/settings.local.json, <root>/.claude/settings.json
# and ~/.claude/settings.json. <root> is --root, else the git toplevel of the
# current directory, else the current directory.
#
# Verdicts and exit codes:
#   foreman-allowed         exit 0  a foreground flag is set, spawn depth >= 2, no model-force
#   foreman-probe-required  exit 0  no foreground flag set; the foreman's Agent probe decides
#   foreman-refused         exit 2  spawn depth < 2 (direct mode still allowed) or
#                                   CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 (nothing allowed)
#
# Spawn depth: CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH defaults to 3, except on
# Claude Code 2.1.217 and 2.1.218 where the harness default is 1; when the
# variable is unset (or unparsable) on those versions the preflight assumes 1
# and refuses the foreman layer.
#   error                   exit 1
#
# Never writes into the repo.

set +e

ROOT=""
JSON_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --root=*) ROOT="${1#--root=}"; shift ;;
    --json) JSON_ONLY=1; shift ;;
    *) shift ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null) || ROOT=""
fi
[ -n "$ROOT" ] || ROOT="$PWD"

# `claude --version` prints e.g. "2.1.260 (Claude Code)". Missing binary -> "unknown".
VERSION_RAW=""
if command -v claude >/dev/null 2>&1; then
  VERSION_RAW=$(claude --version 2>/dev/null </dev/null | head -1)
fi

PY=$(cat 2>/dev/null <<'PY_EOF'
import datetime, json, os, re, sys

root = os.environ.get("PREFLIGHT_ROOT", "") or os.getcwd()
json_only = os.environ.get("PREFLIGHT_JSON_ONLY", "0") == "1"
raw_version = os.environ.get("PREFLIGHT_VERSION_RAW", "")

m = re.search(r"(\d+)\.(\d+)\.(\d+)", raw_version or "")
version = m.group(0) if m else "unknown"
version_tuple = tuple(int(x) for x in m.groups()) if m else None

NAMES = [
    "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS",
    "CLAUDE_CODE_FORK_SUBAGENT",
    "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH",
    "CLAUDE_CODE_SUBAGENT_MODEL_FORCE",
]

# Layered sources: first hit wins.
sources = [("env", dict(os.environ))]
home = os.path.expanduser("~")
for label in (
    os.path.join(root, ".claude", "settings.local.json"),
    os.path.join(root, ".claude", "settings.json"),
    os.path.join(home, ".claude", "settings.json"),
):
    try:
        with open(label) as fh:
            doc = json.load(fh)
        env_block = doc.get("env") if isinstance(doc, dict) else None
        if isinstance(env_block, dict):
            sources.append((label, {str(k): str(v) for k, v in env_block.items()}))
    except Exception:
        continue

def lookup(name):
    for label, table in sources:
        if name in table:
            return str(table[name]), label
    return None, None

def flag(name, value):
    v, src = lookup(name)
    return (v is not None and v.strip() == value), v, src

reasons = []

bg_disabled, _, bg_src = flag("CLAUDE_CODE_DISABLE_BACKGROUND_TASKS", "1")
fork_disabled, _, fork_src = flag("CLAUDE_CODE_FORK_SUBAGENT", "0")
model_force, _, force_src = flag("CLAUDE_CODE_SUBAGENT_MODEL_FORCE", "1")

depth_raw, depth_src = lookup("CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH")
depth_one_versions = ((2, 1, 217), (2, 1, 218))
default_depth = 1 if version_tuple in depth_one_versions else 3
spawn_depth = default_depth
if depth_raw is not None:
    if re.match(r"^[0-9]+$", depth_raw.strip()) and int(depth_raw.strip()) > 0:
        spawn_depth = int(depth_raw.strip())
    else:
        reasons.append("CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=" + repr(depth_raw) + " (" + depth_src
                       + ") is not a positive whole number in plain digits; Claude Code ignores it, default "
                       + str(default_depth) + " assumed")
        depth_src = None
if depth_raw is None or depth_src is None:
    if version_tuple in depth_one_versions:
        depth_src = "default on " + version
        reasons.append("Claude Code " + version + " defaults CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH to 1 "
                       "(2.1.217 and 2.1.218 only); set it to 3 explicitly in .claude/settings.json env")

if version == "unknown":
    reasons.append("claude binary not found on PATH or its version did not parse: claudeCodeVersion unknown")

if bg_disabled:
    dispatch = "foreground"
    reasons.append("CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 (" + bg_src + "): every subagent runs in the foreground")
elif fork_disabled:
    dispatch = "foreground-on-request"
    reasons.append("CLAUDE_CODE_FORK_SUBAGENT=0 (" + fork_src + "): fork mode off, run_in_background is available "
                   "per call but background stays the default; the foreman Agent probe is still decisive")
else:
    dispatch = "unknown"
    reasons.append("no foreground flag set: set CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 in "
                   + os.path.join(root, ".claude", "settings.json") + " env for foreman runs; "
                   "the foreman Agent probe decides the mode")

refused = False
if spawn_depth < 2:
    refused = True
    reasons.append("CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=" + str(spawn_depth) + " (" + str(depth_src)
                   + ") is below 2: the foreman cannot spawn workers; set it to 3 or higher. "
                   "Direct mode is still allowed")
if model_force:
    refused = True
    reasons.append("CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 (" + force_src + ") ignores every subagent model: "
                   "tiered routing is defeated; nothing is allowed until the user unsets it")

if refused:
    verdict = "foreman-refused"
    code = 2
elif bg_disabled or fork_disabled:
    verdict = "foreman-allowed"
    code = 0
else:
    verdict = "foreman-probe-required"
    code = 0

out = {
    "claudeCodeVersion": version,
    "dispatch": dispatch,
    "backgroundTasksDisabled": bool(bg_disabled),
    "forkModeDisabled": bool(fork_disabled),
    "spawnDepth": spawn_depth,
    "subagentModelForce": bool(model_force),
    "foremanAllowed": not refused,
    "checkedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "verdict": verdict,
    "reasons": reasons,
}
print(json.dumps(out))
if not json_only:
    sys.stderr.write("preflight: " + verdict + " (claude " + version + ", dispatch " + dispatch
                     + ", spawn depth " + str(spawn_depth) + ", model-force "
                     + ("on" if model_force else "off") + ")\n")
sys.exit(code)
PY_EOF
)

PREFLIGHT_ROOT="$ROOT" PREFLIGHT_JSON_ONLY="$JSON_ONLY" PREFLIGHT_VERSION_RAW="$VERSION_RAW" python3 -c "$PY" </dev/null
RC=$?
case "$RC" in
  0|2) exit "$RC" ;;
  *) exit 1 ;;
esac
