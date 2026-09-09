#!/bin/sh
# Self-contained test for scripts/hooks/*.sh and scripts/preflight.sh.
#
# Builds a temp git repo with fabricated checkpoints, pipes fixture stdin JSON
# into each hook script and asserts silent / deny / block / systemMessage /
# additionalContext outputs. Runs the preflight under `env -i` with the env
# combinations the spec names. Prints PASS/FAIL per check; exits non-zero on
# any FAIL.
#
# Usage: tests/hooks.sh [scratch-dir]

set +e

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$HERE/.." && pwd)
HOOKS="$PLUGIN_ROOT/scripts/hooks"
PREFLIGHT="$PLUGIN_ROOT/scripts/preflight.sh"

SCRATCH="${1:-${TMPDIR:-/tmp}/orchestrate-hooks-test}"
SCRATCH="$SCRATCH/tmp-U5"
rm -rf "$SCRATCH" 2>/dev/null
mkdir -p "$SCRATCH" || { echo "cannot create $SCRATCH"; exit 1; }
# The hooks print git's resolved toplevel (macOS: /var -> /private/var), so
# compare against the physical path.
SCRATCH=$(cd "$SCRATCH" && pwd -P)

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      %s\n' "$1" "$2"; }

# json_get <json> <python-expr-on-d> : prints the evaluated expression or "".
json_get() {
  printf '%s' "$1" | python3 -c "import json,sys
try:
    d = json.load(sys.stdin)
    v = $2
    print('' if v is None else v)
except Exception:
    print('')" 2>/dev/null
}

# run_hook <script> <stdin-json> : sets OUT and RC.
run_hook() {
  OUT=$(printf '%s' "$2" | "$1" 2>/dev/null)
  RC=$?
}

# run_hook_env <script> <stdin-json> <env-args...> : same, with `env` args
# (VAR=value or -u VAR) applied to the hook process only.
run_hook_env() {
  script=$1; input=$2; shift 2
  OUT=$(printf '%s' "$input" | env "$@" "$script" 2>/dev/null)
  RC=$?
}

# --- fixtures ---------------------------------------------------------------

REPO="$SCRATCH/repo with space"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
RUNS="$REPO/.claude/orchestrate-runs"
mkdir -p "$RUNS/20260909-1000"
CKPT="$RUNS/20260909-1000/checkpoint.json"

EMPTY_REPO="$SCRATCH/empty repo"
mkdir -p "$EMPTY_REPO"
git -C "$EMPTY_REPO" init -q

# write_ckpt <nextAction> <dispatchMode> <used> <cap> [owner.agentId, default foreman]
write_ckpt() {
  OWNER_ID="${5-foreman}"
  cat > "$CKPT" <<EOF
{
  "schemaVersion": 2,
  "runId": "20260909-1000",
  "integrationRoot": "$REPO",
  "integrationBranch": "main",
  "baselineSha": "abc",
  "lastIntegratedSha": "abc",
  "dispatchMode": "$2",
  "harness": {"claudeCodeVersion": "2.1.260", "dispatch": "foreground", "backgroundTasksDisabled": true,
              "forkModeDisabled": false, "spawnDepth": 3, "subagentModelForce": false,
              "foremanAllowed": true, "checkedAt": "2026-09-09T10:00:00Z"},
  "dispatchTally": {"used": $3, "cap": $4, "capSource": "planned-slots"},
  "owner": {"agentId": "$OWNER_ID", "epoch": 7},
  "stallCount": 0,
  "lastStallAt": "",
  "openWorktrees": [],
  "units": [],
  "nextAction": "$1"
}
EOF
}

FOREMAN_START='{"session_id":"s","transcript_path":"/x","cwd":"'"$REPO"'","hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"orchestrate:foreman"}'
FOREMAN_START_MANUAL='{"session_id":"s","transcript_path":"/x","cwd":"'"$REPO"'","hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"foreman"}'
EXPLORE_START='{"session_id":"s","transcript_path":"/x","cwd":"'"$REPO"'","hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"Explore"}'
FOREMAN_START_EMPTY='{"session_id":"s","transcript_path":"/x","cwd":"'"$EMPTY_REPO"'","hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"orchestrate:foreman"}'

stop_json() { # <agent_type> <stop_hook_active> [cwd]
  printf '{"session_id":"s","transcript_path":"/x","cwd":"%s","hook_event_name":"SubagentStop","agent_id":"a1","agent_type":"%s","stop_hook_active":%s,"last_assistant_message":"STATE: ..."}' "${3:-$REPO}" "$1" "$2"
}

pre_json() { # <agent_type or ""> [cwd] [tool_name]
  if [ -n "$1" ]; then
    printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"prompt":"x"},"tool_use_id":"t1","agent_id":"a1","agent_type":"%s"}' "${2:-$REPO}" "${3:-Agent}" "$1"
  else
    printf '{"session_id":"s","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"prompt":"x"},"tool_use_id":"t1"}' "${2:-$REPO}" "${3:-Agent}"
  fi
}

