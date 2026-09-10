# Direct mode: the ordered checklist

Direct mode: plans of 5 units or fewer, the tail of any phase, or degraded mode at any size.
You run the loop in the main session; gates and evidence-or-FAIL apply as in SKILL.md "Core loop".
Resolve the plugin root once per session: plugin install → `ls -d ~/.claude/plugins/cache/claude-orchestrate/orchestrate/*/ | sort -V | tail -1`; manual checkout → the repo directory. Quote it. `orchestrate` below means `"<plugin root>/bin/orchestrate"`. Exit 1: error or no manifest; 2: refused by policy; 3: failed gate.
Gates and bootstrap read `.claude/orchestrate-gates.json` (fallback `orchestrate-gates.json`). Without one, `worktree add` skips bootstrap and `gate run` takes `--cmd <id>=<command>` options or the unit's saved report gates, still recording under `gates/`.
Steps run in order, each written to disk before the next.

## Checklist

1. **Preflight.** Record the result.
   ```
   orchestrate preflight
   ```
   `foreman-refused` under `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1` blocks direct mode too; spawn depth below 2 does not.
2. **Init**, in the integration root on the integration branch (records baseline, branch, lease `epoch 1`, the `ship` pseudo-unit). `--mode` defaults to `DIRECT` (printed as `mode: DIRECT`); `--mode FOREMAN` only when handing to a foreman.
   ```
   orchestrate init [--branch <b>] [--cap <n>]
   ```
   Degraded mode: never init twice. The foreman's `handoff --to orchestrator` already set `dispatchMode: DIRECT`; only if it stopped without handing off, take the lease:
   ```
   orchestrate lease take --agent orchestrator --expect <owner.epoch>
   ```
3. **Plan table and cap.** Register every row, then paste the `plan show` output verbatim into your reply before the first dispatch; dispatching without that pasted table is a protocol violation.
   ```
   orchestrate plan set U1 --tier T1 --model sonnet --effort high --verifier fast --isolation worktree [--depends U0]
   orchestrate plan show
   ```
   Cap = planned slots: 4 per verified unit, 2 per skip-Gate-2 unit, plus 4 for the ship gate. Every manifest unit-stage gate must pass on the baseline; a gate that only exists after a unit is that unit's own `[run]` criterion; units that need it get `--depends`.
4. **Worktree per unit** at the unit's baseline: `git rev-parse HEAD` in the integration root at dispatch time (the run `baselineSha` for the first wave; the post-merge HEAD once its `--depends` targets are integrated). That SHA feeds `dispatch/U1.md`, the verifier's `baselineSha` and `gate run --since`. The worktree lives at `<integrationRoot>/.claude/worktrees/U1` (git-excluded; printed by the command, filled in by `contract new`), checks out `unit/U1` (`--branch` overrides; never `--detach`) and runs `envBootstrap` and `install`. Never `isolation: worktree`.
   ```
   orchestrate worktree add U1 --at <unitBaselineSha>
   ```
5. **Contract on disk.** `orchestrate contract new U1 [--objective <text>] [--files <csv>]` writes `dispatch/U1.md` from `templates/dispatch.md` with every value the CLI knows filled in (worktree, branch, baseline, integration branch, gates with `{{baseline}}` substituted, bootstrap, docs, token cap) and prints the placeholders left. Edit those before dispatching: criterion IDs `C1..Cn` (`[run]` on every criterion that executes something), constraints, depth. `--force` to overwrite. Agent prompt: the pointer plus the execution sentence; a retry adds the verdict.
6. **Dispatch**: open, call, save. `<n>`: the number `dispatch open` prints.
   ```
   orchestrate dispatch open U1 --role worker --epoch <owner.epoch> --model sonnet --effort high
   ```
   Then the Agent call, `run_in_background: false` (absent under fork mode; never sufficient alone). Save the worker's final JSON block from stdin (bare or fenced); a failing save is a Gate 1 FAIL. Parallel units: open each, then all Agent calls in one message.
   ```
   orchestrate report save U1 - --worktree <worktree> --run-criteria <run IDs> <<'EOF'
   <worker JSON>
   EOF
   ```
7. **Gate 1, run by you**, never taken from the report; then close the dispatch with its result. `report save` rejects a `[run]` PASS without a non-empty artifact and archives the artifacts. `--cold` when the unit touched build config or dependencies.
   ```
   orchestrate gate run U1 unit --cwd <worktree> --since <unitBaselineSha>
   orchestrate dispatch close U1 <n> --exit <Gate 1 result> --tokens <subagent_tokens> --duration <sec> --evidence gates/U1-unit-<n>.log
   ```
