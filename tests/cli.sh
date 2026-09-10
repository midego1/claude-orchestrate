#!/usr/bin/env bash
# Self-contained test for bin/orchestrate.
#
# Creates a throwaway git repository under $ORCH_TEST_TMP (default: a
# directory under $TMPDIR), writes a small gates manifest whose gates are
# cheap shell commands, and exercises every subcommand. Prints PASS/FAIL per
# check and exits non-zero when any check fails.
#
# Usage: tests/cli.sh            (bash 3.2 compatible)
#        ORCH_TEST_TMP=/some/dir tests/cli.sh

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ROOT=$(cd "$HERE/.." && pwd)
ORCH="$PLUGIN_ROOT/bin/orchestrate"
BASE_TMP="${ORCH_TEST_TMP:-${TMPDIR:-/tmp}/orchestrate-cli-test}"
mkdir -p "$BASE_TMP" || { echo "cannot create $BASE_TMP"; exit 1; }
WORK=$(mktemp -d "$BASE_TMP/repo.XXXXXX") || { echo "mktemp failed"; exit 1; }
REPO="$WORK/repo"
PASS_COUNT=0
FAIL_COUNT=0
KEEP="${ORCH_TEST_KEEP:-0}"

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $*"; }

# check_exit <expected> <label> <command...>
check_exit() {
  local expected="$1" label="$2" rc out
  shift 2
  out=$("$@" 2>&1)
  rc=$?
  if [ "$rc" -eq "$expected" ]; then
    pass "$label (exit $rc)"
  else
    fail "$label: expected exit $expected, got $rc"
    printf '%s\n' "$out" | sed 's/^/      | /'
  fi
  LAST_OUT="$out"
}

# check_true <label> <shell test...>
check_true() {
  local label="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    pass "$label"
  else
    fail "$label"
  fi
}

# check_contains <label> <needle> <haystack>
check_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in
    *"$needle"*) pass "$label" ;;
    *) fail "$label: expected to find '$needle' in:"; printf '%s\n' "$hay" | sed 's/^/      | /' ;;
  esac
}

cpget() {
  # cpget <dotted.key> [checkpoint]: prints a checkpoint value via python3
  python3 - "$1" "${2:-$CP}" <<'PY'
import json, sys
node = json.load(open(sys.argv[2]))
for part in sys.argv[1].split("."):
    if isinstance(node, list):
        node = node[int(part)]
    else:
        node = node[part]
print(node if isinstance(node, str) else json.dumps(node))
PY
}

schema_validate() {
  # schema_validate <schema> <doc>: runs the validator embedded in bin/orchestrate (the PYLIB heredoc)
  ORCH_SCHEMA_DIR="$PLUGIN_ROOT/schemas" python3 -c "$(sed -n '/^PYLIB=\$(cat <<.PY.$/,/^PY$/p' "$ORCH" | sed '1d;$d')" validate "$1" "$2"
}

cleanup() {
  if [ "$KEEP" = "1" ]; then
    echo "keeping $WORK"
    return
  fi
  if [ -d "$REPO" ]; then
    git -C "$REPO" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' | while read -r w; do
      [ "$w" = "$REPO" ] || git -C "$REPO" worktree remove --force "$w" 2>/dev/null || true
    done
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "== setup: temp repo at $REPO"
mkdir -p "$REPO" && cd "$REPO" || exit 1
git init -q -b main . 2>/dev/null || { git init -q . && git checkout -q -b main; }
git config user.email "cli-test@example.invalid"
git config user.name "cli test"
echo "hello" > README.md
mkdir -p .claude
cat > .claude/orchestrate-gates.json <<'EOF'
{
  "$comment": "test manifest: every gate is a cheap shell command",
  "install": "echo install >> bootstrap.txt",
  "envBootstrap": "echo env >> bootstrap.txt",
  "cachePaths": [".cache", "**/dist"],
  "sharedCache": { "note": "none in the test" },
  "gates": {
    "unit": [
      { "id": "ok", "cmd": "echo unit-ok" },
      { "id": "baseline", "cmd": "git rev-parse --verify {{baseline}} > /dev/null" },
      { "id": "opt", "cmd": "echo optional-failure; exit 4", "optional": true }
    ],
    "integration": [
      { "id": "ok", "cmd": "true" }
    ],
    "ship": [
      { "id": "ok", "cmd": "true" },
      { "id": "bad", "cmd": "echo failing; exit 7" },
      { "id": "opt", "cmd": "false", "optional": true }
    ]
  },
  "pricing": {
    "sonnet": { "inPerMTok": 3, "outPerMTok": 15, "perMTok": 6 },
    "haiku": { "perMTok": 1 }
  }
}
EOF
git add -A
git commit -q -m "baseline"
BASE=$(git rev-parse HEAD)
# untracked cache artefacts, like a real build leaves behind
mkdir -p .cache pkg/dist
echo "cache" > .cache/blob
echo "built" > pkg/dist/out.js
RUNS="$REPO/.claude/orchestrate-runs"
count_units() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["units"]))' "${1:-$CP}"; }

echo "== syntax"
check_exit 0 "bash -n bin/orchestrate" bash -n "$ORCH"
check_exit 0 "help exits 0" "$ORCH" help
check_contains "help lists gate run" "gate run" "$LAST_OUT"
check_contains "help lists gate run --cmd" "--cmd <id>=<command>" "$LAST_OUT"
check_contains "help lists worktree add --detach" "--detach" "$LAST_OUT"
check_contains "help says report accepts a fenced block" "fenced block" "$LAST_OUT"
check_contains "help names the reserved ship unit" "'ship' is reserved" "$LAST_OUT"
check_exit 0 "example manifest validates against the schema" schema_validate "$PLUGIN_ROOT/schemas/gates-manifest.schema.json" "$PLUGIN_ROOT/examples/orchestrate-gates.json"

# ---------------------------------------------------------------------------
echo "== init"
check_exit 0 "init (default run id)" "$ORCH" init
ID1=$(printf '%s\n' "$LAST_OUT" | tail -1)
check_true "archive dir exists" test -d "$RUNS/$ID1"
check_true "archive subdirs exist" test -d "$RUNS/$ID1/dispatch" -a -d "$RUNS/$ID1/reports" -a -d "$RUNS/$ID1/gates" -a -d "$RUNS/$ID1/failures"
check_true "dispatch-log.md exists" test -f "$RUNS/$ID1/dispatch-log.md"
check_true "no temp dir left behind" test -z "$(ls -d "$RUNS"/.init.* 2>/dev/null)"
check_true "exclude entry present" grep -qxF ".claude/orchestrate-runs/" "$REPO/.git/info/exclude"
check_true "archive is ignored by git" git check-ignore -q .claude/orchestrate-runs
check_exit 0 "init twice: second init succeeds" "$ORCH" init
ID2=$(printf '%s\n' "$LAST_OUT" | tail -1)
if [ "$ID1" != "$ID2" ]; then pass "second run id distinct ($ID1 vs $ID2)"; else fail "second run id not distinct ($ID1)"; fi
check_true "exclude entry added once" test "$(grep -cxF ".claude/orchestrate-runs/" "$REPO/.git/info/exclude")" = 1
check_exit 0 "init --run main --mode FOREMAN" "$ORCH" init --run main --mode FOREMAN
export ORCHESTRATE_RUN=main
CP="$RUNS/main/checkpoint.json"
check_exit 0 "checkpoint valid (archive check on a fresh run)" "$ORCH" archive check
check_true "schemaVersion 2" test "$(cpget schemaVersion)" = 2
check_true "baselineSha recorded" test "$(cpget baselineSha)" = "$BASE"
check_true "integrationBranch recorded" test "$(cpget integrationBranch)" = "main"
check_true "owner orchestrator epoch 1" test "$(cpget owner.agentId)" = "orchestrator" -a "$(cpget owner.epoch)" = 1
check_true "dispatchMode FOREMAN" test "$(cpget dispatchMode)" = "FOREMAN"
check_true "harness.dispatch present" test -n "$(cpget harness.dispatch)"
check_true "init seeds the reserved ship pseudo-unit" test "$(cpget units.0.id)" = "ship" -a "$(cpget units.0.status)" = "pending"
check_true "ship record: T2 opus xhigh verifier none shared" test "$(cpget units.0.tier)" = "T2" -a "$(cpget units.0.model)" = "opus" -a "$(cpget units.0.effort)" = "xhigh" -a "$(cpget units.0.verifier)" = "none" -a "$(cpget units.0.isolation)" = "shared"
check_true "fresh run cap stays 0 (no cap) until the first plan set" test "$(cpget dispatchTally.cap)" = 0
check_exit 1 "init --run main again refused" "$ORCH" init --run main

# ---------------------------------------------------------------------------
echo "== plan set"
check_exit 0 "plan set U1 (verified)" "$ORCH" plan set U1 --tier T1 --model sonnet --effort high --verifier fast
check_exit 0 "plan set U2 (verified deep)" "$ORCH" plan set U2 --tier T2 --model opus --effort high --verifier deep --depends U1
check_exit 0 "plan set U3 (unverified)" "$ORCH" plan set U3 --tier T0 --model haiku --effort low --verifier none --isolation shared
check_true "cap = 4+4+2+4 = 14 (ship excluded from the slot sum)" test "$(cpget dispatchTally.cap)" = 14
check_true "planned units are inserted before the ship record" test "$(cpget units.0.id)" = "U1" -a "$(cpget units.2.id)" = "U3" -a "$(cpget units.3.id)" = "ship"
check_exit 1 "plan set ship refused (reserved)" "$ORCH" plan set ship --tier T2 --model opus --effort high --verifier none
check_contains "refusal says reserved" "reserved" "$LAST_OUT"
check_true "cap unchanged after the refusal" test "$(cpget dispatchTally.cap)" = 14
check_true "capSource planned-slots" test "$(cpget dispatchTally.capSource)" = "planned-slots"
check_true "U2 dependsOn U1" test "$(cpget units.1.dependsOn)" = '["U1"]'
check_exit 0 "plan set U1 again (update)" "$ORCH" plan set U1 --tier T1 --model sonnet --effort medium --verifier fast
check_true "update did not duplicate U1 (3 units + ship)" test "$(count_units)" = 4
check_exit 1 "plan set with bad tier refused" "$ORCH" plan set U9 --tier T7 --model sonnet --effort high --verifier fast
check_true "invalid write left no U9" test "$(count_units)" = 4

# ---------------------------------------------------------------------------
echo "== dispatch open/close"
check_exit 0 "dispatch open U1 worker epoch 1" "$ORCH" dispatch open U1 --role worker --epoch 1
check_true "prints dispatch number 1" test "$LAST_OUT" = 1
check_true "tally used 1" test "$(cpget dispatchTally.used)" = 1
check_true "U1 in-flight" test "$(cpget units.0.status)" = "in-flight"
check_true "nextAction dispatch U1" test "$(cpget nextAction)" = "dispatch U1"
check_exit 2 "dispatch open with wrong epoch refused" "$ORCH" dispatch open U1 --role verifier --epoch 2
check_true "refusal did not count" test "$(cpget dispatchTally.used)" = 1
check_exit 0 "dispatch close U1 1 PASS" "$ORCH" dispatch close U1 1 --exit PASS --tokens 12000 --duration 90 --evidence "gates/U1-unit-1.json"
check_true "close recorded tokens" test "$(cpget units.0.dispatches.0.tokens)" = 12000
check_true "close recorded result" test "$(cpget units.0.dispatches.0.result)" = "PASS"
check_exit 0 "dispatch open U1 worker 2" "$ORCH" dispatch open U1 --role worker --epoch 1
check_exit 0 "dispatch close U1 2 FAIL" "$ORCH" dispatch close U1 2 --exit FAIL --tokens 3000 --duration 30
check_exit 0 "dispatch open U1 worker 3" "$ORCH" dispatch open U1 --role worker --epoch 1
check_exit 0 "dispatch close U1 3 PASS" "$ORCH" dispatch close U1 3 --exit PASS --tokens 5000 --duration 40
check_exit 2 "4th worker dispatch refused" "$ORCH" dispatch open U1 --role worker --epoch 1
check_exit 0 "verifier dispatch still allowed on U1" "$ORCH" dispatch open U1 --role verifier --epoch 1 --model haiku
check_true "prints dispatch number 4" test "$LAST_OUT" = 4
check_exit 0 "dispatch close U1 4" "$ORCH" dispatch close U1 4 --exit PASS --tokens 2000 --duration 20
check_exit 1 "dispatch close unknown n" "$ORCH" dispatch close U1 9 --exit PASS
check_exit 1 "dispatch open unknown unit" "$ORCH" dispatch open U9 --role worker --epoch 1
check_true "tally used 4" test "$(cpget dispatchTally.used)" = 4

