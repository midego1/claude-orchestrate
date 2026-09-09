# Changelog

All notable changes to the orchestrate plugin. The update notifier reads this file — keep the **Why update** line on every release.

## [Unreleased]

## [0.6.0] — 2026-09-09

Sixth field report, and the first release that ships tooling next to prose. Source: about 15 orchestrate runs on a commerce monorepo (2 foreman runs, 5 direct-mode runs, about 20 PRs) on Claude Code 2.1.266, every finding cross-checked by a second model against the plugin text and the run archives, and every harness claim re-verified against the Claude Code docs on 2026-09-09 plus one live probe on 2.1.260. Gate 2 "evidence or FAIL" caught 9 real defects before merge; almost everything else in the report was plumbing the plugin made the orchestrator hand-script.

**Why update:** foreman runs get a deterministic dispatch mode (a settings switch, a preflight, and a live probe instead of a prose rule the harness may not honor), a `bin/orchestrate` CLI replaces hand-scripted archives, checkpoints, worktrees, gates and the lease (30 to 40 percent of orchestrator tokens went to that plumbing), and four hooks now enforce what used to be attentiveness: a stopped foreman with work left is blocked once, a fenced-out or stale foreman cannot dispatch, and an open run is announced when the session stops.

- **Dispatch mode is explicit and enforced (F2, H1 to H4)**: the docs confirm that fork mode (interactive default since 2.1.232) runs every subagent in the background and removes the Agent tool's `run_in_background` parameter, and that `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` runs every subagent in the foreground in every kind of session. Two feedback claims were narrowed on the way: `CLAUDE_CODE_DISABLE_FORK_MODE` does not exist (fork mode is `CLAUDE_CODE_FORK_SUBAGENT=0`), and "Agent is not in the background tool set" is version-dependent, not universal (a 2.1.260 probe: a background subagent had Agent, and its nested call with `run_in_background: false` returned inline). The plugin therefore keeps the flag on every worker dispatch and adds three layers for foreman runs: the settings `env` block (README Setup), `orchestrate preflight` (version, mode, spawn depth, model-force; refuses the foreman layer on depth < 2 or `CLAUDE_CODE_SUBAGENT_MODEL_FORCE=1`), and the foreman's Agent probe as the decisive test (inline result = foreground, async launch = planner mode), recorded with `orchestrate harness set dispatch`
- **`bin/orchestrate` (F1, M1, M2, M3)**: `preflight`, `init` (temp dir + one rename; adds `.claude/orchestrate-runs/` to `.git/info/exclude`), `plan set` (cap from planned slots), `unit set` (recomputes `nextAction`), `dispatch open/close` (records model, effort, tokens, duration, evidence; refuses at the cap, on a stale epoch, on a paused or complete run, and on a fourth worker dispatch), `lease take --expect` / `lease check` (compare-and-swap under a `mkdir` lock; macOS has no `flock`), `handoff`, `stall record`, `worktree add --at <sha>` (branch `unit/<id>` by default, env bootstrap + install from the manifest) / `worktree remove`, `gate run <unit> unit|integration|ship` (records command + exit under `gates/`, `--cold` deletes cache paths, `--since` substitutes `{{baseline}}`, `--cmd` for repos without a manifest), `report validate/save`, `archive check`, `status` (the STATE line from disk), `cost`, `stale`, `pause/resume`, `next set`, `complete`. bash 3.2 + python3 stdlib only. `tests/cli.sh` runs 341 checks in a temp repo
- **Hooks instead of prose (F10, H5)**: `SubagentStart` injects the checkpoint summary, the lease epoch and the mandatory first actions into the foreman; `SubagentStop` blocks a foreman once when `nextAction` is neither `ship-gate`, `complete` nor `paused:` (then lets it through with a user-facing notice); `PreToolUse` on `Agent` denies a foreman's dispatch when the checkpoint is missing, stale (> 20 min), owned by the orchestrator (`dispatchMode: DIRECT`), complete, or at the cap; `Stop` prints an open-run notice in the main session (it does not fire on a user interrupt; `orchestrate status` is the fallback). All silent outside orchestrate runs, fail-silent, never write to the repo. `tests/hooks.sh` runs 107 fixture checks
- **Schemas (F4, F8, F11)**: `schemas/checkpoint.schema.json` (v2: `harness`, `dispatchMode`, `capSource`, `units[].dispatches[]` with model, effort, tokens, duration, evidence; validated before every write), `schemas/worker-report.schema.json` (the worker's final text is one JSON block: branch, commits, files, gates, criteria with IDs, deviations, env vars, pending runtime checks, `backgroundProcesses: "none"`), `schemas/gates-manifest.schema.json` for `.claude/orchestrate-gates.json` (install, env bootstrap, cache paths, warm unit gates, integration gates, cold ship gates, optional e2e, pricing). JSON rather than the proposed YAML: the CLI is shell plus python3 stdlib and no YAML parser is guaranteed. Example in `examples/orchestrate-gates.json`
- **Templates**: `templates/dispatch.md` (contract with criterion IDs, the standard preamble, the JSON report, the new line "never leave background processes; end only when nothing you started is running" (F7)), `templates/verify.md` and `templates/reverify.md`
- **Verifier inputs (F5)**: both verifiers require `unit`, `repoRoot`, `baselineSha`, `headSha`, `diffRange` and criterion IDs, open with a `RANGE:` line, and return `INPUT-MISSING` / `BASE-MISMATCH` as FAIL instead of guessing; the dispatcher merges the integration branch into the unit branch first when the worktree predates a sibling's merge, so the stale-baseline false FAIL cannot recur
- **`DIRECT-MODE.md` (F3)**: the common path as one ordered 14-step checklist: preflight, init, plan, exact-baseline worktree, contract, dispatch, Gate 1 after the worker (dispatch closed with the gate log as evidence), Gate 2 by risk, merge the integration branch into the unit branch before merging or pushing, keep-both only for ordered registries (code conflicts are resolved semantically; a keep-both on a component file produced duplicate imports), shared docs rule, PR state, cold ship gate, close-out with the cost line
- **Operator card and `REFERENCE.md` (F9, M4)**: SKILL.md opens with a one-screen card covering the whole run and the lifecycle musts (tripwire, watchdog, notification handler, STATE line, wind-down, no live children); it is 4,499 words, down from 6,669, with every rule kept and every field anecdote moved to `REFERENCE.md` with a back-reference. "Never read files directly" is now scoped: never worker output, logs, diffs or failure histories; the checkpoint, gate one-liners, the plan table, merge conflicts and the integrated diff are yours
- **Budget from planned slots and a cost line (F8, M5)**: cap = 4 per verified unit (worker, verifier, fix, re-verify) + 2 per skip-Gate-2 unit + 4 for the ship gate, replacing 3x unit count; ship-gate reviewers dispatch against a reserved `ship` pseudo-unit; `orchestrate cost` prints tokens and duration per model (USD when the manifest carries pricing) and the final report quotes it. The per-unit budget of 3 worker-role dispatches is unchanged and now CLI-enforced
- **Shared docs registries (F12)**: one owner per shared file per wave, or per-unit fragments merged at integration, or append-only per-unit sections; never two parallel units in one prose section
- **Gate latency (M6)**: per-unit gates warm with one shared dependency store (the manifest's `install` command points every worktree at it), changed-package selection via `{{baseline}}`, per-merge integration gates warm unless the merge touched build config or dependencies, and exactly two cold runs per run: the final integration gate and the ship gate (the v0.5.3 rule, kept at full strictness)
- **STATE line and `nextAction`**: `nextAction` vocabulary is `setup | dispatch <ids> | integrate <id> | ship-gate | complete | paused: <reason>`; `COMPLETED` when it reads `ship-gate` or `complete`, `STOPPED-AWAITING-RESUME` for everything else including a paused run; `orchestrate status` prints the line
- **Foreground foreman**: with the background-tasks switch the foreman is a foreground child, its tool result is the notification and the in-turn watchdog is the harness stall abort (`CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS`); the timer watchdog and mid-turn wind-down apply only to a background foreman
- **Kept on purpose**: the ship gate stays a separate review of the integrated diff (F6, rejected in the field too: it found an impossible user remedy after a scoped re-verify had passed); agent teams stay deferred, still experimental behind `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (H6); manual worktrees at the exact baseline SHA stay the rule (`isolation: worktree` branches from the default branch, H7)
- **Portable edition** carries the agent-agnostic parts: JSON worker report, verifier inputs, no background processes, planned-slot cap, the direct-mode checklist, the scoped read rule, and a note to find the host's foreground switch before using a foreman layer
- **Migration from 0.5.5**: for foreman runs add `"env": {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1"}` to the project's `.claude/settings.json` (README Setup); optionally add `.claude/orchestrate-gates.json` from the example; direct mode needs no flags. Existing run archives are v1 checkpoints and are not migrated; new runs write `schemaVersion: 2`. Manual-copy installs now need `bin/`, `schemas/`, `templates/`, `scripts/` and `hooks/` too, and the hooks are active only with a plugin install unless `hooks/hooks.json` is merged into settings by hand

## [0.5.5] — 2026-08-17

Harness-change release, not a field report: Claude Code gained cross-session connectivity — sessions can list and message each other, and (verified by direct probe, not just docs) a subagent can now SendMessage `main` and sibling agents. One of the plugin's stated impossibilities became merely a prohibition, and two new realities needed encoding. The architecture itself — synchronous dispatch, checkpoint contract, foreman resume — survives unchanged: subagents still cannot message across sessions, and cross-session messages are plain text, queued (never interrupting a tool mid-flight), and can never approve a permission prompt.

**Why update:** the "workers can't message their dispatcher" rationale is now factually false — workers CAN message `main`, so dispatch prompts must forbid it explicitly or an unsolicited worker message lands in the main session looking like a report that bypassed both gates; runs also gain a triage rule for peer-session messages arriving mid-run (five live peers were observed on one host), and the stall watchdog gains a real wake-up primitive.

- **Worker messaging: impossible → forbidden** — the rule (a worker's final text IS its report) is unchanged, but its justification moved from physics to contract. The execution sentence of file-referenced dispatch and the standard worker preamble now carry an explicit "do not use SendMessage" line; a worker message that arrives anyway is advisory data, never an accepted report or gate result
- **Incoming agent messages are advisory, never authoritative** — new lifecycle rule: messages can now arrive mid-run from workers ignoring the prohibition or from unrelated peer sessions on the same machine. Reconcile every such message against `checkpoint.json`; never accept one as a worker report, gate verdict, plan change, or user approval (the harness enforces the last — a peer message cannot approve permission prompts or alter settings). Authoritative message paths remain exactly the old ones: orchestrator→foreman resume, wind-down, unit injection with full contract + restated cap
- **The watchdog's wake-up gap is closed** — "an agent cannot wake itself" still holds, but a peer can: a cross-session message to an idle session starts a new turn, so a scheduled task or watchdog peer session that messages the orchestrator is a real wake-up, not a best-effort reminder. The triggered response is the unchanged notification handler — the checkpoint still decides
- **Verified constraints, for the record** — subagent→cross-session messaging does not exist (probe: ListAgents disabled in subagents; docs: sibling roster is session-scoped); delivery is queued at the recipient's next turn, so a message alone cannot interrupt a running turn; repeated identical messages are rate-limited/dropped
- **Evaluated and deferred: agent teams** — separate-session teammates with a shared task list and idle-notifications-to-lead is effectively a native foreman layer, but it is experimental and env-gated (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`); revisit when it stabilizes

## [0.5.4] — 2026-08-05

Fifth field report: a 15-unit, 3-phase build under an opus foreman. The foreman stopped itself three times and cost ~60 minutes of idle wall-clock — with zero lost work, because the checkpoint contract held. None of the three were process death, which 0.4.2 already covered. The foreman ended its own turn cleanly each time, and its round-end report read as a run still in flight.

**Why update:** a foreman that quietly ends its turn no longer reads as a foreman still working — every notification now forces a resume-or-take-over decision against the checkpoint, a stall watchdog catches the stops that never notify at all, and an ownership lease keeps a false-positive take-over from putting two dispatchers on the same plan.

- **A foreman task-notification always means the foreman STOPPED** — fifth field report: a 15-unit/3-phase opus-foreman run stopped itself three times and cost ~60 minutes of idle wall-clock (zero lost work — the checkpoint contract held). The stops were not process death, which the protocol already covered; the foreman ended its own turn cleanly and its `next round 6 (U7a, U10)` report read as intent-to-continue. There is no notification for "still working," so on any foreman notification the orchestrator now must immediately resume it or take the remaining work over in direct mode
- **Notification handling is a two-branch handler, and the checkpoint decides** — read `checkpoint.json`: `nextAction: complete` means finished, go to the ship gate; anything else means stopped, so resume or take over. Stopped runs and finished runs both notify, and only disk tells them apart
- **STATE line carries a terminal token** — `STATE: … · next <unit> · STOPPED-AWAITING-RESUME|COMPLETED`. A returned result has exactly two legal tokens, because a result is a turn that ended and cannot claim to be continuing; `CONTINUING` survives only as an in-turn progress line immediately followed by a dispatch. The producer rule behind it: do not end your turn while authorized work remains
- **Stall watchdog, named and armed** — harness agent status first; without one, two decisive signals (checkpoint mtime stale ~20 min AND no file writes ~5 min) plus a build/test process check that is advisory only, since it is host-wide and can neither confirm nor veto. Recurring check recommended past ~30 minutes; a false positive costs one idempotent resume message, a false negative costs 43 idle minutes
- **Repeat stalls use restart intensity, not a lifetime count** — borrowed from OTP supervision, which counts restarts per period and defaults to intensity 1: one resume per window (a phase, or ~60 min), and a second stall inside that window means stop resuming and take the loop over. Two stalls an hour apart in a long run are unrelated and each earns a resume; two inside one phase are recurrence, and a third just re-runs the failure at another ~20-minute detection window. `stallCount` + `lastStallAt` live in the checkpoint so context compression cannot reset the window
- **Ownership lease closes the double-dispatch hole** — a take-over bumps `owner.epoch`; every dispatcher re-reads it at the checkpoint write it already owes before dispatching, and aborts if the epoch moved. No new discipline, one new check
- **Driver boundary is exact: 5/6** — 5 units or fewer (and the tail of any phase, whatever the original plan size) dispatch directly; 6 or more get a foreman, always paired with the watchdog. The foreman's value is real — 4 concurrent worktree workers managed cleanly — but below the boundary that coordination no longer exceeds its turn-end risk
- **Checkpoint gains `integrationRoot`, `openWorktrees`, `owner`, and `stallCount`** — all four now seeded by the atomic setup command, because a stopped foreman leaves no shell variables behind and a watchdog reads everything from disk
- **No migration needed for Claude Opus 5 (or future model releases)** — the plugin routes every dispatch through Claude Code's model aliases (`haiku` / `sonnet` / `opus`), never pinned IDs like `claude-opus-4-8`. When Anthropic repoints an alias to a new release — as with Opus 5 — every tier, the foreman, and both verifiers pick it up automatically: no config change, no plugin update. The only pinned ID in the repo is the README's session-model recommendation (`claude-fable-5`), which is unaffected
- Caveat for tuners: the routing heuristic "Sonnet at xhigh often matches Opus at high" was calibrated on the 4.x family — re-validate on a real run before leaning on it for 5-family routing decisions

## [0.5.3] — 2026-07-24

Fourth field report: a ~60-dispatch production-readiness run (10-unit audit → 25 fix units in 3 waves → gates → ship-gate → PR) on v0.4.2 agents. Its P0 — a foreman without the Agent tool silently degrading to self-review and reporting green gates — was already closed by 0.5.2's capability preflight and DIRECT degraded mode; this release encodes everything else the run paid for.

**Why update:** shared-worktree runs stop corrupting each other's git state (one field `git stash` swept a concurrent worker's uncommitted work into an orphan stash), go/no-go gates stop lying from warm caches (a lint count swung 40–1800 with cache freshness, hiding the 2 real errors), and unverifiable failures stop burning escalations on attempts nothing can check.

- **Foreman precondition stated where delegation is defined** — the foreman layer is valid only when the foreman can itself dispatch workers and verifiers; a non-dispatching foreman's PASSes are self-reviews and must be discarded
- **Shared-worktree git hygiene** — a hard rule in every file-mutating dispatch prompt when writers share a tree: scoped `git add <path>` only, never `git add -A` / `git add .` / `git stash`; dependency adds reported for serial install, never a lockfile-rewriting full install under concurrency
- **Post-wave tree audit** — after any wave of concurrent shared-tree writers: `git status`, `git stash list`, per-commit file scope — before the integration gate
- **Concurrency ceiling for shared trees** — 2–3 file-mutating writers with disjoint declared file scopes; a 4th reliably produced build-cache contention and a phantom typecheck failure; read-only workers and verifiers exceed freely
- **Cold go/no-go gates** — the final integration gate and ship gate clear build caches first (`.turbo`, package `dist`, `.cache`, `*tsbuildinfo*`), matching a fresh CI runner; per-unit gates may stay warm
- **Verifiability-gap triage branch** — when the failure mode structurally can't be exercised by the repo's test infra, don't escalate the model (it buys another unverifiable attempt); reduce the unit to the verifiable subset, ship that, surface the remainder naming the missing test infra
- **Verifier rationing encoded** — security- and data-loss-critical units always get a dedicated independent verifier; mechanical/config units ride the ship-gate review as their named spot-check
- **Ship gate prefers host `/security-review`** — it reviews the branch diff directly with its own false-positive filtering and consumes zero dispatch budget

## [0.5.2] — 2026-07-22

**Why update:** dispatch failures are caught up front and degrade gracefully instead of stalling the run; dispatch contracts persist on disk and retries reuse them; fixing a gap no longer discards already-verified work; recovery always reads state from disk.

- **Capability preflight** — the foreman's first tool action is a trivial Agent call confirming dispatch works; on error it reports immediately
- **DIRECT degraded mode** — if dispatch is unavailable, the orchestrator runs the loop and the foreman becomes planner: contracts + final-gate runbook to `dispatch/*.md`, checkpoint handed over (`dispatchMode: "DIRECT"`); a blocked foreman never simulates a gate it can't run
- **File-referenced dispatch** — contracts live in `dispatch/<unit>.md`; the Agent prompt is a pointer; a retry is the same pointer plus the verdict
- **Tool availability by real call** — ToolSearch indexes deferred tools only; availability is tested by calling, not searching
- **Worker fast-forward remedy** — a worker strictly behind the baseline may `--ff-only` to it, with disclosure; any other base mismatch stops
- **Two retry shapes** — attempt failure: reset to baseline, fresh dispatch; verifier-found gap in verified work: incremental fix round on the same branch, then a scoped re-verify pinned to `<lastPassedSha>..HEAD`
- **Ordered-registry integration** — same-slot claims from parallel units resolve by keep-both + renumber; validate only the invariants the consuming runner requires
- **Disk before memory** — after context compression or interruption, the orchestrator re-derives run state from `checkpoint.json` + git log before acting

## [0.5.1] — 2026-07-21

Second field report, from a third production wave that ran with the 0.5.0 rules injected via prompt while agent defs were still 0.4.2 — a natural experiment proving where discipline must live: prompt-carried rules eroded again (third foreman in a row wrote an empty archive), file- and agent-def-carried rules held.

**Why update:** the checkpoint can no longer silently not-exist (atomic one-command archive seed + orchestrator first-status-check tripwire), archive paths stop landing in the wrong repo root (pinned via `git rev-parse --show-toplevel`), worker worktrees fork at the exact baseline (manual `git worktree add <sha>` preferred over SDK isolation), reachability now covers init/registration wiring (a dead-in-production drain loop passed every import grep), and the wind-down order that produced the cleanest pause of three runs is protocol.

- Atomic archive seed command in both SKILL.md and foreman.md — dirs + seeded `checkpoint.json` + `dispatch-log.md` in one command; "dirs exist, files don't" is structurally impossible
- Orchestrator checkpoint tripwire on first status check, with the field-proven corrective text
- Archive path resolved once at the integration-worktree root, stored in the checkpoint, never recomputed
- Manual worker worktrees at the exact baseline SHA; the preamble merge-base check demoted to backstop
- Reachability ⊇ init contracts: stateful modules name their init site in done-criteria; the init-hook invocation is grep-verified at Gate 1
- Wind-down lifecycle order (complete in-flight, integrate passers, surface without retrying, final checkpoint with resume plan, STATE line) + SendMessage next-tool-round delivery-latency caveat (~45 min in the field)
- Skipped-Gate-2 units register a named final-gate spot-check; the global cap explicitly counts workers + verifiers + retries

## [0.5.0] — 2026-07-21

Hardened against a real two-wave production run (33 units, ~35 workers across two foremen, 4 foreman process deaths — all environmental, zero capability escalations, 3 ship-gate MAJORs caught). Every change traces to observed field evidence.

- **Checkpoint contract (change 1)**: free-form archive guidance replaced by a required `.claude/orchestrate-runs/<run>/checkpoint.json` — runId, integration branch, baseline/last-integrated SHAs, dispatch tally, per-unit status, nextAction — rewritten atomically before every dispatch round and after every integration; checkpoint-before-dispatch is as mandatory as the gates. Archive layout (`dispatch/`, `reports/`, `gates/`, `failures/`) specified once, in both the skill and the foreman def. In the field, one foreman kept a good narrative log and the other created the directories but wrote zero files; every crash recovery was git archaeology
- **Foreman lifecycle (change 2)**: long runs assume the foreman WILL be killed — all 4 observed deaths were environmental (network, spend limit, host restart), now an explicit orchestrator-level triage class. Canonical recovery: checkpoint first, SendMessage-resume the same foreman (worked 4/4 in the field), fresh foreman only as fallback — explicitly disambiguated from the worker no-resume rule. Mandatory `STATE:` line ends every foreman turn (the last result blob is often all the orchestrator gets). Mid-run plan changes documented: full unit spec + explicit new global cap via SendMessage
- **Gate-1 reachability for UI units (change 3)**: an import-chain grep proving each new component is reachable from a route — the field run shipped four fully-built, verifier-PASSed components imported nowhere; every mechanical gate passes on dead code
- **Standard worker preamble (change 4)**: canonical block for worktree-isolated workers — verify your base with `git merge-base --is-ancestor` (fail fast, never improvise a branch), install command + no-runtime rules with EXECUTION-PENDING labeling, the phantom-failure rule (re-check failures on the untouched base; dependency drift caused two phantom typecheck failures), capped return contract. Orchestrator counterpart: keep the integration worktree on the integration branch when forking
- **Foreman inline-fix policy (change 5)**: small direct commits allowed (env repairs, mechanical glue) but each needs Gate 1 evidence + a `foreman-fix` ledger entry, and never security/correctness-critical code — a field foreman committed a security fix directly and it got zero Gate 2 review
- **Canonical routing-plan table**: the pre-dispatch announcement (already mandated) now has a specified format — unit | tier | model | effort | isolation | verifier | dispatches, plus a cap line — so every run shows the same glanceable "what's kicked off, on which models" preview before any spend; rows map 1:1 onto the checkpoint's `units` array. Announced once — running progress stays in the STATE line and the run archive
- **Amendments (change 6)**: tier distribution qualified per work-type (spec-heavy schema/engine/UI builds legitimately run 40–50% T2; investigate only when T2 share AND escalation rate are both high); "encode missing context back" promoted to the ledger's headline rule — it eliminated a repeat Gate-2 failure class in the field; load-bearing rules marked "do not soften"

**Why update:** on v0.4.2 a killed foreman leaves no recoverable state — and long runs get killed (4 times in one production run); v0.5.0 makes every run checkpointed and resumable, and closes the dead-code blind spot where all gates pass on components nothing imports.

## [0.4.2] — 2026-07-17

Fixes worker→foreman result routing, observed in a live run on v0.4.1: retried workers' completions escalated to the main session instead of the idle foreman, and workers trying to SendMessage the foreman failed (agent handles are session-scoped) — every retry result bounced through the orchestrator, the exact overhead the protocol exists to avoid.

- **Workers and verifiers are dispatched synchronously** — `run_in_background: false`, passed explicitly because background is the harness default. Wave parallelism = multiple Agent calls in a single message (parallel tool use); results return inline as tool results, no notification routing involved
- **A worker's final text IS its report**: dispatch prompts must never instruct a worker to SendMessage, notify, or report to the foreman or main — workers hold no handle to their dispatcher
- **Retries are fresh synchronous dispatches** carrying the failed attempt's report + verifier verdict — never a SendMessage-resume of an idle worker (a resumed worker doesn't count as the sender's live background child, so its completion escalates to the main session)
- **Background workers forbidden**; over-long units get split instead. Escape hatch: if one exists anyway, the foreman polls observable state (branch/commit SHA, archive files) rather than idling for a notification. The foreman itself may still run in the background — the orchestrator spawned it, so its completion routes back correctly
- Portable edition aligned: prefer inline-returning sub-tasks; poll observable state when async dispatch is unavoidable

**Why update:** on v0.4.1 every retried worker's result detoured through your main session, costing orchestrator turns and tokens; v0.4.2 makes all worker dispatch synchronous so results return inline.

## [0.4.1] — 2026-07-17

- Update notifier now checks at most once per **hour** (was 24h) — releases can land daily or faster, and one silent hour is a better trade than a silent day

**Why update:** you hear about new releases within the hour instead of within the day.

## [0.4.0] — 2026-07-17

Contract-precision release: every P1 from an adversarial cross-model review (OpenAI Codex, 29 findings) fixed, plus an opt-in update notifier.

- **Evidence references everywhere**: foreman PASS lines must carry their evidence (command + exit code / verdict location); full logs archived to `.claude/orchestrate-runs/`, referenced not inlined — closes the "trust the foreman's bare PASS" paradox
- **Integration protocol**: baseline commit recorded per unit; isolated workers return branch + commit SHA; sequential merge-back with Gate 1 re-run after each merge; reset-to-baseline before retries (no cross-attempt contamination)
- **Retry semantics made precise**: attempt = one dispatch; max 3 dispatches per unit (original + 1 same-tier retry + 1 escalation); escalation = one bump, effort before model; re-decomposition grants a fresh budget once; global dispatch cap (default 3× unit count)
- **Ship gate bounded**: one fix round + one re-review, then surface — no fix/review loops
- **Verifier-deep `MISSING` lines**: novel defects outside the stated criteria now have an output slot; verifiers explicitly read-only
- **Triage decision guide**: how to tell spec vs environment vs capability; unclear failures default to environment
- **Partial-ship policy**: a surfaced unit parks only itself and its dependents; independent passed units ship
- **Update notifier**: SessionStart hook checks for a newer version at most once per 24h and shows what changed and why — never installs anything, updating stays your choice
- **Honesty pass**: portable edition states plainly that cost-routing needs per-dispatch model selection; instruction-file edits require user approval; "near-deterministic" claims softened
- README: "Which effort, when?" guide (high vs xhigh/**"Extra"** in the desktop app vs ultracode vs max), Updates section

**Why update:** the v0.3.0 protocol had contract gaps an executing agent could exploit or trip over — unverifiable PASS claims, undefined retry accounting, worktree changes that never merged back. v0.4.0 closes all of them.

## [0.3.0] — 2026-07-17

Tuned against Boris Cherny's *Steps of AI Adoption* maturity model.

- **Ship gate**: automated code review + security review over the *integrated* diff before shipping — unit gates catch unit bugs; the ship gate catches what only exists after integration
- **Worktree isolation preferred** over serialization for file-mutating parallel workers
- **Gate 1 broadened**: lint + end-to-end check against a real dev environment
- **Ledger → standards feedback**: missing-context spec failures get encoded into `CLAUDE.md`/skills instead of just logged
- README: "Where this fits" (adoption-curve positioning), ops tip on pre-approved commands

**Why update:** without the ship gate, integration-level bugs (conflicting units that each passed their own gates) reach your branch unreviewed.

## [0.2.0] — 2026-07-17

- **Portable edition** (`portable/orchestrator.md`): agent-agnostic protocol for OpenAI Codex (ChatGPT app, CLI, IDE, web), opencode, Cursor, Gemini CLI, GitHub Copilot, Aider — capability tiers instead of pinned model names, graceful fallbacks for missing primitives
- **gitleaks CI** on every push/PR + GitHub secret scanning & push protection
- README: architecture diagram (mermaid), ultracode/ultrathink relationship, marketplace notes

**Why update:** teams mixing coding agents get one shared protocol instead of Claude-only behavior.

## [0.1.0] — 2026-07-17

Initial release.

- `orchestrate` skill: tiered model routing (T0–T3), evidence-gated verification (Gates 1–3), failure triage (spec/env/capability), hard retry budget (2 attempts + 1 escalation per unit)
- Agents: `foreman` (opus @ high), `verifier-fast` (haiku), `verifier-deep` (sonnet @ xhigh)
- Escalation ledger, dispatch contract, reader split (haiku extraction / sonnet comprehension)