8. **Gate 2 by risk.** If `git -C <worktree> merge-base --is-ancestor <lastIntegratedSha> <headSha>` is false, run `orchestrate worktree sync U1 --gate` and use the post-merge `headSha`. `orchestrate contract verify U1 --head <headSha> [--deep]` writes `dispatch/U1-verify.md` with every input filled (`diffRange <baselineSha>..<headSha>`, newest report, criteria copied from `dispatch/U1.md`, `verifier-fast` unless `--deep`) and prints the Agent pointer; a missing input is FAIL; a `[run]` criterion is judged from its artifact. Role `verifier`; `dispatch open` carries the verifier's own model and effort: `verifier-fast` `--model haiku --effort low`, `verifier-deep` `--model sonnet --effort xhigh`. A planned skip is `unit set U1 pending --spot-check <text>`: a named ship-gate item that the ship-review dispatch lists as a criterion. Fix rounds: `--role fix` on the same branch, then `--role reverify` via `contract verify U1 --head <sha> --scope <open IDs> --prior <verdict ref> --since <lastPassedSha>` (`templates/reverify.md`, `diffRange <lastPassedSha>..<headSha>`).
9. **Integrate, one unit at a time**, one command in the integration root (exit 1 off the integration branch or with uncommitted tracked changes): `worktree sync U1 --gate` (integration branch into the unit worktree, install if the lockfile changed, Gate 1; exit 3 on conflict or gate FAIL, nothing merged), `git merge --no-ff unit/U1` (conflict: aborted, exit 3: step 10), `docs apply U1` plus its commit (step 11), `gate run U1 integration` warm (`--cold` after build-config or dependency changes; implied for the last unit; FAIL: exit 3, merge left in place, unit unmarked), then `unit set U1 integrated --sha <HEAD after the docs commit> --evidence gates/U1-integration-<n>.json`. Push only after it passes (step 12).
   ```
   orchestrate integrate U1 [--cold]
   ```
10. **Conflicts.** Keep-both plus renumber is valid ONLY for ordered registries. Resolve code conflicts semantically in the unit worktree, re-run `gate run U1 unit --cwd <worktree>`, then `orchestrate integrate U1 --no-sync`.
11. **Shared docs**: workers write `<fragments>/<unit>.md` (manifest `docs[]`: `fragments`, `target`, exact `section` heading), never the target; `docs apply` appends it to the section as `### U1: <title>`, idempotent, and deletes the fragment; `integrate` commits target and deletion (`docs(U1): apply fragments`) before the integration gate. Without a `docs` entry, one owner unit per wave appends. Parallel units never share a prose section.
12. **PR state.** One PR per integration branch; unit PRs target it. Under manifest `ci.serial`, `orchestrate push U1 --pr` (push, PR, wait for `ci.checksCmd`; exit 2 while another unit's checks run; killed watch: re-run `push` for that unit; `--no-wait` only if parallel CI is accepted) one unit at a time. Merged upstream: `integrated` (record the SHA); closed unmerged: a failed attempt.
13. **Ship gate, cold, over the integrated diff** (`nextAction` reads `ship-gate`). Then host `/code-review` and `/security-review` ONLY when the orchestrated repo is the session cwd; otherwise `--role review` and `--role security` dispatches (sonnet @ xhigh) on the reserved `ship` pseudo-unit (outside the slot sum) with the integrated diff range `<baselineSha>..<lastIntegratedSha>` and every recorded spot-check as criteria. One fix round, one re-review; rest surfaced.
    ```
    orchestrate gate run - ship
    orchestrate dispatch open ship --role review|security|fix|reverify --epoch <owner.epoch> --model sonnet --effort xhigh
    ```
14. **Close out.** `archive check` must exit 0; then `orchestrate complete` makes `orchestrate status` print `COMPLETED`. The final report: what shipped, what is parked, the `orchestrate cost` line verbatim. Append every escalated or surfaced unit to `.claude/escalation-ledger.md` (failure type spec/env/capability); if absent, create it with the header row `unit | initial tier | failure type | final tier | outcome`.
    ```
    orchestrate archive check
    orchestrate complete
    orchestrate cost
    orchestrate worktree remove U1
    ```

## Gate latency

Unit and per-merge integration gates run warm (`{{baseline}}` and `--since` select changed packages). Shared dependency cache: the manifest's `install` must point every worktree at one store (`sharedCache.note` says how).

## What differs from foreman mode

- No foreground flag, no watchdog; checkpoint discipline, plan table, cap, retry budget and triage order: as SKILL.md.
- Hooks: PreToolUse ignores main-session Agent calls; SubagentStop is foreman-only; the Stop hook prints an open-run notice when work is left and never blocks, but does not fire after a user interrupt or an API error, so run `orchestrate status` after an interrupted turn.

## Resume after interruption

1. Disk before memory: `orchestrate status` (`COMPLETED` only for `nextAction` `ship-gate` or `complete`; everything else, paused included, is `STOPPED-AWAITING-RESUME`), then `checkpoint.json`, then `git log --oneline <baselineSha>..HEAD` (integration root).
2. Open dispatch with a report under `reports/`: gate and close it; without one, check the worktree branch; nothing there: close FAIL, redispatch within budget.
3. A foreman owned the run: `orchestrate lease take --agent orchestrator --expect <epoch>`. Paused: `orchestrate resume`.
4. `orchestrate archive check` before the next dispatch; `git merge-base --is-ancestor <unitSha> HEAD` before merging a unit again. Continue at step 6, first non-integrated unit.