echo "== dispatch open ship (ship-gate pseudo-unit)"
check_exit 0 "dispatch open ship --role review" "$ORCH" dispatch open ship --role review --epoch 1
check_true "prints ship dispatch number 1" test "$LAST_OUT" = 1
check_true "ship dispatch defaults to the ship record's model/effort" test "$(cpget units.3.dispatches.0.model)" = "opus" -a "$(cpget units.3.dispatches.0.effort)" = "xhigh"
check_true "ship dispatch counts against the global cap" test "$(cpget dispatchTally.used)" = 5
check_true "ship dispatch sets nextAction ship-gate" test "$(cpget nextAction)" = "ship-gate"
check_true "ship status stays pending" test "$(cpget units.3.status)" = "pending"
check_exit 0 "dispatch close ship 1" "$ORCH" dispatch close ship 1 --exit PASS --tokens 1000 --duration 10 --evidence "review: no findings"
check_exit 0 "dispatch open ship --role security" "$ORCH" dispatch open ship --role security --epoch 1 --model sonnet
check_exit 0 "dispatch open ship --role fix" "$ORCH" dispatch open ship --role fix --epoch 1
check_exit 0 "dispatch open ship --role reverify" "$ORCH" dispatch open ship --role reverify --epoch 1
check_exit 1 "dispatch open ship --role worker refused" "$ORCH" dispatch open ship --role worker --epoch 1
check_exit 0 "dispatch open - maps to ship" "$ORCH" dispatch open - --role review --epoch 1
check_true "ship has 5 dispatches, none limited by the 3-worker rule" test "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["units"][3]["dispatches"]))' "$CP")" = 5
for k in 2 3 4 5; do "$ORCH" dispatch close ship $k --exit PASS --tokens 1000 --duration 10 > /dev/null || fail "close ship $k"; done
check_true "tally used 9 after the ship-gate round" test "$(cpget dispatchTally.used)" = 9
check_exit 0 "archive check accepts the ship record" "$ORCH" archive check
check_exit 0 "unit set ship integrated (no sha needed)" "$ORCH" unit set ship integrated
check_exit 0 "archive check: ship integrated without sha/evidence is fine" "$ORCH" archive check
check_exit 0 "unit set ship pending again" "$ORCH" unit set ship pending
check_exit 0 "init --run old (archive without a ship record)" "$ORCH" init --run old
python3 - "$RUNS/old/checkpoint.json" <<'PY'
import json, sys
cp = json.load(open(sys.argv[1])); cp["units"] = []; json.dump(cp, open(sys.argv[1], "w"))
PY
check_exit 0 "dispatch open ship on an archive without the record creates it" "$ORCH" --run old dispatch open ship --role review --epoch 1
check_true "old archive now has the ship record" test "$(cpget units.0.id "$RUNS/old/checkpoint.json")" = "ship"

echo "== dispatch cap"
check_exit 0 "init --run capped --cap 1" "$ORCH" init --run capped --cap 1
check_exit 0 "plan set on capped run" "$ORCH" --run capped plan set A1 --tier T1 --model sonnet --effort high --verifier fast
check_true "manual cap kept at 1" test "$(cpget dispatchTally.cap "$RUNS/capped/checkpoint.json")" = 1
check_true "capSource manual" test "$(cpget dispatchTally.capSource "$RUNS/capped/checkpoint.json")" = "manual"
check_exit 0 "first dispatch under cap" "$ORCH" --run capped dispatch open A1 --role worker --epoch 1
check_exit 2 "dispatch at cap refused" "$ORCH" --run capped dispatch open A1 --role worker --epoch 1
check_exit 0 "pause capped run" "$ORCH" --run capped pause --reason "cap reached"

# ---------------------------------------------------------------------------
echo "== unit set"
check_exit 0 "unit set U1 integrated" "$ORCH" unit set U1 integrated --sha "$BASE" --evidence "gates/U1-unit-1.json"
check_true "lastIntegratedSha bumped" test "$(cpget lastIntegratedSha)" = "$BASE"
check_true "unit set recomputes nextAction: first pending unit (U2)" test "$(cpget nextAction)" = "dispatch U2"
check_exit 1 "unit set bad status" "$ORCH" unit set U1 done
check_exit 1 "unit set unknown unit" "$ORCH" unit set U9 pending
check_exit 0 "unit set U3 spot-check" "$ORCH" unit set U3 pending --spot-check "read the diff by hand"
check_true "spotCheck recorded" test "$(cpget units.2.spotCheck)" = "read the diff by hand"

# ---------------------------------------------------------------------------
echo "== lease"
check_exit 0 "lease check epoch 1 current" "$ORCH" lease check --epoch 1
check_exit 2 "lease take --expect mismatch refused" "$ORCH" lease take --agent orchestrator --expect 5
check_true "epoch unchanged after refusal" test "$(cpget owner.epoch)" = 1
check_exit 0 "lease take --expect 1" "$ORCH" lease take --agent orchestrator --expect 1
check_true "prints new epoch 2" test "$LAST_OUT" = 2
check_true "dispatchMode DIRECT after orchestrator take" test "$(cpget dispatchMode)" = "DIRECT"
check_exit 2 "lease check epoch 1 superseded" "$ORCH" lease check --epoch 1
check_exit 2 "dispatch open with old epoch refused after take-over" "$ORCH" dispatch open U2 --role worker --epoch 1
check_exit 0 "dispatch open with new epoch" "$ORCH" dispatch open U2 --role worker --epoch 2 --model opus --effort high
check_exit 0 "dispatch close U2 1" "$ORCH" dispatch close U2 1 --exit PASS --tokens 40000 --duration 300
check_exit 0 "handoff --to foreman" "$ORCH" handoff --to foreman
check_true "handoff keeps epoch 2" test "$(cpget owner.epoch)" = 2
check_true "handoff sets owner foreman" test "$(cpget owner.agentId)" = "foreman"
check_true "handoff sets FOREMAN" test "$(cpget dispatchMode)" = "FOREMAN"
check_exit 0 "handoff --to orchestrator" "$ORCH" handoff --to orchestrator
check_true "handoff back sets DIRECT" test "$(cpget dispatchMode)" = "DIRECT"
check_exit 0 "stall record" "$ORCH" stall record
check_true "stallCount 1" test "$(cpget stallCount)" = 1
check_true "lastStallAt set" test -n "$(cpget lastStallAt)"

# ---------------------------------------------------------------------------
echo "== worktree"
check_exit 0 "worktree add U1 --at baseline (no --branch)" "$ORCH" worktree add U1 --at "$BASE"
WT_LINE=$(printf '%s\n' "$LAST_OUT" | tail -1)
WT="${WT_LINE% *}"
check_true "prints <path> <branch>" test "${WT_LINE##* }" = "unit/U1"
check_true "worktree path exists" test -d "$WT"
check_true "worktree is a git worktree" git -C "$WT" rev-parse --is-inside-work-tree
check_true "worktree on the default branch unit/U1" test "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "unit/U1"
check_true "openWorktrees.branch is unit/U1" test "$(cpget openWorktrees.0.branch)" = "unit/U1"
check_true "worktree at baseline" test "$(git -C "$WT" rev-parse HEAD)" = "$BASE"
check_true "envBootstrap ran" grep -q env "$WT/bootstrap.txt"
check_true "install ran" grep -q install "$WT/bootstrap.txt"
check_true "registered in openWorktrees" test "$(cpget openWorktrees.0.unit)" = "U1"
check_true "openWorktrees baselineSha" test "$(cpget openWorktrees.0.baselineSha)" = "$BASE"
check_exit 1 "worktree add U1 again refused (path exists)" "$ORCH" worktree add U1 --at "$BASE"
check_exit 1 "worktree add U1b reusing branch unit/U1 elsewhere refused (checked out)" "$ORCH" worktree add U1b --at "$BASE" --branch unit/U1 --no-bootstrap --path "$WORK/wt-U1b"
check_true "refused worktree not registered" test "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["openWorktrees"]))' "$CP")" = 1
check_exit 0 "worktree add U2 --detach --no-bootstrap" "$ORCH" worktree add U2 --at "$BASE" --no-bootstrap --detach --path "$WORK/wt-U2"
check_true "--detach prints the path only" test "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "$WORK/wt-U2"
check_true "U2 worktree has no bootstrap file" test ! -e "$WORK/wt-U2/bootstrap.txt"
check_true "U2 worktree is detached" test "$(git -C "$WORK/wt-U2" rev-parse --abbrev-ref HEAD)" = "HEAD"
check_true "detached worktree registers an empty branch" test "$(cpget openWorktrees.1.branch)" = ""
check_exit 1 "archive check flags the detached worktree" "$ORCH" archive check
check_contains "finding names the missing branch" "has no branch" "$LAST_OUT"
check_exit 1 "--detach with --branch refused" "$ORCH" worktree add U5 --at "$BASE" --detach --branch unit/U5 --path "$WORK/wt-U5"
git -C "$REPO" branch unit/U3 "$BASE"
check_exit 0 "worktree add U3: existing branch at <sha> is reused" "$ORCH" worktree add U3 --at "$BASE" --no-bootstrap --path "$WORK/wt-U3"
check_true "U3 worktree on the reused branch" test "$(git -C "$WORK/wt-U3" rev-parse --abbrev-ref HEAD)" = "unit/U3"
OTHER=$(git -C "$REPO" commit-tree "$(git -C "$REPO" rev-parse "HEAD^{tree}")" -p "$BASE" -m "elsewhere")
git -C "$REPO" branch unit/U4 "$OTHER"
check_exit 1 "worktree add U4: existing branch at another sha refused" "$ORCH" worktree add U4 --at "$BASE" --no-bootstrap --path "$WORK/wt-U4"
check_contains "refusal names the branch" "unit/U4 already exists" "$LAST_OUT"
check_true "refused U4 worktree not created" test ! -e "$WORK/wt-U4"

# ---------------------------------------------------------------------------
echo "== gate run"
mkdir -p "$WT/.cache" "$WT/pkg/dist" "$WT/node_modules/foo/dist" "$WT/node_modules/.pnpm/bar@1/node_modules/bar/dist"
echo "cache" > "$WT/.cache/blob"
echo "built" > "$WT/pkg/dist/out.js"
echo "dep" > "$WT/node_modules/foo/dist/index.js"
echo "dep" > "$WT/node_modules/.pnpm/bar@1/node_modules/bar/dist/index.js"
check_exit 0 "gate run U1 unit --cwd worktree --since baseline" "$ORCH" gate run U1 unit --cwd "$WT" --since "$BASE"
check_contains "unit gate prints PASS ok" "PASS ok (echo unit-ok" "$LAST_OUT"
check_contains "unit gate prints FAIL opt (optional)" "FAIL opt" "$LAST_OUT"
check_contains "baseline substituted" "git rev-parse --verify $BASE" "$LAST_OUT"
check_true "unit gate log written" test -f "$RUNS/main/gates/U1-unit-1.log"
check_true "unit gate json written" test -f "$RUNS/main/gates/U1-unit-1.json"
check_true "unit gate json result PASS" test "$(cpget result "$RUNS/main/gates/U1-unit-1.json")" = "PASS"
check_true "unit gate json has 3 cmds" test "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["cmds"]))' "$RUNS/main/gates/U1-unit-1.json")" = 3
check_true "unit gate log has command output" grep -q "unit-ok" "$RUNS/main/gates/U1-unit-1.log"
check_true "warm run kept .cache in worktree" test -d "$WT/.cache"
check_exit 0 "gate run U1 unit again numbers 2" "$ORCH" gate run U1 unit --cwd "$WT"
check_true "second unit gate json is -2" test -f "$RUNS/main/gates/U1-unit-2.json"
check_exit 0 "gate run U1 integration" "$ORCH" gate run U1 integration
check_true "integration json written" test -f "$RUNS/main/gates/U1-integration-1.json"
check_exit 3 "gate run - ship exits 3 on FAIL" "$ORCH" gate run - ship --cwd "$WT"
check_contains "ship gate prints FAIL bad" "FAIL bad (echo failing; exit 7 → exit 7" "$LAST_OUT"
check_contains "ship gate prints PASS ok" "PASS ok" "$LAST_OUT"
check_true "ship log written (unit '-' becomes all)" test -f "$RUNS/main/gates/all-ship-1.log"
check_true "ship json written" test -f "$RUNS/main/gates/all-ship-1.json"
check_true "ship json result FAIL" test "$(cpget result "$RUNS/main/gates/all-ship-1.json")" = "FAIL"
check_true "ship json cold true" test "$(cpget cold "$RUNS/main/gates/all-ship-1.json")" = "true"
check_true "cold deleted .cache in cwd" test ! -e "$WT/.cache"
check_true "cold deleted **/dist in cwd" test ! -e "$WT/pkg/dist"
check_true "cold did not touch the main checkout" test -d "$REPO/.cache"
check_true "cold never deletes under node_modules" test -f "$WT/node_modules/foo/dist/index.js"
check_true "cold never deletes under nested node_modules (.pnpm)" test -f "$WT/node_modules/.pnpm/bar@1/node_modules/bar/dist/index.js"
check_true "cold left .git alone" test -e "$WT/.git"
check_true "ship log has failing output" grep -q "failing" "$RUNS/main/gates/all-ship-1.log"
check_exit 1 "gate run bad stage" "$ORCH" gate run U1 deploy
check_exit 0 "gate run --cmd overrides the manifest" "$ORCH" gate run U1 unit --cwd "$WT" --cmd "only=echo from-cmd"
check_contains "--cmd gate ran" "PASS only (echo from-cmd" "$LAST_OUT"
check_true "--cmd run recorded one command" test "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["cmds"]))' "$RUNS/main/gates/U1-unit-3.json")" = 1
check_exit 1 "gate run --cmd without = refused" "$ORCH" gate run U1 unit --cmd "nonsense"
check_exit 1 "gate run --cmd duplicate id refused" "$ORCH" gate run U1 unit --cmd "a=true" --cmd "a=false"
mv "$REPO/.claude/orchestrate-gates.json" "$REPO/.claude/orchestrate-gates.json.off"
cat > "$REPO/.claude/orchestrate-gates.json" <<'EOF'
{ "gates": { "unit": [ { "id": "u", "cmd": "echo unit-only" } ] } }
EOF
check_exit 0 "gate run integration falls back to the unit gates when the stage is absent" "$ORCH" gate run U1 integration
check_contains "fallback announced" "integration: no integration gates in the manifest, using the unit gates" "$LAST_OUT"
check_contains "fallback ran the unit gate" "PASS u (echo unit-only" "$LAST_OUT"
check_exit 0 "gate run ship falls back too" "$ORCH" gate run U1 ship --cwd "$WORK/wt-U2"
check_contains "ship fallback announced" "ship: no ship gates in the manifest, using the unit gates" "$LAST_OUT"
rm -f "$REPO/.claude/orchestrate-gates.json"
check_exit 1 "gate run without manifest or saved report exits 1" "$ORCH" gate run U1 unit
check_contains "prints no manifest" "no manifest" "$LAST_OUT"
check_contains "names --cmd" "--cmd <id>=<command>" "$LAST_OUT"
check_contains "names report save" "report save U1" "$LAST_OUT"
check_true "nothing recorded for the refused run" test ! -e "$RUNS/main/gates/U1-unit-4.json"
check_exit 3 "gate run without manifest with --cmd (one failing)" "$ORCH" gate run U1 unit --cwd "$WT" --cmd "ok=echo cmd-ok" --cmd "bad=exit 5"
check_contains "manifest-free --cmd PASS line" "PASS ok (echo cmd-ok → exit 0" "$LAST_OUT"
check_contains "manifest-free --cmd FAIL line" "FAIL bad (exit 5 → exit 5" "$LAST_OUT"
check_true "manifest-free run wrote the log" test -f "$RUNS/main/gates/U1-unit-4.log"
check_true "manifest-free run wrote the json" test "$(cpget result "$RUNS/main/gates/U1-unit-4.json")" = "FAIL"
check_true "log records the command source" grep -q "^# commands from: --cmd" "$RUNS/main/gates/U1-unit-4.log"
check_exit 0 "manifest-free cold run without cachePaths still passes" "$ORCH" gate run U1 unit --cold --cwd "$WT" --cmd "ok=true"
check_contains "cold without manifest says so" "no manifest, no cachePaths" "$LAST_OUT"
mv "$REPO/.claude/orchestrate-gates.json.off" "$REPO/.claude/orchestrate-gates.json"

