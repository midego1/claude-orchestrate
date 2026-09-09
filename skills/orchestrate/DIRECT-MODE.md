# Direct mode: the ordered checklist

Direct mode: plans of 5 units or fewer, the tail of any phase, or degraded mode at any size (the foreman became the planner).
You run the loop in the main session; gates and evidence-or-FAIL apply as in SKILL.md "Core loop".
Resolve the plugin root once per session: plugin install → `ls -d ~/.claude/plugins/cache/claude-orchestrate/orchestrate/*/ | sort -V | tail -1`; manual checkout → the repo directory. Quote it (paths contain spaces and apostrophes). `orchestrate` below means `"<plugin root>/bin/orchestrate"`. Exit 1: error or no manifest; 2: refused by policy; 3: failed gate.
Gates and bootstrap read `.claude/orchestrate-gates.json` (fallback `orchestrate-gates.json`; start from `examples/orchestrate-gates.json`). Without one, `worktree add` skips bootstrap and `gate run` takes `--cmd <id>=<command>` options or the unit's saved report gates, still recording under `gates/`.
Steps run in order, each written to disk before the next.

## Checklist

1. **Preflight.** Record the result.
   ```
   orchestrate preflight
   ```
   `foreman-refused` under `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` blocks direct mode too; spawn depth below 2 does not.
2. **Init**, in the integration root on the integration branch (records baseline, branch, lease `epoch 1`, the `ship` pseudo-unit).
   ```
   orchestrate init --mode DIRECT
   ```
   Degraded mode: never init twice. The foreman's `handoff --to orchestrator` already set `dispatchMode: DIRECT`; only if it stopped without handing off, take the lease:
   ```
   orchestrate lease take --agent orchestrator --expect <owner.epoch>
   ```
3. **Plan table and cap.** Announce the table (SKILL.md "Budget discipline") before any dispatch; register every row:
   ```
   orchestrate plan set U1 --tier T1 --model sonnet --effort high --verifier fast --isolation worktree [--depends U0]
   ```
   Cap = planned slots: 4 per verified unit, 2 per skip-Gate-2 unit, plus 4 for the ship gate.
4. **Worktree per unit** at the unit's baseline: `git rev-parse HEAD` in the integration root at dispatch time (the run `baselineSha` for the first wave; the post-merge HEAD once its `--depends` targets are integrated). That SHA feeds `dispatch/U1.md`, the verifier's `baselineSha` and `gate run --since`. It checks out branch `unit/U1` (default; `--branch` overrides; never `--detach`: the report and step 9 need it) and runs `envBootstrap` and `install`. Never `isolation: worktree` (branches from the default branch).
   ```
   orchestrate worktree add U1 --at <unitBaselineSha>
   ```
5. **Contract on disk.** Copy `templates/dispatch.md` to `dispatch/U1.md`: criterion IDs `C1..Cn`, the worker preamble (SKILL.md "Dispatch contract"), the JSON report block, the manifest's unit gate commands with `{{baseline}}` substituted (the worker never reads the manifest), branch `unit/U1`, and that bootstrap and install already ran (the worker re-runs install only if the dependency directory is missing). Agent prompt: the pointer plus the execution sentence; a retry adds the verdict.
6. **Dispatch**: open, call, save. `<n>`: the number `dispatch open` prints.
   ```
   orchestrate dispatch open U1 --role worker --epoch <owner.epoch> --model sonnet --effort high
   ```
   Then the Agent call, `run_in_background: false` (absent under fork mode; never sufficient alone). Save the worker's final JSON block; a failing save is a Gate 1 FAIL. Parallel units: open each, then all Agent calls in one message.
   ```
   orchestrate report save U1 <file.json>
   ```
7. **Gate 1, run by you**, never taken from the report; then close the dispatch with its result. `--cold` when the unit touched build config or dependencies.
   ```
   orchestrate gate run U1 unit --cwd <worktree> --since <unitBaselineSha>
   orchestrate dispatch close U1 <n> --exit <Gate 1 result> --tokens <subagent_tokens> --duration <sec> --evidence gates/U1-unit-<n>.log
   ```
