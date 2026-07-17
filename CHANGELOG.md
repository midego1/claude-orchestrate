# Changelog

All notable changes to the orchestrate plugin. The update notifier reads this file — keep the **Why update** line on every release.

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