# ---------------------------------------------------------------------------
echo "== report validate / save"
cat > "$WORK/report-ok.json" <<EOF
{
  "unit": "U1", "branch": "unit/U1", "baselineSha": "$BASE", "headSha": "$BASE",
  "commits": [], "filesChanged": ["README.md"],
  "gates": [ { "id": "ok", "cmd": "echo unit-ok", "exit": 0 } ],
  "criteria": [ { "id": "C1", "status": "PASS", "evidence": "echo unit-ok exit 0" } ],
  "deviations": [], "envVars": [], "pendingRuntimeChecks": [], "preExistingOnBase": [],
  "backgroundProcesses": "none", "notes": "ok"
}
EOF
python3 - "$WORK/report-ok.json" "$WORK/report-missing.json" "$WORK/report-running.json" "$WORK/report-gatefail.json" "$WORK/report-badid.json" <<'PY'
import json, sys
ok = json.load(open(sys.argv[1]))
m = dict(ok); del m["backgroundProcesses"]; json.dump(m, open(sys.argv[2], "w"))
r = dict(ok); r["backgroundProcesses"] = "running"; json.dump(r, open(sys.argv[3], "w"))
g = json.loads(json.dumps(ok)); g["gates"][0]["exit"] = 1; json.dump(g, open(sys.argv[4], "w"))
b = json.loads(json.dumps(ok)); b["criteria"][0]["id"] = "X1"; json.dump(b, open(sys.argv[5], "w"))
PY
check_exit 0 "report validate valid file" "$ORCH" report validate "$WORK/report-ok.json"
check_exit 1 "report validate missing backgroundProcesses" "$ORCH" report validate "$WORK/report-missing.json"
check_contains "names the missing key" "backgroundProcesses" "$LAST_OUT"
check_exit 1 "report validate backgroundProcesses running" "$ORCH" report validate "$WORK/report-running.json"
check_exit 1 "report validate gate exit 1 without FAIL criterion" "$ORCH" report validate "$WORK/report-gatefail.json"
check_exit 1 "report validate bad criterion id" "$ORCH" report validate "$WORK/report-badid.json"
check_exit 1 "report validate missing file" "$ORCH" report validate "$WORK/nope.json"
python3 - "$WORK/report-ok.json" "$WORK/report-nocriteria.json" <<'PY'
import json, sys
ok = json.load(open(sys.argv[1])); ok["criteria"] = []; json.dump(ok, open(sys.argv[2], "w"))
PY
check_exit 1 "report validate empty criteria refused (minItems 1)" "$ORCH" report validate "$WORK/report-nocriteria.json"
check_contains "names criteria" "criteria" "$LAST_OUT"
{ echo '```json'; cat "$WORK/report-ok.json"; echo '```'; } > "$WORK/report-fenced.md"
{ echo '```'; cat "$WORK/report-ok.json"; printf '```\n\n'; } > "$WORK/report-fenced-plain.md"
{ echo 'Some prose first'; echo '```json'; cat "$WORK/report-ok.json"; echo '```'; } > "$WORK/report-fenced-prose.md"
check_exit 0 "report validate accepts the worker's verbatim fenced block" "$ORCH" report validate "$WORK/report-fenced.md"
check_exit 0 "report validate accepts a fence without the json tag" "$ORCH" report validate "$WORK/report-fenced-plain.md"
check_exit 1 "report validate rejects prose around the fence" "$ORCH" report validate "$WORK/report-fenced-prose.md"
check_exit 0 "report save U1" "$ORCH" report save U1 "$WORK/report-ok.json"
check_true "saved as reports/U1-1.json" test -f "$RUNS/main/reports/U1-1.json"
check_exit 0 "report save U1 again" "$ORCH" report save U1 "$WORK/report-ok.json"
check_true "saved as reports/U1-2.json" test -f "$RUNS/main/reports/U1-2.json"
check_exit 0 "report save U1 from a fenced block" "$ORCH" report save U1 "$WORK/report-fenced.md"
check_true "saved as reports/U1-3.json" test -f "$RUNS/main/reports/U1-3.json"
check_true "saved report is a bare JSON object (fences stripped)" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["unit"]=="U1"' "$RUNS/main/reports/U1-3.json"
check_exit 1 "report save invalid not copied" "$ORCH" report save U2 "$WORK/report-running.json"
check_true "no reports/U2-1.json" test ! -e "$RUNS/main/reports/U2-1.json"
check_exit 1 "report save refuses a report for another unit" "$ORCH" report save U2 "$WORK/report-ok.json"
check_contains "mismatch names both units" 'report unit "U1" does not match U2' "$LAST_OUT"
check_true "mismatched report not copied" test ! -e "$RUNS/main/reports/U2-1.json"

echo "== gate run from the saved report (no manifest)"
mv "$REPO/.claude/orchestrate-gates.json" "$REPO/.claude/orchestrate-gates.json.off"
check_exit 0 "gate run U1 unit uses the newest saved report's gates[]" "$ORCH" gate run U1 unit --cwd "$WT"
check_contains "report gate ran" "PASS ok (echo unit-ok → exit 0" "$LAST_OUT"
check_true "log names the report as the source" grep -q "^# commands from: .*reports/U1-3.json" "$RUNS/main/gates/U1-unit-6.log"
check_true "report-sourced json recorded" test "$(cpget result "$RUNS/main/gates/U1-unit-6.json")" = "PASS"
check_exit 1 "gate run U2 unit: no report for U2 and no manifest" "$ORCH" gate run U2 unit
check_contains "U2 refusal names both options" "--cmd" "$LAST_OUT"
mv "$REPO/.claude/orchestrate-gates.json.off" "$REPO/.claude/orchestrate-gates.json"

# ---------------------------------------------------------------------------
echo "== worktree remove"
echo "dirty" >> "$WT/README.md"
check_exit 1 "worktree remove refuses modified tracked files" "$ORCH" worktree remove U1
check_true "worktree still present after refusal" test -d "$WT"
git -C "$WT" checkout -q -- README.md
check_exit 0 "worktree remove U1 (untracked bootstrap files dropped)" "$ORCH" worktree remove U1
check_true "worktree path gone" test ! -e "$WT"
check_true "deregistered (U2 remains)" test "$(cpget openWorktrees.0.unit)" = "U2"
check_exit 1 "worktree remove U1 again refused" "$ORCH" worktree remove U1
check_exit 0 "worktree remove U2" "$ORCH" worktree remove U2
check_exit 0 "worktree remove U3" "$ORCH" worktree remove U3
check_true "openWorktrees empty" test "$(cpget openWorktrees)" = "[]"

# ---------------------------------------------------------------------------
echo "== archive check"
check_exit 0 "archive check clean run" "$ORCH" archive check
cp "$CP" "$WORK/cp.backup"
python3 - "$CP" <<'PY'
import json, sys
cp = json.load(open(sys.argv[1])); cp["dispatchTally"]["used"] = 99; json.dump(cp, open(sys.argv[1], "w"))
PY
check_exit 1 "archive check: corrupted used count" "$ORCH" archive check
check_contains "finding names the tally" "dispatchTally.used=99" "$LAST_OUT"
python3 - "$CP" <<'PY'
import json, sys
cp = json.load(open(sys.argv[1])); cp["units"][0]["evidenceRef"] = ""; json.dump(cp, open(sys.argv[1], "w"))
PY
check_exit 1 "archive check: integrated without evidenceRef" "$ORCH" archive check
python3 - "$CP" <<'PY'
import json, sys
cp = json.load(open(sys.argv[1])); cp["dispatchTally"]["used"] = "five"; json.dump(cp, open(sys.argv[1], "w"))
PY
check_exit 1 "archive check: schema violation (used is a string)" "$ORCH" archive check
check_contains "finding names the schema" "checkpoint schema" "$LAST_OUT"
check_exit 1 "mutation refused on an invalid checkpoint" "$ORCH" stall record
cp "$WORK/cp.backup" "$CP"
check_exit 0 "archive check clean again after restore" "$ORCH" archive check
python3 - "$CP" <<'PY'
import json, sys
cp = json.load(open(sys.argv[1])); cp["units"][2]["status"] = "integrated"; cp["units"][2]["sha"] = cp["baselineSha"]; cp["units"][2]["evidenceRef"] = "x"; cp["units"][2]["spotCheck"] = ""; json.dump(cp, open(sys.argv[1], "w"))
PY
check_exit 1 "archive check: skipped Gate 2 without spotCheck" "$ORCH" archive check
cp "$WORK/cp.backup" "$CP"

# ---------------------------------------------------------------------------
echo "== pause / resume / status / next"
check_exit 0 "status" "$ORCH" status
check_contains "STATE line format" "STATE: integrated $BASE · tally 10/14 · next " "$LAST_OUT"
check_contains "status STOPPED-AWAITING-RESUME" "STOPPED-AWAITING-RESUME" "$LAST_OUT"
check_true "token is the last word" test "${LAST_OUT##* }" = "STOPPED-AWAITING-RESUME"
check_exit 0 "pause --reason" "$ORCH" pause --reason "surfaced U2, awaiting user"
check_true "nextAction paused" test "$(cpget nextAction)" = "paused: surfaced U2, awaiting user"
check_contains "pause prints the STATE line" "STATE: " "$LAST_OUT"
check_exit 0 "status after pause" "$ORCH" status
check_contains "paused run shows the reason in next" "· next paused: surfaced U2, awaiting user ·" "$LAST_OUT"
check_true "paused run token is STOPPED-AWAITING-RESUME (no PAUSED token)" test "${LAST_OUT##* }" = "STOPPED-AWAITING-RESUME"
case "$LAST_OUT" in *"· PAUSED"*) fail "status printed a PAUSED token" ;; *) pass "status never prints PAUSED" ;; esac
check_exit 2 "dispatch open refused while paused" "$ORCH" dispatch open U2 --role fix --epoch 2
check_contains "paused refusal names resume" "run is paused: run \`orchestrate resume\` first" "$LAST_OUT"
check_true "paused refusal did not count" test "$(cpget dispatchTally.used)" = 10
check_exit 2 "dispatch open ship refused while paused too" "$ORCH" dispatch open ship --role review --epoch 2
check_exit 1 "pause without reason" "$ORCH" pause
check_exit 0 "resume" "$ORCH" resume
check_true "resume restores dispatch <first non-integrated unit> (ship skipped)" test "$(cpget nextAction)" = "dispatch U2"
check_exit 0 "dispatch open allowed again after resume" "$ORCH" dispatch open U2 --role fix --epoch 2
check_exit 0 "dispatch close U2 2" "$ORCH" dispatch close U2 2 --exit PASS --tokens 1000 --duration 5
check_exit 0 "next set complete" "$ORCH" next set complete
check_exit 0 "status complete" "$ORCH" status
check_contains "status COMPLETED" "· COMPLETED" "$LAST_OUT"
check_true "COMPLETED is the last word" test "${LAST_OUT##* }" = "COMPLETED"
check_exit 2 "dispatch open refused when complete" "$ORCH" dispatch open U3 --role worker --epoch 2
check_exit 0 "next set integrate U2" "$ORCH" next set "integrate U2"

