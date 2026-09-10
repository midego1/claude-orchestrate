# orchestrate evals

Repeatable, scored live runs of the plugin on a fixture repo, with and without the plugin loaded, plus the cost of each arm. `claude plugin eval` is the intended runner (case layout is the same: `<case>/prompt.md` + `graders/`); while it is early access, `evals/run.sh` drives the same cases through `claude -p`.

## Run

```bash
evals/run.sh                              # every case, arms with,without, 1 run each, opus, $8 budget per run
evals/run.sh --case direct-mode-smoke --arms with --runs 3 --model opus
evals/run.sh --dry-run                    # print the claude invocations only
```

Output: `evals/results/<stamp>/summary.md` (score, cost, turns, minutes, failed graders per case/arm/run) and per run `trace.jsonl` (the full stream-json), `result.json`, `final.md` (the assistant's last message) and one log per grader. `--keep` leaves the fixture repos in place. Exit 1 when any scored grader failed.

Cost (2.1.260, opus orchestrator): one with-arm run of `direct-mode-smoke` USD 3.11, 37 turns, 7.7 min (sonnet/haiku dispatches included); the without arm USD 0.28, 5 turns, 0.5 min. `--max-budget-usd` caps each run.

## Arms

- **with**: `--plugin-dir <this checkout>` (so a branch is tested before release, not the installed cache) plus a system-prompt line naming that path as the plugin root, `--setting-sources project` (no user-level plugins or settings), `--dangerously-skip-permissions`, a fresh fixture per run.
- **without**: identical minus the plugin, plus a system-prompt fence saying no orchestrate plugin may be loaded or read from disk. Probed on 2.1.260: `--setting-sources project` hides every user-installed plugin (a Skill call returns "Unknown skill"), but the installed copy under `~/.claude/plugins/cache` stays readable from the sandbox and the first baseline run found it through the fixture's CLAUDE.md and ran the whole protocol by hand (USD 4.71, more than the with arm). When protocol indicators fire in the without arm, the baseline leaked.

## Cases

Each case: `case.yaml` (flat keys: `runs`, `model`, `max_budget_usd`, `max_turns`, `timeout_seconds`, `tags`), `prompt.md` (the task; a task, never `/orchestrate`, so both arms get the same prompt; the fixture's CLAUDE.md says multi-unit work goes through the skill when installed), `scaffold.sh` (builds the fixture at `$1`, records the baseline SHA in `.git/eval-baseline`), `graders/*.sh`.

- `direct-mode-smoke`: the first live field run (v0.6.1) as a case: shout + tests, README + docs fragment.
- `gate2-trap`: same task plus one easy-to-skip spec detail (the summary line must print even when a test fails); a mutation grader breaks `shout` and checks the runner still reports.

## Graders

Shell scripts, exit 0 = pass, run in the fixture repo with `RUN_DIR`, `TRACE`, `RESULT`, `FINAL`, `ARM`, `PLUGIN_ROOT` set. `_common/graders/` runs for every case; a case adds its own under `graders/`. A first-line `# with-only` marker makes a grader a plugin indicator: scored in the with arm, reported but not scored in the without arm (the `claude plugin eval` ablation rule). Score = passed / scored.

Outcome (both arms): tests pass with the summary line, shout behaves, README examples, docs section filled and no fragment left, clean tree on main with no worktrees, diff scope. Protocol (with-only): skill fired, one archive at `COMPLETED`, a non-empty run artifact, a Gate 2 verdict with evidence, plan table + cap line before the first dispatch, cost line in the final report, `contract new` + `integrate` used (no hand merge of a unit branch), no background dispatches.

## Adding a case

Copy a case directory, edit `prompt.md` and `case.yaml`, add graders for anything the prompt makes decidable. Keep the prompt a task; keep protocol checks `# with-only`.