main_stop_json() { # <background_tasks json or "">
  if [ -n "$1" ]; then
    printf '{"session_id":"s","cwd":"%s","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done","background_tasks":%s}' "$REPO" "$1"
  else
    printf '{"session_id":"s","cwd":"%s","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done"}' "$REPO"
  fi
}

# --- syntax ----------------------------------------------------------------

for f in "$HOOKS"/foreman-start.sh "$HOOKS"/foreman-stop.sh "$HOOKS"/foreman-pre-agent.sh "$HOOKS"/run-open-notice.sh "$PREFLIGHT"; do
  if sh -n "$f" 2>/dev/null; then pass "sh -n $(basename "$f")"; else fail "sh -n $(basename "$f")" "syntax error"; fi
  if [ -x "$f" ]; then pass "executable $(basename "$f")"; else fail "executable $(basename "$f")" "not executable"; fi
  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -s sh "$f" >/dev/null 2>&1; then pass "shellcheck $(basename "$f")"; else fail "shellcheck $(basename "$f")" "$(shellcheck -s sh "$f" 2>&1 | head -5)"; fi
  fi
done

if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PLUGIN_ROOT/hooks/hooks.json" 2>/dev/null; then
  pass "hooks.json parses"
else
  fail "hooks.json parses" "invalid JSON"
fi
HJ=$(cat "$PLUGIN_ROOT/hooks/hooks.json")
for ev in SubagentStart SubagentStop PreToolUse Stop SessionStart; do
  v=$(json_get "$HJ" "len(d['hooks']['$ev'])")
  [ "$v" = "1" ] && pass "hooks.json has $ev" || fail "hooks.json has $ev" "got '$v'"