# ---------------------------------------------------------------------------
echo "== nextAction recompute (unit set / status / resume / archive check)"
FCP="$RUNS/flip/checkpoint.json"
check_exit 0 "init --run flip" "$ORCH" init --run flip
check_exit 0 "plan set F1" "$ORCH" --run flip plan set F1 --tier T1 --model sonnet --effort low --verifier fast
check_exit 0 "plan set F2" "$ORCH" --run flip plan set F2 --tier T1 --model sonnet --effort low --verifier fast
check_exit 0 "dispatch open F1 worker" "$ORCH" --run flip dispatch open F1 --role worker --epoch 1
check_true "flip: nextAction dispatch F1" test "$(cpget nextAction "$FCP")" = "dispatch F1"
check_exit 0 "unit set F2 integrated while F1 is in-flight" "$ORCH" --run flip unit set F2 integrated --sha "$BASE" --evidence "x"
check_true "in-flight unit leaves nextAction unchanged" test "$(cpget nextAction "$FCP")" = "dispatch F1"
check_exit 0 "pause flip" "$ORCH" --run flip pause --reason "hold"
check_exit 0 "unit set F2 pending while paused" "$ORCH" --run flip unit set F2 pending
check_true "paused run is not overridden by unit set" test "$(cpget nextAction "$FCP")" = "paused: hold"
check_exit 0 "resume flip (F1 still in-flight)" "$ORCH" --run flip resume
check_true "resume dispatches the in-flight unit" test "$(cpget nextAction "$FCP")" = "dispatch F1"
check_exit 0 "dispatch close F1 1" "$ORCH" --run flip dispatch close F1 1 --exit PASS --tokens 100 --duration 1
check_exit 0 "unit set F1 integrated" "$ORCH" --run flip unit set F1 integrated --sha "$BASE" --evidence "x"
check_true "after F1: dispatch F2 (pending)" test "$(cpget nextAction "$FCP")" = "dispatch F2"
check_exit 0 "unit set F2 failed (last open unit)" "$ORCH" --run flip unit set F2 failed
check_true "last unit closed flips nextAction to ship-gate" test "$(cpget nextAction "$FCP")" = "ship-gate"
check_exit 0 "status on a ship-gate run" "$ORCH" --run flip status
check_contains "ship-gate shown in next" "· next ship-gate ·" "$LAST_OUT"
check_true "ship-gate token is COMPLETED" test "${LAST_OUT##* }" = "COMPLETED"
check_exit 0 "unit set ship integrated" "$ORCH" --run flip unit set ship integrated
check_true "unit set ship never moves nextAction" test "$(cpget nextAction "$FCP")" = "ship-gate"
check_exit 0 "pause flip again" "$ORCH" --run flip pause --reason "hold again"
check_exit 0 "status while paused" "$ORCH" --run flip status
check_true "paused token is STOPPED-AWAITING-RESUME" test "${LAST_OUT##* }" = "STOPPED-AWAITING-RESUME"
check_exit 0 "resume with every unit closed" "$ORCH" --run flip resume
check_true "resume sets ship-gate when no unit is pending/in-flight" test "$(cpget nextAction "$FCP")" = "ship-gate"
check_exit 0 "archive check: ship-gate with a failed unit is fine" "$ORCH" --run flip archive check
check_exit 0 "next set complete" "$ORCH" --run flip next set complete
check_exit 0 "unit set F2 pending on a complete run" "$ORCH" --run flip unit set F2 pending
check_true "complete run is not overridden by unit set" test "$(cpget nextAction "$FCP")" = "complete"
check_exit 1 "archive check: pending unit in a complete run" "$ORCH" --run flip archive check
check_contains "finding names the open unit" "unit F2 is pending in a complete run" "$LAST_OUT"
check_exit 0 "unit set F2 surfaced" "$ORCH" --run flip unit set F2 surfaced
check_exit 0 "archive check: surfaced unit in a complete run is fine" "$ORCH" --run flip archive check

# ---------------------------------------------------------------------------
echo "== harness set (probe result)"
check_exit 0 "harness set dispatch foreground" "$ORCH" harness set dispatch foreground
check_true "harness.dispatch foreground" test "$(cpget harness.dispatch)" = "foreground"
check_exit 0 "harness set dispatch background" "$ORCH" harness set dispatch background
check_true "harness.dispatch background" test "$(cpget harness.dispatch)" = "background"
check_exit 1 "harness set dispatch bogus value refused" "$ORCH" harness set dispatch inline
check_true "bogus value left dispatch unchanged" test "$(cpget harness.dispatch)" = "background"
check_exit 1 "harness set unknown key refused" "$ORCH" harness set spawnDepth 1

# ---------------------------------------------------------------------------
echo "== stale"
check_exit 0 "stale: fresh checkpoint" "$ORCH" stale
check_exit 0 "stale --minutes 1: fresh" "$ORCH" stale --minutes 1
touch -t 202001010000 "$CP"
check_exit 2 "stale: old checkpoint" "$ORCH" stale
check_exit 2 "stale --minutes 5: old" "$ORCH" stale --minutes 5
check_exit 0 "mutation refreshes mtime" "$ORCH" stall record
check_exit 0 "stale after write: fresh" "$ORCH" stale

# ---------------------------------------------------------------------------
echo "== cost"
check_exit 0 "cost" "$ORCH" cost
check_contains "cost totals dispatches (incl. ship-gate round)" "COST: 11 dispatches" "$LAST_OUT"
check_contains "cost totals tokens" "68000 tokens" "$LAST_OUT"
check_contains "cost USD from manifest pricing" "USD" "$LAST_OUT"
check_contains "cost sonnet USD (21000 tok at 6/MTok = 0.13)" "USD 0.13" "$LAST_OUT"
check_contains "cost lists opus (ship dispatches)" "opus" "$LAST_OUT"
mv "$REPO/.claude/orchestrate-gates.json" "$REPO/.claude/orchestrate-gates.json.off"
check_exit 0 "cost without manifest" "$ORCH" cost
check_contains "no USD without pricing" "USD n/a" "$LAST_OUT"
cat > "$REPO/.claude/orchestrate-gates.json" <<'EOF'
{ "gates": { "unit": [] }, "pricing": { "sonnet": { "inPerMTok": 0, "outPerMTok": 0, "perMTok": 0 }, "opus": {}, "haiku": {} } }
EOF
check_exit 0 "cost with zero-valued pricing" "$ORCH" cost
check_contains "zero rates are not pricing: USD n/a" "USD n/a" "$LAST_OUT"
case "$LAST_OUT" in *"USD 0.00"*) fail "zero pricing printed USD 0.00" ;; *) pass "no false USD 0.00" ;; esac
rm -f "$REPO/.claude/orchestrate-gates.json"
mv "$REPO/.claude/orchestrate-gates.json.off" "$REPO/.claude/orchestrate-gates.json"

# ---------------------------------------------------------------------------
echo "== lock"
mkdir -p "$RUNS/main/.lock"
touch -t 202001010000 "$RUNS/main/.lock"
check_exit 0 "stale lock (>30 s) is recovered" "$ORCH" stall record
check_true "lock released" test ! -e "$RUNS/main/.lock"

# ---------------------------------------------------------------------------
echo "== run selection"
unset ORCHESTRATE_RUN
check_exit 0 "newest checkpoint selected without --run" "$ORCH" status
check_exit 0 "--run capped selects that run" "$ORCH" --run capped status
check_contains "capped run shows its pause reason" "next paused: cap reached" "$LAST_OUT"
check_true "capped run token is STOPPED-AWAITING-RESUME" test "${LAST_OUT##* }" = "STOPPED-AWAITING-RESUME"
check_exit 1 "--run nonexistent" "$ORCH" --run nope status
check_exit 0 "--root from outside the repo" "$ORCH" --root "$REPO" --run capped status
cd "$WORK"
check_exit 1 "outside a repo without --root" "$ORCH" status
cd "$REPO"

echo "== preflight wrapper"
if [ -f "$PLUGIN_ROOT/scripts/preflight.sh" ]; then
  "$ORCH" preflight --json > /dev/null 2>&1
  rc=$?
  case "$rc" in 0|2) pass "preflight exits 0 or 2 (got $rc)" ;; *) fail "preflight exited $rc" ;; esac
else
  check_exit 1 "preflight without scripts/preflight.sh exits 1" "$ORCH" preflight
fi

