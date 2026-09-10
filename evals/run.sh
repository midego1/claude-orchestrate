#!/usr/bin/env bash
# orchestrate eval harness: runs a case headless (claude -p) with and without the plugin,
# scores it with the graders, and records cost. Stand-in for `claude plugin eval` (early access)
# with the same case layout (prompt.md + graders/), so cases carry over when that lands.
#
# usage: evals/run.sh [--case <name>] [--arms with,without] [--runs <n>] [--model <alias>]
#                     [--max-budget-usd <x>] [--timeout <sec>] [--keep] [--dry-run]
# Exit 0 when every scored grader passed in every run, 1 otherwise, 2 on usage error.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EVALS="$ROOT/evals"
CASES=""; ARMS="with,without"; RUNS=""; MODEL=""; BUDGET=""; TIMEOUT=""; KEEP=0; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --case) CASES="$CASES $2"; shift 2 ;;
    --arms) ARMS="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --max-budget-usd) BUDGET="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --keep) KEEP=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "$CASES" ] || CASES="$(cd "$EVALS" && ls -d */ | sed 's#/##' | grep -v -e '^_' -e '^results$')"
command -v claude >/dev/null || { echo "claude CLI not found" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 2; }

cfg() { # cfg <case.yaml> <key> <default>   (flat "key: value" lines only)
  local v; v="$(grep -E "^$2:" "$1" 2>/dev/null | head -1 | sed -E "s/^$2:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^\"(.*)\"$/\1/")"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$3"
}
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$EVALS/results/$STAMP"; mkdir -p "$OUT"
SUMMARY="$OUT/summary.md"
{ echo "# eval run $STAMP"; echo; echo "plugin root: $ROOT"; echo; echo "| case | arm | run | score | passed | cost USD | turns | minutes | failed graders |"; echo "|---|---|---|---|---|---|---|---|---|"; } > "$SUMMARY"
ANY_FAIL=0

run_one() { # run_one <case> <arm> <n>
  local case="$1" arm="$2" n="$3" cdir="$EVALS/$1" yaml="$EVALS/$1/case.yaml"
  local model budget timeout maxturns
  model="${MODEL:-$(cfg "$yaml" model opus)}"; budget="${BUDGET:-$(cfg "$yaml" max_budget_usd 8)}"
  timeout="${TIMEOUT:-$(cfg "$yaml" timeout_seconds 2400)}"; maxturns="$(cfg "$yaml" max_turns 200)"
  local rdir="$OUT/$case/$arm-$n"; mkdir -p "$rdir"
  local work; work="$(mktemp -d "${TMPDIR:-/tmp}/orch-eval-XXXXXX")"; local repo="$work/repo"
  bash "$cdir/scaffold.sh" "$repo" > "$rdir/scaffold.log" 2>&1 || { echo "scaffold failed: $rdir/scaffold.log" >&2; return 1; }
  local prompt; prompt="$(cat "$cdir/prompt.md")"
  local -a args=(-p "$prompt" --setting-sources project --dangerously-skip-permissions --no-session-persistence
                 --model "$model" --max-budget-usd "$budget" --max-turns "$maxturns" --output-format stream-json --verbose)
  if [ "$arm" = with ]; then
    args+=(--plugin-dir "$ROOT" --append-system-prompt "The orchestrate plugin is loaded from a manual checkout for this session; its plugin root is \"$ROOT\" (use that as <plugin root>; do not look under ~/.claude/plugins).")
  else
    # baseline fence: an installed copy under ~/.claude/plugins is reachable from the sandbox; a probe on 2.1.260 showed the model finding it via CLAUDE.md and running the protocol by hand
    args+=(--append-system-prompt "No orchestrate plugin or skill is available in this session, and none may be loaded or read from disk (not from ~/.claude/plugins or anywhere else). Work directly with your built-in tools.")
  fi
  echo ">> $case / $arm / run $n  (model $model, budget \$$budget, timeout ${timeout}s)"
  if [ "$DRY" = 1 ]; then echo "   claude ${args[*]}" | cut -c1-300; rm -rf "$work"; return 0; fi
  ( cd "$repo" && perl -e 'alarm shift; exec @ARGV' "$timeout" claude "${args[@]}" ) > "$rdir/trace.jsonl" 2> "$rdir/stderr.log"
  local rc=$?
  python3 - "$rdir/trace.jsonl" "$rdir/result.json" "$rdir/final.md" <<'PY'
import json, sys
trace, out, final = sys.argv[1:4]
res = {}
for line in open(trace, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line: continue
    try: o = json.loads(line)
    except Exception: continue
    if o.get("type") == "result": res = o
json.dump(res, open(out, "w"), indent=1)
open(final, "w").write(str(res.get("result", "")))
PY
  # graders: shared first, then the case's own; a first-line "# with-only" marker scores only in the with arm
  local total=0 passed=0 failed="" ind=""
  for g in "$EVALS"/_common/graders/*.sh "$cdir"/graders/*.sh; do
    [ -f "$g" ] || continue
    local name; name="$(basename "$g" .sh)"
    local withonly=0; head -3 "$g" | grep -q '^# with-only' && withonly=1
    local grc
    ( cd "$repo" && RUN_DIR="$repo" TRACE="$rdir/trace.jsonl" RESULT="$rdir/result.json" FINAL="$rdir/final.md" ARM="$arm" PLUGIN_ROOT="$ROOT" bash "$g" ) > "$rdir/grader-$name.log" 2>&1; grc=$?
    if [ "$withonly" = 1 ] && [ "$arm" != with ]; then
      ind="$ind $name=$([ $grc -eq 0 ] && echo fired || echo -)"; continue
    fi
    total=$((total+1))
    if [ $grc -eq 0 ]; then passed=$((passed+1)); else failed="$failed $name"; fi
  done
  local score="0"; [ $total -gt 0 ] && score="$(python3 -c "print(round($passed/$total,2))")"
  local cost turns mins
  read -r cost turns mins < <(python3 -c "import json,sys
try: r=json.load(open(sys.argv[1]))
except Exception: r={}
print(round(r.get('total_cost_usd',0),2), r.get('num_turns','?'), round(r.get('duration_ms',0)/60000,1))" "$rdir/result.json")
  [ $rc -ne 0 ] && failed="$failed (claude exit $rc)"
  echo "   score $score ($passed/$total) · \$$cost · $turns turns · ${mins} min · failed:${failed:- none}${ind:+ · indicators:$ind}"
  echo "| $case | $arm | $n | $score | $passed/$total | $cost | $turns | $mins | ${failed:- } |" >> "$SUMMARY"
  [ "$passed" -eq "$total" ] || ANY_FAIL=1
  if [ "$KEEP" = 1 ]; then echo "   repo kept at $repo"; else rm -rf "$work"; fi
}

for case in $CASES; do
  yaml="$EVALS/$case/case.yaml"
  [ -f "$yaml" ] || { echo "no case.yaml for $case" >&2; exit 2; }
  runs="${RUNS:-$(cfg "$yaml" runs 1)}"
  for arm in $(echo "$ARMS" | tr ',' ' '); do
    n=1; while [ $n -le "$runs" ]; do run_one "$case" "$arm" "$n"; n=$((n+1)); done
  done
done
echo; echo "summary: $SUMMARY"; cat "$SUMMARY"
exit $ANY_FAIL
