# Changelog

All notable changes to the orchestrate plugin. The update notifier reads this file — keep the **Why update** line on every release.

## [0.5.1] — 2026-07-21

Second field report, from a third production wave that ran WITH the 0.5.0 rules injected via prompt (agent defs still 0.4.2) — a natural experiment in where discipline must live.

**Why update:** the checkpoint can no longer silently not-exist (atomic seed command + orchestrator tripwire), archive paths stop landing in the wrong repo root, worker worktrees fork at the exact baseline, reachability checks now cover init/registration wiring (a dead-in-production drain loop passed every import grep), and the wind-down order that produced the cleanest pause of three runs is now protocol.

- **Atomic archive seed**: one command creates dirs + seeded checkpoint.json + dispatch-log.md — "dirs exist, files don't" is structurally impossible; orchestrator verifies the file on first status check and sends the field-proven corrective if missing
- **Archive path pinned** to the integration-worktree root (`git rev-parse --show-toplevel`), resolved once, stored in the checkpoint
- **Manual worker worktrees** at the exact baseline SHA preferred over SDK `isolation:"worktree"` (which forks from session HEAD); merge-base preamble check demoted to backstop
- **Reachability ⊇ init contracts**: stateful modules (managers/stores/outboxes) must have their `setUser`/`register`/`init` hook grep-verifiably invoked from the composition root, named in done-criteria
- **Wind-down lifecycle order**: finish in-flight workers, integrate passers, surface (don't retry) failures, final checkpoint with resume plan, STATE line — plus the SendMessage next-tool-round delivery-latency caveat
- Skipped-Gate-2 units register a named final-gate spot-check; the global cap explicitly counts workers + verifiers + retries

## [0.5.0] — 2026-07-21

Field-hardening release from a monitored two-wave production run (33 units, ~35 workers, 4 environmental foreman deaths, 3 ship-gate MAJORs caught, zero capability escalations).

**Why update:** crash recovery becomes deterministic (mandatory `checkpoint.json` + documented foreman resume path + STATE line), dead-code UI slips are caught at Gate 1 (reachability grep), and workers stop rediscovering worktree environment facts (standard preamble incl. base-SHA fail-fast and the phantom-failure rule).

- **Mandatory `checkpoint.json`** per run (schema in foreman.md): rewritten atomically before every dispatch round and after every integration; fixed archive layout (`dispatch-log.md`, `dispatch/`, `reports/`, `gates/`, `failures/`)
- **Foreman lifecycle section**: orchestrator-level environment failures (network/spend-limit/host-restart) with a canonical recovery path — checkpoint first, SendMessage-resume the same foreman id, fresh foreman only as last resort; explicit exception to the worker-resume prohibition
- **STATE line** ends every foreman turn (`STATE: integrated <sha> · tally <n>/<cap> · next <unit>`) — the crash breadcrumb is a rule, not luck
- **Plan-change contract**: mid-run unit injection via SendMessage requires a full dispatch-contract spec + explicit new global cap
- **Gate-1 reachability check** for UI units: every new component must be imported by a route-reachable file — typecheck, tests and verifiers all pass on dead code
- **Standard worker preamble**: verify fork base with `git merge-base --is-ancestor` (fail fast, never improvise), mechanical-gates-only in fresh worktrees with runtime checks as EXECUTION-PENDING, phantom-failure re-run rule, capped return contract
- **Foreman inline-fix policy**: allowed for env repairs/mechanical glue with Gate-1 evidence + `foreman-fix` ledger entry; security/correctness-critical code always dispatches as a unit (Gate 2)
- Tier-distribution guideline qualified per work-type (spec-heavy builds legitimately run 40–50% T2); escalation-ledger headline is now "the same context should never be missing twice"; new "Load-bearing — do not soften" list

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