# ---------------------------------------------------------------------------
# v0.6.1: report save artifacts (P1), worktree sync (P2), docs apply (P3), push (P4)
# ---------------------------------------------------------------------------
echo "== v0.6.1 setup (run v061)"
cd "$REPO"
check_exit 0 "help lists worktree sync" "$ORCH" help
check_contains "help: worktree sync" "worktree sync <unit>" "$LAST_OUT"
check_contains "help: docs apply" "docs apply <unit>" "$LAST_OUT"
check_contains "help: push" "push <unit> [--pr] [--no-wait]" "$LAST_OUT"
check_contains "help: report save --run-criteria" "--run-criteria C1,C2" "$LAST_OUT"
check_exit 0 "init --run v061" "$ORCH" init --run v061
export ORCHESTRATE_RUN=v061
VCP="$RUNS/v061/checkpoint.json"
VLOG="$RUNS/v061/dispatch-log.md"
for u in R1 R2 S1 D1 P1 P2; do "$ORCH" plan set $u --tier T1 --model sonnet --effort low --verifier fast > /dev/null || fail "plan set $u"; done
unit_field() { python3 -c 'import json,sys; cp=json.load(open(sys.argv[1])); u=[x for x in cp["units"] if x["id"]==sys.argv[2]][0]; n=u
for p in sys.argv[3].split("."): n=n[p]
print(n if isinstance(n,str) else json.dumps(n))' "$VCP" "$1" "$2"; }
wt_field() { python3 -c 'import json,sys; cp=json.load(open(sys.argv[1])); w=[x for x in cp["openWorktrees"] if x["unit"]==sys.argv[2]][0]; print(w.get(sys.argv[3],""))' "$VCP" "$1" "$2"; }

# ---------------------------------------------------------------------------
echo "== report save: [run] artifacts"
check_exit 0 "worktree add R1" "$ORCH" worktree add R1 --at "$BASE" --no-bootstrap --path "$WORK/wt-R1"
cat > "$WORK/report-run.json" <<EOF
{
  "unit": "R1", "branch": "unit/R1", "baselineSha": "$BASE", "headSha": "$BASE",
  "commits": [], "filesChanged": ["README.md"],
  "gates": [ { "id": "ok", "cmd": "echo unit-ok", "exit": 0 } ],
  "criteria": [
    { "id": "C1", "status": "PASS", "evidence": "18 scenarios, 18 passed, 0 failed; log at out/test.log", "artifact": "out/test.log", "runCmd": "npm test" },
    { "id": "C2", "status": "PASS", "evidence": "reviewed" },
    { "id": "C3", "status": "FAIL", "evidence": "flaky", "artifact": "out/missing.log", "runCmd": "npm run e2e" }
  ],
  "deviations": [], "backgroundProcesses": "none"
}
EOF
check_exit 0 "report validate accepts artifact/runCmd fields" "$ORCH" report validate "$WORK/report-run.json"
check_exit 1 "report save: PASS artifact missing under the registered worktree" "$ORCH" report save R1 "$WORK/report-run.json"
check_contains "refusal names the criterion" "C1" "$LAST_OUT"
check_contains "refusal says not found" "not found" "$LAST_OUT"
check_true "nothing saved for R1" test ! -e "$RUNS/v061/reports/R1-1.json"
mkdir -p "$WORK/wt-R1/out" && : > "$WORK/wt-R1/out/test.log"
check_exit 1 "report save: empty artifact refused" "$ORCH" report save R1 "$WORK/report-run.json"
check_contains "refusal says empty" "empty" "$LAST_OUT"
printf '18 scenarios\n18 passed\n0 failed\n' > "$WORK/wt-R1/out/test.log"
check_exit 0 "report save: artifact present and non-empty" "$ORCH" report save R1 "$WORK/report-run.json"
check_contains "artifacts line printed" "artifacts: 1 file(s) copied" "$LAST_OUT"
check_true "path printed last" test "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "$RUNS/v061/reports/R1-1.json"
check_true "saved reports/R1-1.json" test -f "$RUNS/v061/reports/R1-1.json"
check_true "artifact copied under reports/R1-1-artifacts/" test -f "$RUNS/v061/reports/R1-1-artifacts/out/test.log"
check_true "copied artifact has the run output" grep -q "18 passed" "$RUNS/v061/reports/R1-1-artifacts/out/test.log"
check_true "FAIL criterion's missing artifact is not copied (and not required)" test ! -e "$RUNS/v061/reports/R1-1-artifacts/out/missing.log"
check_exit 1 "--run-criteria C2: PASS without artifact refused" "$ORCH" report save R1 "$WORK/report-run.json" --run-criteria C2
check_contains "names C2" "C2" "$LAST_OUT"
check_contains "explains the [run] contract" "artifact + runCmd" "$LAST_OUT"
check_true "refused save left no R1-2" test ! -e "$RUNS/v061/reports/R1-2.json"
check_exit 0 "--run-criteria C1: artifact + runCmd present" "$ORCH" report save R1 "$WORK/report-run.json" --run-criteria C1
check_true "saved reports/R1-2.json with artifacts dir" test -f "$RUNS/v061/reports/R1-2.json" -a -f "$RUNS/v061/reports/R1-2-artifacts/out/test.log"
check_exit 1 "--run-criteria C9: unknown criterion refused" "$ORCH" report save R1 "$WORK/report-run.json" --run-criteria C9
python3 - "$WORK/report-run.json" "$WORK/report-norun.json" "$WORK/report-abs.json" <<'PY'
import json, sys
ok = json.load(open(sys.argv[1]))
d = json.loads(json.dumps(ok)); del d["criteria"][0]["runCmd"]; json.dump(d, open(sys.argv[2], "w"))
a = json.loads(json.dumps(ok)); a["criteria"][0]["artifact"] = "/etc/hosts"; json.dump(a, open(sys.argv[3], "w"))
PY
check_exit 1 "--run-criteria C1 without runCmd refused" "$ORCH" report save R1 "$WORK/report-norun.json" --run-criteria C1
check_contains "names runCmd" "runCmd" "$LAST_OUT"
check_exit 0 "artifact without runCmd is fine when not listed as [run]" "$ORCH" report save R1 "$WORK/report-norun.json"
check_exit 1 "absolute artifact path refused" "$ORCH" report save R1 "$WORK/report-abs.json"
check_contains "says repo-relative" "repo-relative" "$LAST_OUT"
mkdir -p "$WORK/other-wt"
check_exit 1 "--worktree <dir> without the artifact refused" "$ORCH" report save R1 "$WORK/report-run.json" --worktree "$WORK/other-wt"
sed 's/"unit": "R1"/"unit": "R2"/; s#unit/R1#unit/R2#' "$WORK/report-run.json" > "$WORK/report-run-R2.json"
check_exit 1 "unit without a worktree: artifact looked up in the cwd (absent here)" "$ORCH" report save R2 "$WORK/report-run-R2.json"
cd "$WORK/wt-R1"
check_exit 0 "unit without a worktree: artifact found in the cwd (--root names the integration root)" "$ORCH" --root "$REPO" report save R2 "$WORK/report-run-R2.json"
check_true "R2 artifact copied" test -f "$RUNS/v061/reports/R2-1-artifacts/out/test.log"
cd "$REPO"

# ---------------------------------------------------------------------------
echo "== worktree sync"
check_exit 1 "worktree sync unknown unit" "$ORCH" worktree sync S9
check_exit 0 "worktree add S1 (bootstrapped)" "$ORCH" worktree add S1 --at "$BASE" --path "$WORK/wt-S1"
WTS="$WORK/wt-S1"
check_true "S1 bootstrap ran once" test "$(grep -c env "$WTS/bootstrap.txt")" = 1 -a "$(grep -c install "$WTS/bootstrap.txt")" = 1
echo "main change 1" > main-note.txt && git add main-note.txt && git commit -q -m "main: note"
MAIN1=$(git rev-parse HEAD)
check_exit 0 "worktree sync S1: no lockfile change" "$ORCH" worktree sync S1
check_true "prints <wt> merged <sha> install:skipped gates:skipped" test "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "$WTS merged $MAIN1 install:skipped gates:skipped"
check_true "worktree contains the integration tip" git -C "$WTS" merge-base --is-ancestor "$MAIN1" HEAD
check_true "envBootstrap re-ran, install skipped" test "$(grep -c env "$WTS/bootstrap.txt")" = 2 -a "$(grep -c install "$WTS/bootstrap.txt")" = 1
check_true "syncedTo recorded" test "$(wt_field S1 syncedTo)" = "$MAIN1"
check_true "syncedAt recorded" test -n "$(wt_field S1 syncedAt)"
check_true "dispatch-log has the sync line" grep -q "worktree sync S1: merged main@$MAIN1" "$VLOG"
check_exit 0 "archive check accepts syncedAt/syncedTo" "$ORCH" archive check
echo '{"lockfileVersion": 3}' > package-lock.json && git add package-lock.json && git commit -q -m "main: lockfile"
MAIN2=$(git rev-parse HEAD)
check_exit 0 "worktree sync S1 --gate: lockfile changed" "$ORCH" worktree sync S1 --gate
check_contains "install ran, gates PASS" "$WTS merged $MAIN2 install:ran gates:PASS" "$LAST_OUT"
check_contains "gate output shown" "PASS ok (echo unit-ok" "$LAST_OUT"
check_true "install re-ran after the lockfile change" test "$(grep -c install "$WTS/bootstrap.txt")" = 2
check_true "gate run recorded under gates/" test -f "$RUNS/v061/gates/S1-unit-1.json"
check_true "syncedTo bumped" test "$(wt_field S1 syncedTo)" = "$MAIN2"
check_exit 0 "worktree sync S1 --force-install without changes" "$ORCH" worktree sync S1 --force-install
check_contains "forced install ran" "install:ran gates:skipped" "$LAST_OUT"
check_true "install count 3" test "$(grep -c install "$WTS/bootstrap.txt")" = 3
echo '{"lockfileVersion": 3, "x": 1}' > package-lock.json && git add package-lock.json && git commit -q -m "main: lockfile 2"
check_exit 0 "worktree sync S1 --no-bootstrap" "$ORCH" worktree sync S1 --no-bootstrap
check_contains "--no-bootstrap skips install even with a lockfile change" "install:skipped" "$LAST_OUT"
check_true "no bootstrap ran (env 4, install 3 as before)" test "$(grep -c env "$WTS/bootstrap.txt")" = 4 -a "$(grep -c install "$WTS/bootstrap.txt")" = 3
# conflict: both sides edit the first line of README.md
echo "unit side" > "$WTS/README.md" && git -C "$WTS" commit -q -am "S1: readme"
S1HEAD=$(git -C "$WTS" rev-parse HEAD)
echo "main side" > README.md && git commit -q -am "main: readme"
check_exit 3 "worktree sync S1: conflict exits 3" "$ORCH" worktree sync S1
check_contains "conflict names the file" "conflict: README.md" "$LAST_OUT"
check_true "merge aborted: HEAD unchanged" test "$(git -C "$WTS" rev-parse HEAD)" = "$S1HEAD"
check_true "no merge in progress" test ! -e "$(git -C "$WTS" rev-parse --git-path MERGE_HEAD)"
check_true "worktree clean after the abort" test -z "$(git -C "$WTS" status --porcelain --untracked-files=no)"
check_true "conflict did not touch bootstrap" test "$(grep -c env "$WTS/bootstrap.txt")" = 4 -a "$(grep -c install "$WTS/bootstrap.txt")" = 3
git checkout -q "$MAIN2" -- README.md 2>/dev/null; echo "unit side" > README.md && git commit -q -am "main: take the unit side"
mv "$REPO/.claude/orchestrate-gates.json" "$REPO/.claude/orchestrate-gates.json.off"
cat > "$REPO/.claude/orchestrate-gates.json" <<'EOF'
{ "install": "echo install >> bootstrap.txt", "envBootstrap": "echo env >> bootstrap.txt",
  "gates": { "unit": [ { "id": "bad", "cmd": "echo sync-gate-fails; exit 9" } ] } }
EOF
check_exit 3 "worktree sync S1 --gate: gate FAIL exits 3" "$ORCH" worktree sync S1 --gate
check_contains "summary says gates:FAIL" "install:skipped gates:FAIL" "$LAST_OUT"
mv "$REPO/.claude/orchestrate-gates.json.off" "$REPO/.claude/orchestrate-gates.json"

# ---------------------------------------------------------------------------
echo "== docs apply"
mkdir -p docs/_pending docs/_e2e
cat > docs/features.md <<'EOF'
# Features

## Changes

- existing bullet

```
## not a heading (inside a fence)
```

## Other

other text
EOF
cat > docs/e2e.md <<'EOF'
# E2E

## Scenarios

- login
EOF
git add docs && git commit -q -m "docs targets"
printf '# Login flow\n\nAdded login.\n\n- bullet one\n- bullet two\n' > docs/_pending/D1.md
printf '# Extra\n\nmore\n' > docs/_pending/D1-extra.md
printf '# Login scenarios\n\n- login happy path\n- login lockout\n' > docs/_e2e/D1.md
mv "$REPO/.claude/orchestrate-gates.json" "$REPO/.claude/orchestrate-gates.json.off"
check_exit 1 "docs apply without a manifest exits 1" "$ORCH" docs apply D1
check_contains "names the missing manifest" "no manifest" "$LAST_OUT"
mv "$REPO/.claude/orchestrate-gates.json.off" "$REPO/.claude/orchestrate-gates.json"
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["docs"] = [
  {"fragments": "docs/_pending", "target": "docs/features.md", "section": "## Changes"},
  {"fragments": "docs/_e2e", "target": "docs/e2e.md", "section": "## Scenarios"},
]
json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
check_exit 0 "manifest with docs validates" schema_validate "$PLUGIN_ROOT/schemas/gates-manifest.schema.json" "$REPO/.claude/orchestrate-gates.json"
SUM_BEFORE=$(cat docs/features.md docs/e2e.md | cksum)
check_exit 0 "docs apply D1 --dry-run" "$ORCH" docs apply D1 --dry-run
check_contains "dry run shows the diff" "+### D1: Login flow" "$LAST_OUT"
check_contains "dry run summary (2 features + 1 e2e fragments)" "3 inserted, 0 skipped (dry run" "$LAST_OUT"
check_true "dry run wrote nothing" test "$(cat docs/features.md docs/e2e.md | cksum)" = "$SUM_BEFORE"
check_true "dry run kept the fragments" test -f docs/_pending/D1.md -a -f docs/_pending/D1-extra.md -a -f docs/_e2e/D1.md
check_true "dry run wrote no log line" test "$(grep -c 'docs apply D1' "$VLOG")" = 0
check_exit 0 "docs apply D1" "$ORCH" docs apply D1
check_contains "apply summary" "docs apply D1: 3 inserted, 0 skipped" "$LAST_OUT"
check_true "fragments deleted" test ! -e docs/_pending/D1.md -a ! -e docs/_pending/D1-extra.md -a ! -e docs/_e2e/D1.md
check_true "features.md: both fragments inserted in order at the end of ## Changes, before ## Other" python3 - docs/features.md <<'PY'
import sys
t = open(sys.argv[1]).read()
i = [t.index(x) for x in ("- existing bullet", "## not a heading", "### D1: Login flow", "- bullet two", "### D1: Extra", "more", "## Other")]
assert i == sorted(i), i
assert "### D1: Login flow\n\nAdded login.\n\n- bullet one\n- bullet two\n\n### D1: Extra\n\nmore\n\n## Other" in t, t
PY
check_true "e2e.md: inserted at EOF with a single trailing newline" python3 - docs/e2e.md <<'PY'
import sys
t = open(sys.argv[1]).read()
assert t.endswith("- login\n\n### D1: Login scenarios\n\n- login happy path\n- login lockout\n"), repr(t)
assert not t.endswith("\n\n")
PY
check_true "dispatch-log has the docs line" grep -q "docs apply D1 in $REPO: docs apply D1: 3 inserted" "$VLOG"
SUM_AFTER=$(cat docs/features.md docs/e2e.md | cksum)
printf '# Login flow\n\nAdded login again.\n' > docs/_pending/D1.md
check_exit 0 "docs apply D1 again (idempotent)" "$ORCH" docs apply D1
check_contains "second run skipped" "already has ### D1:" "$LAST_OUT"
check_contains "summary counts the skip" "0 inserted, 1 skipped" "$LAST_OUT"
check_true "targets unchanged on the second run" test "$(cat docs/features.md docs/e2e.md | cksum)" = "$SUM_AFTER"
check_true "skipped fragment left in place" test -f docs/_pending/D1.md
rm -f docs/_pending/D1.md
check_exit 0 "docs apply D2: no fragment" "$ORCH" docs apply D2
check_contains "no-fragment notice" "no fragment docs/_pending/D2.md" "$LAST_OUT"
printf '# Bad\n\ntext\n\n## Splits the section\n' > docs/_pending/D2.md
check_exit 1 "fragment with a heading at the section level refused" "$ORCH" docs apply D2
check_contains "names the heading" "## Splits the section" "$LAST_OUT"
check_true "refused fragment kept" test -f docs/_pending/D2.md
rm -f docs/_pending/D2.md
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["docs"][0]["section"] = "## Missing"; json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
printf '# X\n\nx\n' > docs/_pending/D2.md
check_exit 1 "missing section exits 1" "$ORCH" docs apply D2
check_contains "names the section and target" 'section "## Missing" not found in docs/features.md' "$LAST_OUT"
check_true "missing section: fragment kept, target unchanged" test -f docs/_pending/D2.md -a "$(cat docs/features.md docs/e2e.md | cksum)" = "$SUM_AFTER"
rm -f docs/_pending/D2.md
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); del m["docs"]; json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
check_exit 0 "docs apply with no docs entries: notice, exit 0" "$ORCH" docs apply D1
check_contains "no-entries notice" "no docs entries" "$LAST_OUT"
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["docs"] = [{"fragments": "docs/_pending", "target": "docs/features.md", "section": "## Changes"}]; json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
mkdir -p "$WORK/int-wt" && git worktree add -q "$WORK/int-wt" -b integration-copy HEAD
mkdir -p "$WORK/int-wt/docs/_pending" && printf '# From cwd\n\nbody\n' > "$WORK/int-wt/docs/_pending/D1.md"
check_exit 0 "docs apply --cwd <integration worktree>" "$ORCH" docs apply D1 --cwd "$WORK/int-wt"
check_true "--cwd target updated" grep -q "### D1: From cwd" "$WORK/int-wt/docs/features.md"
check_true "--cwd left the root checkout alone" test "$(cat docs/features.md docs/e2e.md | cksum)" = "$SUM_AFTER"
git worktree remove --force "$WORK/int-wt"
# a "###" section gets a "####" unit heading (one level below the section), never a "###" that would split it (Codex P2, v0.6.1)
printf '# Deep\n\n## Area\n\n### Notes\n\nkeep\n\n### Later\n\nlater\n' > docs/deep.md
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["docs"] = [{"fragments": "docs/_pending", "target": "docs/deep.md", "section": "### Notes"}]; json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
printf '# Deep note\n\ndeep body\n' > docs/_pending/D1.md
check_exit 0 "docs apply into a ### section" "$ORCH" docs apply D1
check_true "unit heading is one level below (####)" grep -q "^#### D1: Deep note" docs/deep.md
check_true "### Later section still follows the insert" python3 - docs/deep.md <<'PY'
import sys
t = open(sys.argv[1]).read()
assert t.index("#### D1: Deep note") < t.index("### Later"), t
assert "deep body" in t
PY

# ---------------------------------------------------------------------------
echo "== push"
git init -q --bare "$WORK/origin.git"
git remote add origin "$WORK/origin.git"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'EOF'
#!/usr/bin/env bash
# stub gh: records its arguments; behaviour per env (GH_PR_EXISTS: pr view exit, GH_CHECKS_EXIT: pr checks exit)
printf '%s\n' "$*" >> "${GH_LOG:?}"
last=""; for last; do :; done
case "${1:-} ${2:-}" in
  "pr view") exit "${GH_PR_EXISTS:-1}" ;;
  "pr create") echo "https://example.invalid/pull/1"; exit 0 ;;
  "pr checks") echo "stub checks for $last"; sleep "${GH_CHECKS_SLEEP:-0}"; exit "${GH_CHECKS_EXIT:-0}" ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/gh"