8. **Gate 2 by risk.** If `git -C <worktree> merge-base --is-ancestor <lastIntegratedSha> <headSha>` is false, merge the integration branch into the unit branch, re-run Gate 1 (step 7), note the merge in `dispatch-log.md`, and use the post-merge `headSha`. Fill every `templates/verify.md` input, `diffRange <baselineSha>..<headSha>`; a missing input is a FAIL. Role `verifier`; `dispatch open` carries the verifier's own model and effort: `verifier-fast` `--model haiku --effort low`, `verifier-deep` `--model sonnet --effort xhigh` (tiering: SKILL.md Gate 2). A planned skip is `unit set U1 pending --spot-check <text>`, a named ship-gate item. Fix rounds: `--role fix` on the same branch, then `--role reverify` from `templates/reverify.md` (open IDs only, `diffRange <lastPassedSha>..<headSha>`).
9. **Integrate, one unit at a time.** Integration into unit, re-gate, unit into integration, integration gates: warm; `--cold` when the merge touched build config or dependencies, and always for the last unit. Push only after the integration gate passes. `unit set` recomputes `nextAction` (next pending unit, else `ship-gate`).
   ```
   git -C <worktree> merge <integrationBranch>
   orchestrate gate run U1 unit --cwd <worktree>
   git merge --no-ff unit/U1
   orchestrate gate run U1 integration [--cold]
   orchestrate unit set U1 integrated --sha <mergeSha> --evidence gates/U1-integration-<n>.json
   ```
10. **Conflicts.** Keep-both plus renumber is valid ONLY for ordered registries. Resolve code conflicts semantically, then repeat step 9's gates (field case: REFERENCE.md).
11. **Shared docs**: one owner unit per wave, others writing fragments to `docs/_pending/<unit>.md` appended at integration, or append-only per-unit sections (`## <unit>: <title>`) merged keep-both. Parallel units never share a prose section.
12. **PR state.** One PR per integration branch; unit PRs target it. Already merged upstream: the unit is `integrated` (record its SHA); closed unmerged: a failed attempt against its budget.
13. **Ship gate, cold, over the integrated diff** (`nextAction` reads `ship-gate`). Then `/code-review` and `/security-review` where the host has them (zero dispatch budget), otherwise reviewer dispatches on the reserved `ship` pseudo-unit (outside the slot sum). One fix round, one re-review; rest surfaced.
    ```
    orchestrate gate run - ship
    orchestrate dispatch open ship --role review|security|fix|reverify --epoch <owner.epoch> --model <m> --effort <x>
    ```
14. **Close out.** `archive check` must exit 0; then `orchestrate complete` (alias of `next set complete`) makes `orchestrate status` print `COMPLETED`. The final report: what shipped, what is parked, the `orchestrate cost` line verbatim (USD only with manifest `pricing`). Append every escalated or surfaced unit to `.claude/escalation-ledger.md` (unit description, initial tier, failure type spec/env/capability, final tier, outcome); if absent, create it with the header row `unit | initial tier | failure type | final tier | outcome`.
    ```
    orchestrate archive check
    orchestrate complete
    orchestrate cost
    orchestrate worktree remove U1
    ```

## Gate latency

Unit and per-merge integration gates run warm (`{{baseline}}` and `--since` select changed packages; a merge touching build config or dependencies re-gates cold). Two cold runs: the final integration gate and the ship gate. Shared dependency cache: the manifest's `install` must point every worktree at one store (`sharedCache.note` says how; the CLI does not set it up).

## What differs from foreman mode

- No foreground flag, no watchdog; checkpoint discipline, plan table, cap, retry budget and triage order: as SKILL.md.
- Hooks: PreToolUse ignores main-session Agent calls; SubagentStop is foreman-only; the Stop hook prints an open-run notice when work is left and never blocks, but does not fire after a user interrupt or an API error, so run `orchestrate status` after an interrupted turn.

## Resume after interruption

1. Disk before memory: `orchestrate status` (`COMPLETED` only for `nextAction` `ship-gate` or `complete`; everything else, paused included, is `STOPPED-AWAITING-RESUME`), then `checkpoint.json`, then `git log --oneline <baselineSha>..HEAD` (integration root).
2. Open dispatch with a report under `reports/`: gate and close it; without one, check the worktree branch; nothing there: close FAIL, redispatch within budget.
3. A foreman owned the run: `orchestrate lease take --agent orchestrator --expect <epoch>`. Paused: `orchestrate resume`.
4. `orchestrate archive check` before the next dispatch; `git merge-base --is-ancestor <unitSha> HEAD` before merging a unit again. Continue at step 6, first non-integrated unit.
