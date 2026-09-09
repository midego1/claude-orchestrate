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

echo
echo "== summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