export GH_LOG="$WORK/gh.log"; : > "$GH_LOG"
check_exit 0 "worktree add P1" "$ORCH" worktree add P1 --at "$BASE" --no-bootstrap --path "$WORK/wt-P1"
check_exit 0 "worktree add P2" "$ORCH" worktree add P2 --at "$BASE" --no-bootstrap --path "$WORK/wt-P2"
echo "p1" > "$WORK/wt-P1/p1.txt" && git -C "$WORK/wt-P1" add p1.txt && git -C "$WORK/wt-P1" commit -q -m "P1 work"
echo "p2" > "$WORK/wt-P2/p2.txt" && git -C "$WORK/wt-P2" add p2.txt && git -C "$WORK/wt-P2" commit -q -m "P2 work"
check_exit 1 "push unknown unit" "$ORCH" push P9
check_exit 0 "push P1 without ci in the manifest (no gh needed)" env ORCHESTRATE_GH=/nonexistent/gh "$ORCH" push P1
check_contains "prints branch pushed, checks skipped" "unit/P1 pushed pr:none checks:skipped" "$LAST_OUT"
check_true "origin has unit/P1" git -C "$WORK/origin.git" rev-parse --verify --quiet refs/heads/unit/P1
check_true "push recorded on the unit" test "$(unit_field P1 push.branch)" = "unit/P1" -a "$(unit_field P1 push.checks)" = "skipped" -a -n "$(unit_field P1 push.at)"
check_exit 0 "archive check accepts the push record" "$ORCH" archive check
check_exit 1 "push --pr without gh" env ORCHESTRATE_GH=/nonexistent/gh "$ORCH" push P1 --pr
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["ci"] = {"serial": True, "checksCmd": "gh pr checks --watch --fail-fast"}; json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
check_exit 0 "manifest with ci validates" schema_validate "$PLUGIN_ROOT/schemas/gates-manifest.schema.json" "$REPO/.claude/orchestrate-gates.json"
check_exit 2 "ci.serial without gh: refused (exit 2)" env ORCHESTRATE_GH=/nonexistent/gh "$ORCH" push P2 --pr
check_contains "refusal explains" "ci.serial" "$LAST_OUT"
check_true "refused push did not push" test -z "$(git -C "$WORK/origin.git" rev-parse --verify --quiet refs/heads/unit/P2)"
check_exit 0 "push P2 --pr under ci.serial (stub gh on PATH)" env PATH="$WORK/bin:$PATH" "$ORCH" push P2 --pr
check_contains "pr created, checks pass" "unit/P2 pushed pr:created checks:pass" "$LAST_OUT"
check_contains "PR url printed" "https://example.invalid/pull/1" "$LAST_OUT"
check_true "origin has unit/P2" git -C "$WORK/origin.git" rev-parse --verify --quiet refs/heads/unit/P2
check_true "gh pr create --fill --base main" grep -q "^pr create --fill --base main" "$GH_LOG"
check_true "checksCmd ran on the branch" grep -q "^pr checks --watch --fail-fast unit/P2$" "$GH_LOG"
check_true "push.checks pass, pr recorded" test "$(unit_field P2 push.checks)" = "pass" -a "$(unit_field P2 push.pr)" = "https://example.invalid/pull/1"
check_true "checks log written" grep -q "stub checks for unit/P2" "$RUNS/v061/gates/P2-checks.log"
check_true "dispatch-log has the push line" grep -q "push P2: unit/P2 pushed to origin, pr:created" "$VLOG"
check_exit 0 "push P2 --pr again: existing PR is reused" env PATH="$WORK/bin:$PATH" GH_PR_EXISTS=0 "$ORCH" push P2 --pr
check_contains "pr existing" "pr:existing checks:pass" "$LAST_OUT"
check_true "no second pr create" test "$(grep -c "^pr create" "$GH_LOG")" = 1
check_exit 3 "push P2: failing checks exit 3" env PATH="$WORK/bin:$PATH" GH_CHECKS_EXIT=1 "$ORCH" push P2
check_contains "checks fail printed" "checks:fail" "$LAST_OUT"
check_true "push.checks fail" test "$(unit_field P2 push.checks)" = "fail"
python3 - "$VCP" <<'PY'
import json, sys
cp = json.load(open(sys.argv[1]))
for u in cp["units"]:
    if u["id"] == "P2": u["push"]["checks"] = "running"
json.dump(cp, open(sys.argv[1], "w"))
PY
check_exit 2 "push P1 while P2 checks are running: refused" env PATH="$WORK/bin:$PATH" "$ORCH" push P1 --pr
check_contains "refusal names the running unit" "unit P2" "$LAST_OUT"
check_true "P1 record untouched" test "$(unit_field P1 push.checks)" = "skipped"
check_exit 0 "push P2 --no-wait re-pushes the running unit itself" env PATH="$WORK/bin:$PATH" "$ORCH" push P2 --no-wait
check_contains "no-wait records pending" "checks:pending" "$LAST_OUT"
check_true "push.checks pending" test "$(unit_field P2 push.checks)" = "pending"
check_exit 0 "push P1 --pr --no-wait once P2 is no longer running" env PATH="$WORK/bin:$PATH" "$ORCH" push P1 --pr --no-wait
check_contains "P1 pr created, pending" "unit/P1 pushed pr:created checks:pending" "$LAST_OUT"
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["ci"] = {"serial": True}; json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
# atomic claim: a second push must be refused while the first one is still watching its checks (Codex P1, v0.6.1)
( env PATH="$WORK/bin:$PATH" GH_CHECKS_SLEEP=4 "$ORCH" push P2 > "$WORK/push-bg.out" 2>&1 ) &
_bg=$!
sleep 1.5
check_exit 2 "concurrent push P1 while P2's watch is live: refused (claim is atomic)" env PATH="$WORK/bin:$PATH" "$ORCH" push P1
check_true "P1 not pushed by the refused call" test "$(unit_field P1 push.checks)" = "pending"
wait $_bg
check_true "background push P2 finished with checks pass" grep -q "checks:pass" "$WORK/push-bg.out"
check_true "P2 recorded pass after the watch" test "$(unit_field P2 push.checks)" = "pass"
check_exit 0 "push P1 with the default checksCmd" env PATH="$WORK/bin:$PATH" "$ORCH" push P1
check_true "default checksCmd is gh pr checks --watch <branch>" grep -q "^pr checks --watch unit/P1$" "$GH_LOG"
check_true "push.checks pass" test "$(unit_field P1 push.checks)" = "pass"
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["ci"] = {"serial": False}; json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
check_exit 0 "ci.serial false: push without gh, checks skipped" env ORCHESTRATE_GH=/nonexistent/gh "$ORCH" push P1
check_contains "serial false skips checks" "checks:skipped" "$LAST_OUT"
check_exit 0 "archive check after the v0.6.1 round" "$ORCH" archive check
unset ORCHESTRATE_RUN GH_LOG

# ---------------------------------------------------------------------------
# v0.6.2: plan show (T), report save from stdin (6a), contract new / verify (6b), integrate (6c), init mode (8a), help (8e)
# ---------------------------------------------------------------------------
echo "== v0.6.2 setup (run v062)"
cd "$REPO"
cat > "$REPO/.claude/orchestrate-gates.json" <<'EOF'
{
  "install": "echo install >> bootstrap.txt", "envBootstrap": "echo env >> bootstrap.txt",
  "cachePaths": [".cache"],
  "gates": {
    "unit": [ { "id": "ok", "cmd": "echo unit-ok" }, { "id": "baseline", "cmd": "git rev-parse --verify {{baseline}} > /dev/null" } ],
    "integration": [ { "id": "ok", "cmd": "true" } ]
  },
  "docs": [ { "fragments": "docs/_pending", "target": "docs/features.md", "section": "## Changes" } ]
}
EOF
git add .claude/orchestrate-gates.json docs && git commit -q -m "v062 setup" && git checkout -q main
BASE_V=$(git rev-parse HEAD)
check_true "root is on main and clean before the v0.6.2 round" test "$(git rev-parse --abbrev-ref HEAD)" = main -a -z "$(git status --porcelain --untracked-files=no)"
check_exit 0 "help lists the v0.6.2 commands" "$ORCH" help
check_contains "help header names the worktree location (8e)" "Worktrees: <root>/.claude/worktrees/<unit> (git-excluded" "$LAST_OUT"
check_contains "help: worktree add names its default path" "git worktree add at <root>/.claude/worktrees/<unit>" "$LAST_OUT"
check_contains "help: init --mode defaults to DIRECT (8a)" "--mode defaults to" "$LAST_OUT"
check_contains "help: plan show" "plan show" "$LAST_OUT"
check_contains "help: report save accepts -" "report save <unit> <file>|-" "$LAST_OUT"
check_contains "help: contract new" "contract new <unit> [--objective <text>] [--files <csv>] [--force]" "$LAST_OUT"
check_contains "help: contract verify" "contract verify <unit> --head <sha> [--deep] [--since <sha>] [--prior <ref>] [--scope C1,C3]" "$LAST_OUT"
check_contains "help: integrate" "integrate <unit> [--cold] [--no-sync] [--no-docs]" "$LAST_OUT"
check_true "example manifest carries the \$comment_gates rule (8d)" grep -q '"\$comment_gates"' "$PLUGIN_ROOT/examples/orchestrate-gates.json"
check_contains "example \$comment_gates says baseline + --depends" "--depends" "$(grep '"\$comment_gates"' "$PLUGIN_ROOT/examples/orchestrate-gates.json")"

echo "== init prints the mode"
check_exit 0 "init --run v062 (default mode)" "$ORCH" init --run v062
check_true "init prints mode: DIRECT first" test "$(printf '%s\n' "$LAST_OUT" | head -1)" = "mode: DIRECT"
check_true "init still prints the run id last" test "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "v062"
check_true "init prints the archive path second" test "$(printf '%s\n' "$LAST_OUT" | sed -n 2p)" = "$RUNS/v062"
check_true "default mode recorded as DIRECT" test "$(cpget dispatchMode "$RUNS/v062/checkpoint.json")" = "DIRECT"
check_exit 0 "init --run v062f --mode FOREMAN" "$ORCH" init --run v062f --mode FOREMAN
check_true "init prints mode: FOREMAN" test "$(printf '%s\n' "$LAST_OUT" | head -1)" = "mode: FOREMAN"
export ORCHESTRATE_RUN=v062
XCP="$RUNS/v062/checkpoint.json"
XLOG="$RUNS/v062/dispatch-log.md"
XARCH="$RUNS/v062"
xunit() { python3 -c 'import json,sys; cp=json.load(open(sys.argv[1])); u=[x for x in cp["units"] if x["id"]==sys.argv[2]][0]; n=u
for p in sys.argv[3].split("."): n=n[p]
print(n if isinstance(n,str) else json.dumps(n))' "$XCP" "$1" "$2"; }

echo "== plan show"
check_exit 0 "plan show on an empty plan" "$ORCH" plan show
check_true "empty plan: header, separator, blank, cap line" test "$LAST_OUT" = "| unit | tier | model | effort | isolation | verifier | slots | dispatches |
|---|---|---|---|---|---|---|---|

cap: 0/0 · mode: DIRECT · integration branch: main · run: v062"
check_exit 0 "plan set V1 (sonnet, verified)" "$ORCH" plan set V1 --tier T1 --model sonnet --effort high --verifier fast
check_true "plan set prints its own row" test "$(printf '%s\n' "$LAST_OUT" | head -1)" = "| V1 | T1 | sonnet | high | worktree | fast | 4 | 0/4 |"
check_true "plan set prints the cap line after the row" test "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "cap: 0/8 · mode: DIRECT · integration branch: main · run: v062"
check_exit 0 "plan set V2 (haiku, unverified)" "$ORCH" plan set V2 --tier T0 --model haiku --effort low --verifier none
check_true "haiku row shows effort '-'" test "$(printf '%s\n' "$LAST_OUT" | head -1)" = "| V2 | T0 | haiku | - | worktree | none | 2 | 0/2 |"
check_exit 0 "plan show (two units)" "$ORCH" plan show
check_true "plan show prints exactly the table, a blank line and the cap line" test "$LAST_OUT" = "| unit | tier | model | effort | isolation | verifier | slots | dispatches |
|---|---|---|---|---|---|---|---|
| V1 | T1 | sonnet | high | worktree | fast | 4 | 0/4 |
| V2 | T0 | haiku | - | worktree | none | 2 | 0/2 |

cap: 0/10 · mode: DIRECT · integration branch: main · run: v062"
case "$LAST_OUT" in *ship*) fail "plan show lists the ship pseudo-unit" ;; *) pass "plan show omits the ship pseudo-unit" ;; esac
check_exit 0 "plan set V3 --depends V1" "$ORCH" plan set V3 --tier T1 --model sonnet --effort low --verifier fast --depends V1
check_true "plan set row carries the depends column once any unit has it" test "$(printf '%s\n' "$LAST_OUT" | head -1)" = "| V3 | T1 | sonnet | low | worktree | fast | 4 | 0/4 | V1 |"
check_exit 0 "dispatch open V1 worker" "$ORCH" dispatch open V1 --role worker --epoch 1
check_exit 0 "plan show with depends and a dispatch" "$ORCH" plan show
check_true "depends header column" test "$(printf '%s\n' "$LAST_OUT" | head -1)" = "| unit | tier | model | effort | isolation | verifier | slots | dispatches | depends |"
check_true "depends separator" test "$(printf '%s\n' "$LAST_OUT" | sed -n 2p)" = "|---|---|---|---|---|---|---|---|---|"
check_true "V1 row: 1/4 dispatches, depends '-'" test "$(printf '%s\n' "$LAST_OUT" | sed -n 3p)" = "| V1 | T1 | sonnet | high | worktree | fast | 4 | 1/4 | - |"
check_true "V3 row: depends V1" test "$(printf '%s\n' "$LAST_OUT" | sed -n 5p)" = "| V3 | T1 | sonnet | low | worktree | fast | 4 | 0/4 | V1 |"
check_true "cap line counts the dispatch" test "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "cap: 1/14 · mode: DIRECT · integration branch: main · run: v062"
check_exit 0 "dispatch close V1 1" "$ORCH" dispatch close V1 1 --exit PASS --tokens 100 --duration 1
check_exit 0 "plan show on the FOREMAN run" "$ORCH" --run v062f plan show
check_true "FOREMAN cap line names the foreman model and effort" test "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "cap: 0/0 · mode: FOREMAN · foreman: opus @ high · integration branch: main · run: v062f"
check_exit 1 "plan show with an argument refused" "$ORCH" plan show V1
check_exit 1 "plan bogus subcommand" "$ORCH" plan list

