# Changelog

All notable changes to the orchestrate plugin. The update notifier reads this file — keep the **Why update** line on every release.

## [0.5.0] — 2026-07-21

Hardened against a real two-wave production run (33 units, ~35 workers across two foremen, 4 foreman process deaths — all environmental, zero capability escalations, 3 ship-gate MAJORs caught). Every change traces to observed field evidence.

- **Checkpoint contract (change 1)**: free-form archive guidance replaced by a required `.claude/orchestrate-runs/<run>/checkpoint.json` — runId, integration branch, baseline/last-integrated SHAs, dispatch tally, per-unit status, nextAction — rewritten atomically before every dispatch round and after every integration; checkpoint-before-dispatch is as mandatory as the gates. Archive layout (`dispatch/`, `reports/`, `gates/`, `failures/`) specified once, in both the skill and the foreman def. In the field, one foreman kept a good narrative log and the other created the directories but wrote zero files; every crash recovery was git archaeology
- **Foreman lifecycle (change 2)**: long runs assume the foreman WILL be killed — all 4 observed deaths were environmental (network, spend limit, host restart), now an explicit orchestrator-level triage class. Canonical recovery: checkpoint first, SendMessage-resume the same foreman (worked 4/4 in the field), fresh foreman only as fallback — explicitly disambiguated from the worker no-resume rule. Mandatory `STATE:` line ends every foreman turn (the last result blob is often all the orchestrator gets). Mid-run plan changes documented: full unit spec + explicit new global cap via SendMessage
- **Gate-1 reachability for UI units (change 3)**: an import-chain grep proving each new component is reachable from a route — the field run shipped four fully-built, verifier-PASSed components imported nowhere; every mechanical gate passes on dead code
- **Standard worker preamble (change 4)**: canonical block for worktree-isolated workers — verify your base with `git merge-base --is-ancestor` (fail fast, never improvise a branch), install command + no-runtime rules with EXECUTION-PENDING labeling, the phantom-failure rule (re-check failures on the untouched base; dependency drift caused two phantom typecheck failures), capped return contract. Orchestrator counterpart: keep the integration worktree on the integration branch when forking
- **Foreman inline-fix policy (change 5)**: small direct commits allowed (env repairs, mechanical glue) but each needs Gate 1 evidence + a `foreman-fix` ledger entry, and never security/correctness-critical code — a field foreman committed a security fix directly and it got zero Gate 2 review
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