done
v=$(json_get "$HJ" "d['hooks']['PreToolUse'][0]['matcher']")
[ "$v" = "Agent" ] && pass "PreToolUse matcher is Agent" || fail "PreToolUse matcher is Agent" "got '$v'"
v=$(json_get "$HJ" "d['hooks']['SubagentStop'][0]['matcher']")
[ "$v" = '^(orchestrate:)?foreman$' ] && pass "SubagentStop matcher anchored" || fail "SubagentStop matcher anchored" "got '$v'"
v=$(json_get "$HJ" "'matcher' in d['hooks']['Stop'][0]")
[ "$v" = "False" ] && pass "Stop has no matcher" || fail "Stop has no matcher" "got '$v'"
v=$(json_get "$HJ" "d['hooks']['SubagentStart'][0]['hooks'][0]['timeout']")
[ "$v" = "10" ] && pass "new handlers carry timeout 10" || fail "new handlers carry timeout 10" "got '$v'"
# The variable name below does not exist in Claude Code; it is assembled from
# two fragments so the literal never appears in any file of this plugin.
FORBIDDEN="CLAUDE_CODE_DISABLE_FORK""_MODE"
if grep -qF "$FORBIDDEN" "$PLUGIN_ROOT/hooks/hooks.json" "$HOOKS"/*.sh "$PREFLIGHT" "$0" 2>/dev/null; then
  fail "no nonexistent env var name" "$FORBIDDEN appears"
else
  pass "no nonexistent env var name"
fi

# --- foreman-start.sh ---------------------------------------------------------

write_ckpt "dispatch U2" FOREMAN 3 12
run_hook "$HOOKS/foreman-start.sh" "$FOREMAN_START"
ctx=$(json_get "$OUT" "d['hookSpecificOutput']['additionalContext']")
ev=$(json_get "$OUT" "d['hookSpecificOutput']['hookEventName']")
if [ "$RC" = 0 ] && [ "$ev" = "SubagentStart" ] && case "$ctx" in *"runId=20260909-1000"*"nextAction=dispatch U2"*"owner.epoch=7"*"dispatchMode=FOREMAN"*"dispatchTally=3/12"*"harness.dispatch=foreground"*'/bin/orchestrate" preflight'*"run_in_background: false"*) true;; *) false;; esac; then
  pass "SubagentStart: additionalContext with checkpoint fields and first actions"
else
  fail "SubagentStart: additionalContext with checkpoint fields and first actions" "rc=$RC out=$OUT"
fi
case "$ctx" in *"$CKPT"*) pass "SubagentStart: names the checkpoint path";; *) fail "SubagentStart: names the checkpoint path" "$ctx";; esac
case "$ctx" in *"harness set dispatch foreground"*"harness set dispatch background"*) pass "SubagentStart: injects the harness set dispatch instruction";; *) fail "SubagentStart: injects the harness set dispatch instruction" "$ctx";; esac
case "$ctx" in *'orchestrate pause --reason "stale checkpoint at probe; orchestrator must refresh and resume"'*) pass "SubagentStart: names the pause reason for a stale probe";; *) fail "SubagentStart: names the pause reason for a stale probe" "$ctx";; esac
case "$ctx" in *"(1)"*"preflight"*"(2)"*"Agent probe"*"(3)"*"harness set dispatch"*) pass "SubagentStart: preflight, probe, harness set in that order";; *) fail "SubagentStart: preflight, probe, harness set in that order" "$ctx";; esac
case "$ctx" in *"orchestrate status"*) pass "SubagentStart: names orchestrate status as the on-disk equivalent";; *) fail "SubagentStart: names orchestrate status as the on-disk equivalent" "$ctx";; esac

# Plugin-root convention: the path is double-quoted inside the backticks, both
# when CLAUDE_PLUGIN_ROOT is unset (resolved from the script location) and when
# it points at a directory with a space and an apostrophe.
run_hook_env "$HOOKS/foreman-start.sh" "$FOREMAN_START" -u CLAUDE_PLUGIN_ROOT
ctx=$(json_get "$OUT" "d['hookSpecificOutput']['additionalContext']")
case "$ctx" in *'run `"'"$PLUGIN_ROOT"'/bin/orchestrate" preflight`'*) pass "SubagentStart: plugin root resolved from the script location, quoted";; *) fail "SubagentStart: plugin root resolved from the script location, quoted" "$ctx";; esac
FAKE_PLUGIN="$SCRATCH/plug in's root"
run_hook_env "$HOOKS/foreman-start.sh" "$FOREMAN_START" CLAUDE_PLUGIN_ROOT="$FAKE_PLUGIN"
ctx=$(json_get "$OUT" "d['hookSpecificOutput']['additionalContext']")
case "$ctx" in *'run `"'"$FAKE_PLUGIN"'/bin/orchestrate" preflight`'*) pass "SubagentStart: CLAUDE_PLUGIN_ROOT with space and apostrophe quoted in the command";; *) fail "SubagentStart: CLAUDE_PLUGIN_ROOT with space and apostrophe quoted in the command" "$ctx";; esac
case "$ctx" in *'`orchestrate` below means `"'"$FAKE_PLUGIN"'/bin/orchestrate"`'*) pass "SubagentStart: states the orchestrate = quoted plugin-root/bin/orchestrate convention";; *) fail "SubagentStart: states the orchestrate = quoted plugin-root/bin/orchestrate convention" "$ctx";; esac

run_hook "$HOOKS/foreman-start.sh" "$FOREMAN_START_MANUAL"
ctx=$(json_get "$OUT" "d['hookSpecificOutput']['additionalContext']")
[ -n "$ctx" ] && pass "SubagentStart: manual-install agent_type foreman accepted" || fail "SubagentStart: manual-install agent_type foreman accepted" "out=$OUT"

run_hook "$HOOKS/foreman-start.sh" "$FOREMAN_START_EMPTY"
ctx=$(json_get "$OUT" "d['hookSpecificOutput']['additionalContext']")
case "$ctx" in *"no run archive"*"orchestrate init"*"STOPPED-AWAITING-RESUME"*) pass "SubagentStart: no checkpoint -> init instruction";; *) fail "SubagentStart: no checkpoint -> init instruction" "rc=$RC out=$OUT";; esac

run_hook "$HOOKS/foreman-start.sh" "$EXPLORE_START"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "SubagentStart: non-foreman agent_type silent" || fail "SubagentStart: non-foreman agent_type silent" "rc=$RC out=$OUT"

run_hook "$HOOKS/foreman-start.sh" "not json at all"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "SubagentStart: malformed stdin silent exit 0" || fail "SubagentStart: malformed stdin silent exit 0" "rc=$RC out=$OUT"

# --- foreman-stop.sh ----------------------------------------------------------

write_ckpt "complete" FOREMAN 12 12
run_hook "$HOOKS/foreman-stop.sh" "$(stop_json orchestrate:foreman false)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "SubagentStop: nextAction complete -> silent" || fail "SubagentStop: nextAction complete -> silent" "rc=$RC out=$OUT"

write_ckpt "paused: waiting for the user" FOREMAN 4 12
run_hook "$HOOKS/foreman-stop.sh" "$(stop_json orchestrate:foreman false)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "SubagentStop: nextAction paused -> silent" || fail "SubagentStop: nextAction paused -> silent" "rc=$RC out=$OUT"

write_ckpt "ship-gate" FOREMAN 12 12
run_hook "$HOOKS/foreman-stop.sh" "$(stop_json orchestrate:foreman false)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "SubagentStop: nextAction ship-gate -> silent (loop finished, ship gate is the orchestrator's)" || fail "SubagentStop: nextAction ship-gate -> silent (loop finished, ship gate is the orchestrator's)" "rc=$RC out=$OUT"

write_ckpt "dispatch U2" DIRECT 4 12 orchestrator
run_hook "$HOOKS/foreman-stop.sh" "$(stop_json orchestrate:foreman false)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "SubagentStop: dispatchMode DIRECT -> silent (taken over)" || fail "SubagentStop: dispatchMode DIRECT -> silent (taken over)" "rc=$RC out=$OUT"

write_ckpt "dispatch U2" FOREMAN 4 12 orchestrator
run_hook "$HOOKS/foreman-stop.sh" "$(stop_json orchestrate:foreman false)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "SubagentStop: owner.agentId orchestrator -> silent" || fail "SubagentStop: owner.agentId orchestrator -> silent" "rc=$RC out=$OUT"

write_ckpt "dispatch U2" FOREMAN 4 12 ""
run_hook "$HOOKS/foreman-stop.sh" "$(stop_json orchestrate:foreman false)"
dec=$(json_get "$OUT" "d.get('decision')")
[ "$dec" = "block" ] && pass "SubagentStop: empty owner.agentId still guarded -> block" || fail "SubagentStop: empty owner.agentId still guarded -> block" "rc=$RC out=$OUT"

write_ckpt "dispatch U2" FOREMAN 4 12
run_hook "$HOOKS/foreman-stop.sh" "$(stop_json orchestrate:foreman false)"
dec=$(json_get "$OUT" "d['decision']")
reason=$(json_get "$OUT" "d['reason']")
if [ "$RC" = 0 ] && [ "$dec" = "block" ] && case "$reason" in *"nextAction=dispatch U2"*"tally 4/12"*"orchestrate pause --reason"*) true;; *) false;; esac; then
  pass "SubagentStop: work left, stop_hook_active false -> block"
else
  fail "SubagentStop: work left, stop_hook_active false -> block" "rc=$RC out=$OUT"
fi
case "$reason" in *"lease take --agent orchestrator --expect 7"*) pass "SubagentStop: block reason names the CAS take-over with --expect epoch";; *) fail "SubagentStop: block reason names the CAS take-over with --expect epoch" "$reason";; esac
case "$reason" in *'lease take --agent orchestrator`'*) fail "SubagentStop: no bare lease take without --expect in the reason" "$reason";; *) pass "SubagentStop: no bare lease take without --expect in the reason";; esac
sm=$(json_get "$OUT" "d.get('systemMessage')")
[ -z "$sm" ] && pass "SubagentStop: block carries no systemMessage" || fail "SubagentStop: block carries no systemMessage" "$OUT"

run_hook "$HOOKS/foreman-stop.sh" "$(stop_json orchestrate:foreman true)"
dec=$(json_get "$OUT" "d.get('decision')")
sm=$(json_get "$OUT" "d.get('systemMessage')")
if [ "$RC" = 0 ] && [ -z "$dec" ] && case "$sm" in *"foreman stopped with work left"*"run 20260909-1000"*"nextAction=dispatch U2"*"lease take --agent orchestrator --expect 7"*) true;; *) false;; esac; then
  pass "SubagentStop: stop_hook_active true -> systemMessage with --expect epoch, no block"
else
  fail "SubagentStop: stop_hook_active true -> systemMessage with --expect epoch, no block" "rc=$RC out=$OUT"
fi

run_hook "$HOOKS/foreman-stop.sh" "$(stop_json foreman false)"
dec=$(json_get "$OUT" "d.get('decision')")
[ "$dec" = "block" ] && pass "SubagentStop: manual-install agent_type foreman handled" || fail "SubagentStop: manual-install agent_type foreman handled" "out=$OUT"

run_hook "$HOOKS/foreman-stop.sh" "$(stop_json Explore false)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "SubagentStop: non-foreman agent_type silent" || fail "SubagentStop: non-foreman agent_type silent" "rc=$RC out=$OUT"

run_hook "$HOOKS/foreman-stop.sh" "$(stop_json orchestrate:foreman false "$EMPTY_REPO")"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "SubagentStop: no checkpoint -> silent" || fail "SubagentStop: no checkpoint -> silent" "rc=$RC out=$OUT"

run_hook "$HOOKS/foreman-stop.sh" "{broken"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "SubagentStop: malformed stdin silent exit 0" || fail "SubagentStop: malformed stdin silent exit 0" "rc=$RC out=$OUT"

# --- foreman-pre-agent.sh -----------------------------------------------------

write_ckpt "dispatch U2" FOREMAN 4 12
run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json "")"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "PreToolUse: no agent_type (main session) -> silent" || fail "PreToolUse: no agent_type (main session) -> silent" "rc=$RC out=$OUT"

run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json Explore)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "PreToolUse: other agent_type -> silent" || fail "PreToolUse: other agent_type -> silent" "rc=$RC out=$OUT"

run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json orchestrate:foreman "$REPO" Bash)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "PreToolUse: foreman non-Agent tool -> silent" || fail "PreToolUse: foreman non-Agent tool -> silent" "rc=$RC out=$OUT"

run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json orchestrate:foreman)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "PreToolUse: foreman, FOREMAN mode, fresh, work left -> allow silently" || fail "PreToolUse: foreman, FOREMAN mode, fresh, work left -> allow silently" "rc=$RC out=$OUT"

check_deny() { # <label> <needle>
  pd=$(json_get "$OUT" "d['hookSpecificOutput']['permissionDecision']")
  ev=$(json_get "$OUT" "d['hookSpecificOutput']['hookEventName']")
  rs=$(json_get "$OUT" "d['hookSpecificOutput']['permissionDecisionReason']")
  if [ "$RC" = 0 ] && [ "$pd" = "deny" ] && [ "$ev" = "PreToolUse" ] && case "$rs" in *"$2"*) true;; *) false;; esac; then
    pass "$1"
  else
    fail "$1" "rc=$RC out=$OUT"
  fi
}

write_ckpt "dispatch U2" DIRECT 4 12
run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json orchestrate:foreman)"
check_deny "PreToolUse: dispatchMode DIRECT -> deny with epoch" "epoch 7"

write_ckpt "complete" FOREMAN 12 12
run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json orchestrate:foreman)"
check_deny "PreToolUse: nextAction complete -> deny" "nextAction=complete"

write_ckpt "dispatch U3" FOREMAN 12 12
run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json foreman)"
check_deny "PreToolUse: cap reached -> deny (manual-install agent_type)" "cap reached"

write_ckpt "dispatch U3" FOREMAN 5 0
run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json orchestrate:foreman)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "PreToolUse: cap 0 means uncapped -> allow" || fail "PreToolUse: cap 0 means uncapped -> allow" "rc=$RC out=$OUT"

write_ckpt "dispatch U2" FOREMAN 4 12
touch -t 202001010000 "$CKPT"
run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json orchestrate:foreman)"
check_deny "PreToolUse: checkpoint older than 20 min -> deny stale" "checkpoint stale"
rs=$(json_get "$OUT" "d['hookSpecificOutput']['permissionDecisionReason']")
case "$rs" in *'orchestrate pause --reason "stale checkpoint at probe; orchestrator must refresh and resume"'*"STATE line"*) pass "PreToolUse: stale deny tells the foreman to pause, refresh is the orchestrator's";; *) fail "PreToolUse: stale deny tells the foreman to pause, refresh is the orchestrator's" "$rs";; esac
case "$rs" in *"handoff --to foreman"*"stall record"*) pass "PreToolUse: stale deny names the orchestrator's refresh commands";; *) fail "PreToolUse: stale deny names the orchestrator's refresh commands" "$rs";; esac

# Newest-by-mtime selection: an older run dir with a stale checkpoint must not
# shadow a fresh one.
mkdir -p "$RUNS/20260101-0900"
cp "$CKPT" "$RUNS/20260101-0900/checkpoint.json"
touch -t 202001010000 "$RUNS/20260101-0900/checkpoint.json"
write_ckpt "dispatch U2" FOREMAN 4 12
run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json orchestrate:foreman)"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "PreToolUse: newest checkpoint by mtime wins over an older run" || fail "PreToolUse: newest checkpoint by mtime wins over an older run" "rc=$RC out=$OUT"
rm -rf "$RUNS/20260101-0900"

run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json orchestrate:foreman "$EMPTY_REPO")"
check_deny "PreToolUse: no checkpoint -> deny with init instruction" "orchestrate init"

run_hook "$HOOKS/foreman-pre-agent.sh" "garbage"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "PreToolUse: malformed stdin silent exit 0" || fail "PreToolUse: malformed stdin silent exit 0" "rc=$RC out=$OUT"

# --- run-open-notice.sh -------------------------------------------------------

write_ckpt "dispatch U2" FOREMAN 4 12
run_hook "$HOOKS/run-open-notice.sh" "$(main_stop_json '[{"id":"a"},{"id":"b"}]')"
sm=$(json_get "$OUT" "d.get('systemMessage')")
dec=$(json_get "$OUT" "d.get('decision')")
if [ "$RC" = 0 ] && [ -z "$dec" ] && case "$sm" in *"run 20260909-1000 is open"*"nextAction=dispatch U2"*"tally 4/12"*"min ago"*"background tasks in flight: 2"*) true;; *) false;; esac; then
  pass "Stop: open run -> systemMessage with background_tasks count, no block"
else
  fail "Stop: open run -> systemMessage with background_tasks count, no block" "rc=$RC out=$OUT"
fi

run_hook "$HOOKS/run-open-notice.sh" "$(main_stop_json "")"
sm=$(json_get "$OUT" "d.get('systemMessage')")
case "$sm" in *"background tasks in flight: unknown"*) pass "Stop: background_tasks absent -> unknown";; *) fail "Stop: background_tasks absent -> unknown" "out=$OUT";; esac

write_ckpt "complete" FOREMAN 12 12
run_hook "$HOOKS/run-open-notice.sh" "$(main_stop_json '[]')"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "Stop: complete -> silent" || fail "Stop: complete -> silent" "rc=$RC out=$OUT"

write_ckpt "paused: blocked on creds" FOREMAN 4 12
run_hook "$HOOKS/run-open-notice.sh" "$(main_stop_json '[]')"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "Stop: paused -> silent" || fail "Stop: paused -> silent" "rc=$RC out=$OUT"

write_ckpt "ship-gate" FOREMAN 12 12
run_hook "$HOOKS/run-open-notice.sh" "$(main_stop_json '[]')"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "Stop: ship-gate -> silent" || fail "Stop: ship-gate -> silent" "rc=$RC out=$OUT"

write_ckpt "dispatch U2" DIRECT 4 12 orchestrator
run_hook "$HOOKS/run-open-notice.sh" "$(main_stop_json '[]')"
sm=$(json_get "$OUT" "d.get('systemMessage')")
case "$sm" in *"is open"*) pass "Stop: open DIRECT-mode run still noticed (main-session notice ignores ownership)";; *) fail "Stop: open DIRECT-mode run still noticed (main-session notice ignores ownership)" "out=$OUT";; esac

write_ckpt "dispatch U2" FOREMAN 4 12
touch -t 202001010000 "$CKPT"
run_hook "$HOOKS/run-open-notice.sh" "$(main_stop_json '[]')"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "Stop: checkpoint older than 6 h -> silent" || fail "Stop: checkpoint older than 6 h -> silent" "rc=$RC out=$OUT"

run_hook "$HOOKS/run-open-notice.sh" "??"
[ "$RC" = 0 ] && [ -z "$OUT" ] && pass "Stop: malformed stdin silent exit 0" || fail "Stop: malformed stdin silent exit 0" "rc=$RC out=$OUT"

# --- hooks never write into the repo ------------------------------------------

write_ckpt "dispatch U2" FOREMAN 4 12
BEFORE=$(cd "$REPO" && find . -path ./.git -prune -o -type f -print | sort)
run_hook "$HOOKS/foreman-start.sh" "$FOREMAN_START"
run_hook "$HOOKS/foreman-stop.sh" "$(stop_json orchestrate:foreman false)"
run_hook "$HOOKS/foreman-pre-agent.sh" "$(pre_json orchestrate:foreman)"
run_hook "$HOOKS/run-open-notice.sh" "$(main_stop_json '[]')"
AFTER=$(cd "$REPO" && find . -path ./.git -prune -o -type f -print | sort)
[ "$BEFORE" = "$AFTER" ] && pass "hooks leave the repo file list unchanged" || fail "hooks leave the repo file list unchanged" "before: $BEFORE after: $AFTER"

# --- preflight.sh ---------------------------------------------------------------

FAKE_HOME="$SCRATCH/home"
mkdir -p "$FAKE_HOME/.claude"
CLEAN_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"

run_preflight() { # env assignments as remaining args
  OUT=$(cd "$REPO" && env -i PATH="$CLEAN_PATH" HOME="$FAKE_HOME" "$@" "$PREFLIGHT" --json 2>/dev/null)
  RC=$?
}

check_preflight() { # <label> <expected verdict> <expected rc>
  v=$(json_get "$OUT" "d['verdict']")
  fa=$(json_get "$OUT" "d['foremanAllowed']")
  if [ "$RC" = "$3" ] && [ "$v" = "$2" ]; then
    pass "$1"
  else
    fail "$1" "rc=$RC verdict=$v out=$OUT"
  fi
  if [ "$2" = "foreman-refused" ]; then
    [ "$fa" = "False" ] || fail "$1 (foremanAllowed false)" "$fa"
  else
    [ "$fa" = "True" ] || fail "$1 (foremanAllowed true)" "$fa"
  fi
}

run_preflight CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1
check_preflight "preflight: DISABLE_BACKGROUND_TASKS=1 -> foreman-allowed exit 0" foreman-allowed 0
d=$(json_get "$OUT" "d['dispatch']"); b=$(json_get "$OUT" "d['backgroundTasksDisabled']")
[ "$d" = "foreground" ] && [ "$b" = "True" ] && pass "preflight: dispatch foreground, backgroundTasksDisabled true" || fail "preflight: dispatch foreground, backgroundTasksDisabled true" "$OUT"
for k in claudeCodeVersion dispatch backgroundTasksDisabled forkModeDisabled spawnDepth subagentModelForce foremanAllowed checkedAt verdict reasons; do
  has=$(json_get "$OUT" "'$k' in d")
  [ "$has" = "True" ] || fail "preflight: output has key $k" "$OUT"
done
pass "preflight: output carries every harness key plus verdict and reasons"
sd=$(json_get "$OUT" "d['spawnDepth']")
[ "$sd" = "3" ] && pass "preflight: spawnDepth defaults to 3" || fail "preflight: spawnDepth defaults to 3" "$sd"

run_preflight
check_preflight "preflight: nothing set -> foreman-probe-required exit 0" foreman-probe-required 0
d=$(json_get "$OUT" "d['dispatch']")
[ "$d" = "unknown" ] && pass "preflight: no flag -> dispatch unknown" || fail "preflight: no flag -> dispatch unknown" "$d"
r=$(json_get "$OUT" "' '.join(d['reasons'])")
case "$r" in *"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1"*) pass "preflight: probe-required reason names the fix";; *) fail "preflight: probe-required reason names the fix" "$r";; esac

run_preflight CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1
check_preflight "preflight: SPAWN_DEPTH=1 -> foreman-refused exit 2" foreman-refused 2
r=$(json_get "$OUT" "' '.join(d['reasons'])")
case "$r" in *"Direct mode is still allowed"*) pass "preflight: depth refusal says direct mode still allowed";; *) fail "preflight: depth refusal says direct mode still allowed" "$r";; esac

run_preflight CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1
check_preflight "preflight: SUBAGENT_MODEL_FORCE=1 -> foreman-refused exit 2 even with the foreground flag" foreman-refused 2
mf=$(json_get "$OUT" "d['subagentModelForce']")
[ "$mf" = "True" ] && pass "preflight: subagentModelForce true" || fail "preflight: subagentModelForce true" "$OUT"

run_preflight CLAUDE_CODE_FORK_SUBAGENT=0
check_preflight "preflight: FORK_SUBAGENT=0 -> foreman-allowed exit 0" foreman-allowed 0
d=$(json_get "$OUT" "d['dispatch']"); f=$(json_get "$OUT" "d['forkModeDisabled']")
[ "$d" = "foreground-on-request" ] && [ "$f" = "True" ] && pass "preflight: fork off -> dispatch foreground-on-request" || fail "preflight: fork off -> dispatch foreground-on-request" "$OUT"

run_preflight CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=abc
sd=$(json_get "$OUT" "d['spawnDepth']")
[ "$sd" = "3" ] && [ "$RC" = 0 ] && pass "preflight: non-numeric spawn depth ignored (default 3)" || fail "preflight: non-numeric spawn depth ignored (default 3)" "$OUT"

# settings.json fallback (project)
mkdir -p "$REPO/.claude"
printf '{"env": {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1"}}\n' > "$REPO/.claude/settings.json"
run_preflight
check_preflight "preflight: project .claude/settings.json env fallback -> foreman-allowed" foreman-allowed 0
r=$(json_get "$OUT" "' '.join(d['reasons'])")
case "$r" in *"settings.json"*) pass "preflight: reason names the settings file as source";; *) fail "preflight: reason names the settings file as source" "$r";; esac

# settings.local.json overrides settings.json
printf '{"env": {"CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"}}\n' > "$REPO/.claude/settings.local.json"
run_preflight
check_preflight "preflight: .claude/settings.local.json env read as well -> refused" foreman-refused 2
rm -f "$REPO/.claude/settings.local.json"

# process env beats settings
run_preflight CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1
check_preflight "preflight: process env wins over settings" foreman-refused 2
rm -f "$REPO/.claude/settings.json"

# user settings under HOME
printf '{"env": {"CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1"}}\n' > "$FAKE_HOME/.claude/settings.json"
run_preflight
check_preflight "preflight: ~/.claude/settings.json env fallback -> refused" foreman-refused 2
rm -f "$FAKE_HOME/.claude/settings.json"

# malformed settings file is ignored
printf 'not json' > "$REPO/.claude/settings.json"
run_preflight CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1
check_preflight "preflight: malformed settings file ignored" foreman-allowed 0
rm -f "$REPO/.claude/settings.json"

# --root override and human line on stderr
OUT=$(env -i PATH="$CLEAN_PATH" HOME="$FAKE_HOME" "$PREFLIGHT" --root "$EMPTY_REPO" 2>"$SCRATCH/stderr.txt"); RC=$?
v=$(json_get "$OUT" "d['verdict']")
[ "$v" = "foreman-probe-required" ] && grep -q '^preflight: foreman-probe-required' "$SCRATCH/stderr.txt" && pass "preflight: --root works and the human line goes to stderr" || fail "preflight: --root works and the human line goes to stderr" "rc=$RC out=$OUT err=$(cat "$SCRATCH/stderr.txt")"
lines=$(printf '%s\n' "$OUT" | grep -c .)
[ "$lines" = "1" ] && pass "preflight: stdout is exactly one JSON line" || fail "preflight: stdout is exactly one JSON line" "$OUT"

# version: with a fake claude on PATH
mkdir -p "$SCRATCH/fakebin"
printf '#!/bin/sh\necho "2.1.217 (Claude Code)"\n' > "$SCRATCH/fakebin/claude"
chmod +x "$SCRATCH/fakebin/claude"
OUT=$(cd "$REPO" && env -i PATH="$SCRATCH/fakebin:$CLEAN_PATH" HOME="$FAKE_HOME" "$PREFLIGHT" --json 2>/dev/null); RC=$?
ver=$(json_get "$OUT" "d['claudeCodeVersion']")
r=$(json_get "$OUT" "' '.join(d['reasons'])")
[ "$ver" = "2.1.217" ] && pass "preflight: parses claude --version" || fail "preflight: parses claude --version" "$OUT"
case "$r" in *"2.1.217 and 2.1.218 only"*) pass "preflight: 2.1.217 spawn-depth exception noted in reasons";; *) fail "preflight: 2.1.217 spawn-depth exception noted in reasons" "$r";; esac
sd=$(json_get "$OUT" "d['spawnDepth']")
[ "$sd" = "1" ] && pass "preflight: spawnDepth defaults to 1 on 2.1.217 without the variable" || fail "preflight: spawnDepth defaults to 1 on 2.1.217 without the variable" "$sd"
check_preflight "preflight: 2.1.217 without the depth variable -> foreman-refused exit 2" foreman-refused 2
case "$r" in *"default on 2.1.217"*"below 2"*"Direct mode is still allowed"*) pass "preflight: 2.1.217 refusal names the version default as source";; *) fail "preflight: 2.1.217 refusal names the version default as source" "$r";; esac

OUT=$(cd "$REPO" && env -i PATH="$SCRATCH/fakebin:$CLEAN_PATH" HOME="$FAKE_HOME" CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=3 CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1 "$PREFLIGHT" --json 2>/dev/null); RC=$?
sd=$(json_get "$OUT" "d['spawnDepth']")
check_preflight "preflight: 2.1.217 with SPAWN_DEPTH=3 set -> foreman-allowed" foreman-allowed 0
[ "$sd" = "3" ] && pass "preflight: explicit depth wins over the 2.1.217 default" || fail "preflight: explicit depth wins over the 2.1.217 default" "$sd"

OUT=$(cd "$REPO" && env -i PATH="$SCRATCH/fakebin:$CLEAN_PATH" HOME="$FAKE_HOME" CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=abc "$PREFLIGHT" --json 2>/dev/null); RC=$?
sd=$(json_get "$OUT" "d['spawnDepth']")
[ "$sd" = "1" ] && [ "$RC" = 2 ] && pass "preflight: unparsable depth on 2.1.217 falls back to 1 -> refused" || fail "preflight: unparsable depth on 2.1.217 falls back to 1 -> refused" "rc=$RC out=$OUT"

printf '#!/bin/sh\necho "2.1.218 (Claude Code)"\n' > "$SCRATCH/fakebin/claude"
OUT=$(cd "$REPO" && env -i PATH="$SCRATCH/fakebin:$CLEAN_PATH" HOME="$FAKE_HOME" "$PREFLIGHT" --json 2>/dev/null); RC=$?
check_preflight "preflight: 2.1.218 without the depth variable -> foreman-refused exit 2" foreman-refused 2

printf '#!/bin/sh\necho "2.1.260 (Claude Code)"\n' > "$SCRATCH/fakebin/claude"
OUT=$(cd "$REPO" && env -i PATH="$SCRATCH/fakebin:$CLEAN_PATH" HOME="$FAKE_HOME" "$PREFLIGHT" --json 2>/dev/null); RC=$?
r=$(json_get "$OUT" "' '.join(d['reasons'])")
case "$r" in *"2.1.217 and 2.1.218 only"*) fail "preflight: no 2.1.217 note on 2.1.260" "$r";; *) pass "preflight: no 2.1.217 note on 2.1.260";; esac
sd=$(json_get "$OUT" "d['spawnDepth']")
[ "$sd" = "3" ] && [ "$RC" = 0 ] && pass "preflight: spawnDepth defaults to 3 on 2.1.260" || fail "preflight: spawnDepth defaults to 3 on 2.1.260" "rc=$RC sd=$sd"

# A PATH with python3 and git but no claude: version must be "unknown".
mkdir -p "$SCRATCH/noclaude"
for tool in python3 git cat head sh; do
  ln -sf "$(command -v "$tool")" "$SCRATCH/noclaude/$tool"
done
OUT=$(cd "$REPO" && env -i PATH="$SCRATCH/noclaude" HOME="$FAKE_HOME" "$PREFLIGHT" --json 2>/dev/null); RC=$?
ver=$(json_get "$OUT" "d['claudeCodeVersion']")
r=$(json_get "$OUT" "' '.join(d['reasons'])")
if [ "$RC" = 0 ] && [ "$ver" = "unknown" ] && case "$r" in *"claudeCodeVersion unknown"*) true;; *) false;; esac; then
  pass "preflight: missing claude binary -> version unknown, still exit 0"
else
  fail "preflight: missing claude binary -> version unknown, still exit 0" "rc=$RC out=$OUT"
fi

# No python3 at all: exit 1 is the documented error path.
OUT=$(cd "$REPO" && env -i PATH="$SCRATCH/nonexistent" HOME="$FAKE_HOME" "$PREFLIGHT" --json 2>/dev/null); RC=$?
[ "$RC" = 1 ] && [ -z "$OUT" ] && pass "preflight: no python3 on PATH -> exit 1, no output" || fail "preflight: no python3 on PATH -> exit 1, no output" "rc=$RC out=$OUT"

# --- summary ------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