echo "== report save from stdin (6a)"
check_exit 0 "worktree add V1 at the default location" "$ORCH" worktree add V1 --at "$BASE_V"
WTV="$REPO/.claude/worktrees/V1"
check_true "default worktree path is <root>/.claude/worktrees/<unit>" test "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "$WTV unit/V1"
check_true ".claude/worktrees/ is git-excluded" git check-ignore -q .claude/worktrees
mkdir -p "$WTV/out" && printf '3 passed\n' > "$WTV/out/test.log"
echo "login" >> "$WTV/README.md"
mkdir -p "$WTV/docs/_pending" && printf '# Login flow\n\nAdded login.\n' > "$WTV/docs/_pending/V1.md"
git -C "$WTV" add README.md docs && git -C "$WTV" commit -q -m "V1: login"
V1HEAD=$(git -C "$WTV" rev-parse HEAD)
cat > "$WORK/report-V1.json" <<EOF
{ "unit": "V1", "branch": "unit/V1", "baselineSha": "$BASE_V", "headSha": "$V1HEAD", "commits": ["$V1HEAD"], "filesChanged": ["README.md", "docs/_pending/V1.md"],
  "gates": [ { "id": "ok", "cmd": "echo unit-ok", "exit": 0 } ],
  "criteria": [ { "id": "C1", "status": "PASS", "evidence": "3 passed; out/test.log", "artifact": "out/test.log", "runCmd": "npm test" },
                { "id": "C2", "status": "PASS", "evidence": "README.md:2" } ],
  "deviations": [], "backgroundProcesses": "none" }
EOF
{ echo '```json'; cat "$WORK/report-V1.json"; echo '```'; } > "$WORK/report-V1.md"
save_stdin() { "$ORCH" report save "$@" < "$STDIN_FILE"; }
STDIN_FILE="$WORK/report-V1.md"
check_exit 0 "report save V1 - reads the fenced block from stdin" save_stdin V1 - --run-criteria C1
check_contains "stdin report validated as stdin, not a temp path" "VALID: stdin (unit V1, 2 criteria, 1 gates)" "$LAST_OUT"
check_contains "artifact copied from the registered worktree" "artifacts: 1 file(s) copied" "$LAST_OUT"
check_true "path printed last" test "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "$XARCH/reports/V1-1.json"
check_true "saved reports/V1-1.json as a bare object" python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["unit"]=="V1" and d["headSha"]==sys.argv[2]' "$XARCH/reports/V1-1.json" "$V1HEAD"
check_true "stdin scratch file removed" test -z "$(ls "$XARCH/reports"/.stdin-* 2>/dev/null)"
STDIN_FILE="$WORK/report-V1.json"
check_exit 0 "report save V1 - with a bare object on stdin" save_stdin V1 -
check_true "saved reports/V1-2.json" test -f "$XARCH/reports/V1-2.json"
STDIN_FILE=/dev/null
check_exit 1 "report save V1 - with empty stdin" save_stdin V1 -
check_contains "empty stdin names the heredoc form" "report save V1 - <<'EOF'" "$LAST_OUT"
STDIN_FILE="$WORK/report-running.json"
check_exit 1 "report save V1 - with an invalid report on stdin" save_stdin V1 -
check_true "invalid stdin report not saved, scratch removed" test ! -e "$XARCH/reports/V1-3.json" -a -z "$(ls "$XARCH/reports"/.stdin-* 2>/dev/null)"

echo "== contract new (6b)"
check_exit 1 "contract new without a registered worktree" "$ORCH" contract new V9
check_contains "refusal tells the user to run worktree add" "run 'orchestrate worktree add V9 --at $BASE_V' first" "$LAST_OUT"
check_true "nothing written for V9" test ! -e "$XARCH/dispatch/V9.md"
check_exit 1 "contract new ship refused" "$ORCH" contract new ship
check_exit 0 "contract new V1 --objective --files" "$ORCH" contract new V1 --objective "Add the login flow." --files "src/a.ts,src/b.ts"
CV1="$XARCH/dispatch/V1.md"
check_true "prints the path first" test "$(printf '%s\n' "$LAST_OUT" | head -1)" = "$CV1"
check_contains "prints the Agent pointer sentence" "Agent prompt: read $CV1, execute exactly, final text = report per the contract's output format; do not use SendMessage or any messaging tool; your final text is your entire report." "$LAST_OUT"
check_contains "lists the remaining placeholders per section" "remaining placeholders (edit $CV1 by hand):" "$LAST_OUT"
check_contains "criteria stay placeholders" "## 3. Done-criteria: " "$LAST_OUT"
check_contains "criterion placeholder listed" "<criterion>" "$LAST_OUT"
check_contains "depth stays a placeholder" "## 5. Depth instruction: " "$LAST_OUT"
check_contains "constraints stay placeholders" "<relevant paths, patterns to follow, things that must not change>" "$LAST_OUT"
case "$LAST_OUT" in *"## 1. Objective"*) fail "objective still listed as a placeholder" ;; *) pass "objective filled: not listed" ;; esac
CTEXT=$(cat "$CV1")
check_contains "contract: title carries the unit" "# Dispatch contract: V1" "$CTEXT"
check_contains "contract: objective in section 1" "Add the login flow." "$CTEXT"
check_contains "contract: absolute worktree path + branch + baseline" "Worktree: \`$WTV\` on branch \`unit/V1\`, created at baseline \`$BASE_V\`." "$CTEXT"
check_contains "contract: integration branch" "Integration branch: \`main\`" "$CTEXT"
check_contains "contract: file scope from --files" "Files in scope: \`src/a.ts, src/b.ts\`." "$CTEXT"
check_contains "contract: fragments dir and target from docs[0]" "write docs fragments to \`docs/_pending/V1.md\`" "$CTEXT"
check_contains "contract: docs target" "never edit the target \`docs/features.md\`" "$CTEXT"
check_true "contract: no gate command still carries {{baseline}}" test "$(grep -c 'verify {{baseline}}' "$CV1")" = 0
check_contains "contract: Gates line from the manifest with {{baseline}} substituted" "\`ok: echo unit-ok; baseline: git rev-parse --verify $BASE_V > /dev/null\`" "$CTEXT"
check_contains "contract: gates[] example from the manifest" "\"gates\": [ {\"id\": \"ok\", \"cmd\": \"echo unit-ok\", \"exit\": 0}, {\"id\": \"baseline\", \"cmd\": \"git rev-parse --verify $BASE_V > /dev/null\", \"exit\": 0} ]," "$CTEXT"
check_contains "contract: envBootstrap filled" "\`envBootstrap\` (\`echo env >> bootstrap.txt\`)" "$CTEXT"
check_contains "contract: install filled" "\`install\` (\`echo install >> bootstrap.txt\`)" "$CTEXT"
check_contains "contract: token cap 400" "≤ 400 tokens" "$CTEXT"
check_contains "contract: JSON example branch" "\"branch\": \"unit/V1\"" "$CTEXT"
check_contains "contract: epoch filled in the dispatch open line" "dispatch open V1 --role worker --epoch 1" "$CTEXT"
for leftover in "<unit>" "<absolute worktree path>" "<baselineSha>" "<integrationBranch>" "<declared file scope>" "<fragments>" "<docs[].target>" "<gate id: command, one per gate>" "<N>" "<One sentence"; do
  case "$CTEXT" in *"$leftover"*) fail "contract still contains $leftover" ;; *) pass "contract has no $leftover" ;; esac
done
case "$CTEXT" in *"Shared-worktree git hygiene"*) fail "worktree-isolated contract kept the shared-worktree hygiene block" ;; *) pass "hygiene block dropped for worktree isolation" ;; esac
check_contains "contract keeps the criteria placeholders for the orchestrator" "- C1 [run]: <criterion> · evidence:" "$CTEXT"
check_true "dispatch-log has the contract line" grep -q "contract new V1: wrote dispatch/V1.md" "$XLOG"
check_exit 1 "contract new V1 again refused" "$ORCH" contract new V1
check_contains "refusal names --force" "pass --force" "$LAST_OUT"
check_true "refusal left the file intact" test "$(cat "$CV1")" = "$CTEXT"
check_exit 0 "contract new V1 --force (no objective, no files)" "$ORCH" contract new V1 --force
check_contains "objective placeholder listed when not given" "## 1. Objective: <One sentence" "$LAST_OUT"
check_contains "file scope placeholder listed when not given" "<declared file scope>" "$LAST_OUT"
check_true "file scope placeholder kept in the file" grep -q "Files in scope: \`<declared file scope>\`" "$CV1"
check_exit 0 "plan set V2 --isolation shared" "$ORCH" plan set V2 --tier T0 --model haiku --effort low --verifier none --isolation shared
check_exit 0 "worktree add V2" "$ORCH" worktree add V2 --at "$BASE_V" --no-bootstrap --path "$WORK/wt-V2"
check_exit 0 "contract new V2 (shared isolation)" "$ORCH" contract new V2
check_true "shared contract keeps the hygiene block, heading cleaned" grep -q "^## Shared-worktree git hygiene$" "$XARCH/dispatch/V2.md"
check_true "shared contract names its --path worktree" grep -q "Worktree: \`$WORK/wt-V2\`" "$XARCH/dispatch/V2.md"
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); del m["docs"]; json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
check_exit 0 "contract new V2 --force without docs in the manifest" "$ORCH" contract new V2 --force
check_true "no docs manifest: the Shared docs line says so" grep -q "^- Shared docs: no docs manifest" "$XARCH/dispatch/V2.md"
mv "$REPO/.claude/orchestrate-gates.json" "$REPO/.claude/orchestrate-gates.json.off"
check_exit 0 "contract new V2 --force without any manifest" "$ORCH" contract new V2 --force
check_true "no manifest: Gates line stays a placeholder" grep -q "<gate id: command, one per gate>" "$XARCH/dispatch/V2.md"
check_true "no manifest: install is none" grep -q "\`install\` (\`none\`)" "$XARCH/dispatch/V2.md"
mv "$REPO/.claude/orchestrate-gates.json.off" "$REPO/.claude/orchestrate-gates.json"
git -C "$REPO" checkout -q -- .claude/orchestrate-gates.json

echo "== contract verify (6b)"
check_exit 1 "contract verify without --head" "$ORCH" contract verify V1
check_exit 1 "contract verify for a unit without a worktree" "$ORCH" contract verify V3 --head "$V1HEAD"
check_exit 0 "worktree add V3" "$ORCH" worktree add V3 --at "$BASE_V" --no-bootstrap --path "$WORK/wt-V3"
check_exit 1 "contract verify without a saved report" "$ORCH" contract verify V3 --head "$BASE_V"
check_contains "refusal names report save" "no saved report reports/V3-<n>.json" "$LAST_OUT"
# the orchestrator edits the criteria of the dispatch contract; verify copies them
sed -e 's/^- C1 \[run\]: <criterion> · evidence: .*/- C1 [run]: unit tests pass · evidence: npm test, out\/test.log, exit 0/' \
    -e 's/^- C2: <criterion> · evidence: .*/- C2: README mentions login · evidence: grep -n login README.md/' "$CV1" > "$CV1.tmp" && mv "$CV1.tmp" "$CV1"
check_exit 0 "contract verify V1 --head" "$ORCH" contract verify V1 --head "$V1HEAD"
VV1="$XARCH/dispatch/V1-verify.md"
check_true "prints the path first" test "$(printf '%s\n' "$LAST_OUT" | head -1)" = "$VV1"
check_true "prints the Agent pointer sentence" test "$(printf '%s\n' "$LAST_OUT" | sed -n 2p)" = "Agent prompt: read $VV1, execute exactly, final text = report per the contract's output format; do not use SendMessage or any messaging tool; your final text is your entire report."
check_true "prints the dispatch open line for verifier-fast" test "$(printf '%s\n' "$LAST_OUT" | sed -n 3p)" = "dispatch: orchestrate dispatch open V1 --role verifier --epoch 1 --model haiku --effort low"
check_contains "lists the remaining placeholders" "remaining placeholders:" "$LAST_OUT"
VTEXT=$(cat "$VV1")
check_contains "verify: title" "# Gate 2 verification: V1" "$VTEXT"
check_contains "verify: verifier-fast" "Verifier: \`verifier-fast\`" "$VTEXT"
check_contains "verify: repoRoot is the worktree" "| repoRoot | \`$WTV\` |" "$VTEXT"
check_contains "verify: baselineSha" "| baselineSha | \`$BASE_V\` |" "$VTEXT"
check_contains "verify: headSha" "| headSha | \`$V1HEAD\` |" "$VTEXT"
check_contains "verify: diffRange baseline..head" "| diffRange | \`$BASE_V..$V1HEAD\` |" "$VTEXT"
check_contains "verify: scope all" "| scope | \`all\` |" "$VTEXT"
check_contains "verify: reportPath is the newest report" "| reportPath | \`$XARCH/reports/V1-2.json\` |" "$VTEXT"
check_contains "verify: priorVerdictRef none" "| priorVerdictRef | \`none\` (first verification) |" "$VTEXT"
check_contains "verify: C1 copied with the artifact from the report" "- C1 [run]: unit tests pass · settling evidence: artifact \`$XARCH/reports/V1-2-artifacts/out/test.log\` produced by \`npm test\`; judged from that file, never from the test source" "$VTEXT"
check_contains "verify: C2 copied with its evidence" "- C2: README mentions login · settling evidence: grep -n login README.md" "$VTEXT"
case "$VTEXT" in *"- Cn:"*) fail "verify kept the template's Cn line" ;; *) pass "verify dropped the template's Cn line" ;; esac
check_contains "verify: command blocks use the worktree and the range" "git -C $WTV log --oneline $BASE_V..$V1HEAD | wc -l" "$VTEXT"
check_contains "verify: ancestry check filled" "git -C $WTV merge-base --is-ancestor $BASE_V $V1HEAD" "$VTEXT"
check_contains "verify: RANGE line filled" "RANGE: $BASE_V..$V1HEAD (<n> commits, <m> files)" "$VTEXT"
for leftover in "<repoRoot>" "<diffRange>" "<unit>" "<archive>" "<absolute path of the unit worktree>" "<baselineSha" "<headSha" "<verifier-fast | verifier-deep>"; do
  case "$VTEXT" in *"$leftover"*) fail "verify still contains $leftover" ;; *) pass "verify has no $leftover" ;; esac
done
check_true "dispatch-log has the verify line" grep -q "contract verify V1: wrote dispatch/V1-verify.md" "$XLOG"
check_exit 0 "contract verify V1 --deep" "$ORCH" contract verify V1 --head "$V1HEAD" --deep
check_contains "--deep: dispatch line sonnet xhigh" "dispatch: orchestrate dispatch open V1 --role verifier --epoch 1 --model sonnet --effort xhigh" "$LAST_OUT"
check_true "--deep: verifier-deep in the file (overwritten in place)" grep -q "Verifier: \`verifier-deep\`" "$VV1"
check_exit 0 "plan set V1 --verifier deep" "$ORCH" plan set V1 --tier T1 --model sonnet --effort high --verifier deep
check_exit 0 "contract verify V1 (deep plan row)" "$ORCH" contract verify V1 --head "$V1HEAD"
check_contains "deep plan row implies verifier-deep" "--model sonnet --effort xhigh" "$LAST_OUT"
check_exit 0 "plan set V1 --verifier fast again" "$ORCH" plan set V1 --tier T1 --model sonnet --effort high --verifier fast
check_exit 0 "contract verify V1 --prior (full re-verify)" "$ORCH" contract verify V1 --head "$V1HEAD" --prior gates/V1-gate2-1.md
check_true "--prior fills priorVerdictRef" grep -q "| priorVerdictRef | \`gates/V1-gate2-1.md\` |" "$VV1"
check_exit 1 "--scope without --since refused" "$ORCH" contract verify V1 --head "$V1HEAD" --scope C2
check_contains "refusal names --since" "--scope needs --since <lastPassedSha>" "$LAST_OUT"
check_exit 1 "--scope with an unknown criterion refused" "$ORCH" contract verify V1 --head "$V1HEAD" --scope C9 --since "$BASE_V"
check_contains "refusal lists the contract's criteria" "it has C1, C2" "$LAST_OUT"
check_true "no reverify file written by the refusals" test ! -e "$XARCH/dispatch/V1-reverify-1.md"
check_exit 0 "contract verify V1 --scope C2 --since --prior" "$ORCH" contract verify V1 --head "$V1HEAD" --scope C2 --since "$BASE_V" --prior gates/V1-gate2-1.md
RV1="$XARCH/dispatch/V1-reverify-1.md"
check_true "scoped: writes dispatch/V1-reverify-1.md" test "$(printf '%s\n' "$LAST_OUT" | head -1)" = "$RV1" -a -f "$RV1"
check_true "scoped: dispatch line uses --role reverify" test "$(printf '%s\n' "$LAST_OUT" | sed -n 3p)" = "dispatch: orchestrate dispatch open V1 --role reverify --epoch 1 --model haiku --effort low"
RTEXT=$(cat "$RV1")
check_contains "reverify: title" "# Scoped Gate 2 re-verification: V1" "$RTEXT"
check_contains "reverify: diffRange lastPassed..head" "| diffRange | \`$BASE_V..$V1HEAD\` |" "$RTEXT"
check_contains "reverify: scope" "| scope | \`C2\` |" "$RTEXT"
check_contains "reverify: priorVerdictRef" "| priorVerdictRef | \`gates/V1-gate2-1.md\` |" "$RTEXT"
check_contains "reverify: reportPath (fix-round report)" "| reportPath | \`$XARCH/reports/V1-2.json\` (the fix-round report) |" "$RTEXT"
check_contains "reverify: only the scoped criterion, with the prior-verdict slot" "- C2: README mentions login · prior verdict: FAIL · <one line: what the prior verdict found> · settling evidence: grep -n login README.md" "$RTEXT"
case "$RTEXT" in *"- C1"*) fail "reverify lists the out-of-scope C1" ;; *) pass "reverify omits out-of-scope criteria" ;; esac
check_contains "reverify: lastPassedSha in prose" "PASSed at \`$BASE_V\`" "$RTEXT"
check_contains "reverify: command block range" "git -C $WTV diff --stat $BASE_V..$V1HEAD" "$RTEXT"
check_contains "reverify: remaining placeholder is the prior-verdict line" "remaining placeholders: <one line: what the prior verdict found>" "$LAST_OUT"
check_exit 0 "second scoped verify numbers -2" "$ORCH" contract verify V1 --head "$V1HEAD" --scope C1,C2 --since "$BASE_V"
check_true "writes dispatch/V1-reverify-2.md" test -f "$XARCH/dispatch/V1-reverify-2.md"
check_true "two-criterion scope" grep -q "| scope | \`C1, C2\` |" "$XARCH/dispatch/V1-reverify-2.md"

echo "== integrate (6c, 8b, 8f)"
check_exit 1 "integrate unknown unit" "$ORCH" integrate V9
check_exit 1 "integrate ship refused" "$ORCH" integrate ship
echo "dirty" >> README.md
check_exit 1 "integrate refused on a dirty root" "$ORCH" integrate V1
check_contains "dirty refusal names the file" "uncommitted changes to tracked files" "$LAST_OUT"
check_contains "dirty refusal lists it" " M README.md" "$LAST_OUT"
git checkout -q -- README.md
git checkout -q -b elsewhere
check_exit 1 "integrate refused when the root is not on the integration branch" "$ORCH" integrate V1
check_contains "branch refusal names both branches" "is on elsewhere, not on the integration branch main" "$LAST_OUT"
git checkout -q main && git branch -q -D elsewhere
check_true "refusals merged nothing" test "$(git rev-parse HEAD)" = "$BASE_V"
check_exit 0 "unit set V2 spot-check (verifier none)" "$ORCH" unit set V2 pending --spot-check "read the diff"
check_exit 0 "integrate V1 (warm: V2 and V3 still open)" "$ORCH" integrate V1
ITEXT="$LAST_OUT"
V1INT=$(git rev-parse HEAD)
check_contains "integrate: sync step line" "sync: ok ($WTV merged $BASE_V install:skipped gates:PASS)" "$ITEXT"
MERGE_SHA=$(git rev-parse HEAD~1)
check_contains "integrate: merge step line" "merge: $MERGE_SHA (git merge --no-ff unit/V1 into main)" "$ITEXT"
check_contains "integrate: docs step line" "docs: 1 inserted, committed $V1INT (docs(V1): apply fragments; fragment files deleted)" "$ITEXT"
check_contains "integrate: gate step line (warm)" "gate: integration PASS (warm) → gates/V1-integration-1.json" "$ITEXT"
check_contains "integrate: unit step line" "unit: unit V1: integrated" "$ITEXT"
check_true "integrate: final line is integrated <unit> at <HEAD after the docs commit>" test "$(printf '%s\n' "$ITEXT" | tail -1)" = "integrated V1 at $V1INT"
check_true "merge commit is --no-ff with the message merge V1" test "$(git log -1 --format=%s "$MERGE_SHA")" = "merge V1" -a "$(git rev-list --parents -n 1 "$MERGE_SHA" | wc -w | tr -d ' ')" = 3
check_true "docs commit message" test "$(git log -1 --format=%s HEAD)" = "docs(V1): apply fragments"
check_true "fragment deleted and its deletion committed (8f)" test ! -e docs/_pending/V1.md -a -z "$(git status --porcelain --untracked-files=no)"
check_true "target updated in the docs commit" grep -q "### V1: Login flow" docs/features.md
check_true "unit V1 integrated with the docs-commit sha (8b)" test "$(xunit V1 status)" = integrated -a "$(xunit V1 sha)" = "$V1INT"
check_true "unit V1 evidence is the integration gate json" test "$(xunit V1 evidenceRef)" = "gates/V1-integration-1.json"
check_true "lastIntegratedSha bumped" test "$(cpget lastIntegratedSha "$XCP")" = "$V1INT"
check_true "integration gate ran warm" test "$(cpget cold "$XARCH/gates/V1-integration-1.json")" = "false"
check_true "dispatch-log has the integrate line" grep -q "integrate V1: merged unit/V1 as $MERGE_SHA, docs commit $V1INT, integration gate PASS (gates/V1-integration-1.json), integrated at $V1INT" "$XLOG"
check_exit 1 "integrate V1 again refused (already integrated)" "$ORCH" integrate V1
# conflict: V3 and main both edit README.md
echo "V3 side" > "$WORK/wt-V3/README.md" && git -C "$WORK/wt-V3" commit -q -am "V3: readme"
echo "main side" > README.md && git commit -q -am "main: readme"
MAINC=$(git rev-parse HEAD)
check_exit 3 "integrate V3: sync conflict exits 3" "$ORCH" integrate V3
check_contains "sync conflict names the file" "conflict: README.md" "$LAST_OUT"
check_contains "sync step reports FAIL, nothing merged" "sync: FAIL (conflict or unit gate FAIL in $WORK/wt-V3; nothing merged into main)" "$LAST_OUT"
check_true "main unchanged after the sync conflict" test "$(git rev-parse HEAD)" = "$MAINC"
check_exit 3 "integrate V3 --no-sync: merge conflict exits 3" "$ORCH" integrate V3 --no-sync
check_contains "--no-sync skipped the sync" "sync: skipped (--no-sync)" "$LAST_OUT"
check_contains "merge conflict aborted" "merge aborted, main unchanged at $MAINC" "$LAST_OUT"
check_contains "merge conflict names the file" "conflict: README.md" "$LAST_OUT"
check_true "main unchanged, no merge in progress, clean" test "$(git rev-parse HEAD)" = "$MAINC" -a ! -e "$(git rev-parse --git-path MERGE_HEAD)" -a -z "$(git status --porcelain --untracked-files=no)"
check_true "V3 still pending" test "$(xunit V3 status)" = pending
check_exit 0 "unit set V3 failed (V2 becomes the last open unit)" "$ORCH" unit set V3 failed
# gate FAIL: merge stays, unit is not marked; cold implied for the last unit
echo "v2" > "$WORK/wt-V2/v2.txt" && mkdir -p "$WORK/wt-V2/docs/_pending" && printf '# V2 note\n\nfrom V2\n' > "$WORK/wt-V2/docs/_pending/V2.md"
git -C "$WORK/wt-V2" add v2.txt docs && git -C "$WORK/wt-V2" commit -q -m "V2 work"
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["gates"]["integration"] = [{"id": "bad", "cmd": "echo integration-fails; exit 9"}]; json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
git commit -q -am "manifest: failing integration gate"
mkdir -p .cache && echo blob > .cache/blob
check_exit 3 "integrate V2 --no-docs: integration gate FAIL exits 3" "$ORCH" integrate V2 --no-docs
V2MERGE=$(git rev-parse HEAD)
check_contains "docs skipped" "docs: skipped (--no-docs)" "$LAST_OUT"
check_contains "gate FAIL line: cold implied for the last unit, merge kept, unit not marked" "gate: integration FAIL (cold, last unit) → gates/V2-integration-1.json; merge $V2MERGE left on main, unit V2 NOT marked" "$LAST_OUT"
check_true "merge V2 is HEAD (left in place)" test "$(git log -1 --format=%s)" = "merge V2"
check_true "cold run deleted cachePaths in the root" test ! -e .cache
check_true "gate json records cold" test "$(cpget cold "$XARCH/gates/V2-integration-1.json")" = "true"
check_true "V2 not marked integrated" test "$(xunit V2 status)" = pending -a "$(xunit V2 sha)" = ""
check_true "--no-docs left the fragment in place" test -f docs/_pending/V2.md
check_true "dispatch-log records the FAIL" grep -q "integrate V2: merged unit/V2 as $V2MERGE, integration gate FAIL (gates/V2-integration-1.json), unit not marked" "$XLOG"
python3 - "$REPO/.claude/orchestrate-gates.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1])); m["gates"]["integration"] = [{"id": "ok", "cmd": "true"}]; json.dump(m, open(sys.argv[1], "w"), indent=2)
PY
git commit -q -am "manifest: fixed integration gate"
check_exit 0 "integrate V2 again after the fix" "$ORCH" integrate V2
V2INT=$(git rev-parse HEAD)
check_contains "re-run: nothing to merge" "merge: nothing to merge (unit/V2 is already in main at" "$LAST_OUT"
check_contains "re-run: docs applied and committed" "docs: 1 inserted, committed $V2INT" "$LAST_OUT"
check_contains "re-run: gate PASS cold, last unit" "gate: integration PASS (cold, last unit) → gates/V2-integration-2.json" "$LAST_OUT"
check_true "re-run: integrated at the docs commit" test "$(printf '%s\n' "$LAST_OUT" | tail -1)" = "integrated V2 at $V2INT" -a "$(xunit V2 sha)" = "$V2INT"
check_true "V2 fragment gone, root clean" test ! -e docs/_pending/V2.md -a -z "$(git status --porcelain --untracked-files=no)"
check_true "nextAction ship-gate after the last unit" test "$(cpget nextAction "$XCP")" = "ship-gate"
check_exit 0 "plan show after integration (dispatch counts)" "$ORCH" plan show
check_exit 0 "archive check after the v0.6.2 round" "$ORCH" archive check
check_exit 0 "worktree remove V1" "$ORCH" worktree remove V1
check_exit 0 "worktree remove V2" "$ORCH" worktree remove V2
check_exit 0 "worktree remove V3" "$ORCH" worktree remove V3
unset ORCHESTRATE_RUN

echo
echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
