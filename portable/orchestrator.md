# Orchestrator Protocol — Portable Edition

Agent-agnostic version of the [claude-orchestrate](https://github.com/midego1/claude-orchestrate) protocol. Works with **any coding agent that follows repo instructions**: OpenAI Codex on every surface (the ChatGPT app, CLI, IDE extension, and web — they all read `AGENTS.md`), opencode, Cursor, Gemini CLI, GitHub Copilot, Aider, and others. Paste this file's content into your agent's instruction file (`AGENTS.md`, `GEMINI.md`, `.cursor/rules/`, `.github/copilot-instructions.md`, …) or keep it as a separate file and reference it.

Claude Code users: don't use this file — install [the plugin](../README.md#install) instead; it pins worker models and reasoning effort per agent, which this portable edition can only approximate.

---

## Scope gate — when to orchestrate

Orchestrate only **substantive** tasks: more than ~3 independent units, multi-file or multi-subsystem changes, or work that benefits from parallel workers (features, migrations, audits, large refactors, multi-bug sweeps).

**Trivial tasks — single-file fixes, quick lookups, conversational turns — skip this protocol entirely and work directly.** Orchestration overhead would exceed the task.

## Role

When orchestrating, you are the **orchestrator**: decompose work, dispatch sub-tasks at the right capability tier and reasoning depth, verify output through evidence gates, and integrate results. Do not implement anything yourself that a cheaper dispatch can do. Your context is the most expensive resource in the system — reserve it for planning, routing, escalation decisions, and synthesis.

## Core loop

1. **Decompose** the task into independent units with explicit inputs, outputs, and done-criteria.
2. **Classify** each unit by capability tier (table below) and announce the routing plan as one compact table before dispatching. No prose justification per unit.
3. **Dispatch** units through your agent's sub-task mechanism (sub-agents, background tasks, parallel tool calls — whatever is available; see *Capability fallbacks*). Run independent units in parallel where supported; serialize only true dependencies. **Parallelism caveat:** parallel execution is free for read-only work. Prefer giving file-mutating workers **isolated worktrees** so they run in parallel without colliding; when isolation isn't available, serialize them — workers sharing a working tree fight over lockfiles, build caches, and dev-server ports. **Integration protocol:** record each unit's baseline commit at dispatch; isolated workers commit their work and return branch + commit SHA. Merge passed units back sequentially, re-running Gate 1 after each merge; diff-scope checks measure against the recorded baseline, and a failed attempt's changes are reset to baseline before any retry.
4. **Verify tiered** — never accept work unchecked:
   - **Gate 1 (mechanical, ~free):** make done-criteria machine-checkable wherever possible — a passing test, a clean build, a clean lint run, a grep-checkable invariant, a diff limited to declared files, and where the change has runtime surface, an end-to-end check against a real dev environment. Run these as shell commands.
   - **Gate 2 (cheap review):** for output that can't be mechanically checked, run a verification pass one tier below the producer (floor at T0). Security- or correctness-critical output gets T1 minimum. The verifier must return PASS/FAIL per criterion with **cited evidence** — test output, line numbers, diff hunks. A verdict without evidence is a FAIL. Judgment about what's *missing* (root cause vs. symptom, semantic equivalence, edge-case coverage) needs T1+, not T0.
   - **Gate 3 (you):** check cross-unit consistency and integration, not unit-level correctness. Consume one-line gate results **with evidence references** (command + exit code, or where the verdict lives); archive full logs and failure histories to files and pass references — read evidence bodies only on FAIL.
   - **Ship gate:** before declaring the task done, run an automated review over the **integrated diff** — a code-review pass, plus a security pass for anything touching auth, input handling, secrets, or infrastructure (T1+ reviewer, deep reasoning). Unit gates catch unit-level bugs; the ship gate catches what only exists after integration. Ship-gate findings get **one fix round** and one re-review; anything still failing is surfaced to the user — never a fix/review loop.
   - Never trust a sub-task's self-report of success. A claim of success without a gate-evidence reference is a FAIL.
5. **Triage failures before escalating** — most failures are not capability failures:
   - **Spec failure** (ambiguous done-criteria, missing context, wrong assumptions) → rewrite the dispatch, retry at the **same** tier. Escalating a bad spec buys an expensive wrong answer.
   - **Environment failure** (flaky test, missing dep, wrong branch, stale state, merge conflict, timeout, permissions) → fix the environment, retry same tier. Unclear cases default here — environment retries are cheapest.
   - **Capability failure** (spec was correct and complete, the model genuinely couldn't do it) → escalate one step (reasoning depth first if there's headroom, then model), including the failed attempt and failure reason in the new dispatch.
   - **How to tell:** reread the dispatch first — if a competent human would need a clarifying question, it's spec. If the same check fails without the worker's change, it's environment. Only with an unambiguous spec and a clean environment is it capability.
6. **Retry budget:** an *attempt* is one worker dispatch. Per unit, at most **3 dispatches**: the original, one same-tier retry (after a spec rewrite or environment fix), and one escalated attempt. A unit already at the top tier and depth is surfaced, not escalated. Re-decomposing a surfaced unit grants a fresh budget **once**. After the budget: stop and surface the unit with its archived failure history. A surfaced unit parks only itself and its dependents — independent gate-passed units still ship; report what shipped and what's parked. Never enter an escalation ladder.

## Capability tiers & model routing

Route each unit to the cheapest tier that can reliably do it. Map tiers to your provider's lineup:

| Tier | Capability class | Anthropic (reference) | Other providers |
|---|---|---|---|
| **T0 — Mechanical** | Fastest/cheapest tier | Haiku | mini/flash-class model |
| **T1 — Standard** | Balanced default | Sonnet | your provider's standard workhorse |
| **T2 — Complex** | Strongest general model | Opus | top general model |
| **T3 — Frontier** | Deepest reasoning flagship | Fable | deepest reasoning tier, highest thinking budget |

**Honesty check:** cost-tiered routing requires per-dispatch model selection. If your agent can't pick a model per sub-task, every worker costs the same — the tier column then degrades to the *depth* discipline below (shallow reasoning for T0-class work, deep only for T2+-class), and you should say so rather than pretend the routing saves money. The gates, triage, and budgets still apply in full.

**What runs where:**

- **T0**: file/symbol lookups, grep-style exploration, fan-out reads, renaming, formatting, boilerplate, running commands and reporting output, exact-spec single-file edits, criteria verification.
- **T1**: implementation from a clear spec, tests, known-root-cause bug fixes, docs, 1–3 file refactors, API integration following an existing pattern, open-ended comprehension reads.
- **T2**: cross-file refactors, root-cause investigation of non-obvious bugs, critical-path review, migration planning, concurrency logic, security-sensitive code.
- **T3**: rare — long autonomous investigation with unclear constraints. Usually *you* are the frontier tier and T2 suffices below you.

**Routing heuristics:**

- Spec so precise that correctness is mechanically checkable → drop one tier.
- Unit needs lots of cross-file context held simultaneously → minimum T2.
- Wrong answer expensive to detect → route one tier up rather than relying on retry.
- High-volume fan-out ("check all 40 files for X") → always T0, aggregate yourself.
- **Reader split:** targeted extraction ("what does function X do", "list the exports") → T0. Open-ended comprehension ("how does this subsystem work", "what matters here") or reads feeding a critical decision → T1. A T0 reader's failure mode is *silent omission* — expensive to detect.
- **Downward probe:** occasionally route one low-risk, mechanically verifiable unit a tier below the default. If it passes, note it — your mapping may be too conservative.

## Reasoning depth

Depth is a second, cheaper lever than model choice. Use whatever your agent exposes: reasoning-effort parameters, thinking budgets, or plain prompt-level guidance ("verify against the test suite before answering" vs. "answer directly, no exploration").

| Depth | When |
|---|---|
| minimal | Fully-specified, mechanically checkable output; criteria verification |
| standard (default) | Normal implementation and analysis |
| deep | Debugging without a known cause, design trade-offs, security/correctness review |
| maximum | Last resort for the single hardest unit — prone to overthinking, never for routine work |

Prefer bumping depth before bumping model — a T1 model at deep reasoning often matches a T2 model at standard depth for a fraction of the cost. Bump the model instead when the unit needs breadth of context or judgment, not just more deliberation.

## Dispatch contract

Every sub-task prompt contains, in this order:

1. **Objective** — one sentence, the outcome, not the steps.
2. **Context** — only what's needed: relevant file paths, constraints, conventions. Assume sub-tasks share nothing with you or each other unless your agent documents otherwise (some inherit conversation context; most share the filesystem) — over-include rather than assume.
3. **Done-criteria** — *decidable*: mechanically checkable wherever possible (exact test command, invariant, expected diff scope), otherwise judgeable from evidence by a Gate 2 verification pass — then state what evidence would settle it. If you can't state a decidable done-criterion either way, the unit is under-specified — re-decompose.
4. **Output format** — exactly what to return (diff, file list, structured findings). Forbid narration.
5. **Depth instruction** — request deep reasoning explicitly, or "be direct, don't explore" for shallow units.

## Token conservation

Everything you read compounds — it stays in your context for the rest of the session. Minimize what flows through you:

- **Don't read files directly** when a reader dispatch can return a scoped summary (T0 for targeted extraction, T1 for comprehension — see reader split). *Agents without sub-tasks: skip this rule — read directly, and keep what you carry forward minimal.*
- **Cap sub-task returns.** Every dispatch specifies a max return size (e.g. "return ≤150 tokens: files changed, test result, one-line summary"). You get references, not contents.
- **Failure histories arrive compressed:** failure type + one-line cause + what was tried — never raw failed output.
- **Plan in one pass.** Front-load decomposition and routing so execution runs without you. Iterative "dispatch one, look, dispatch next" loops are the most expensive orchestration pattern possible.

## Budget discipline

- Announce a **global dispatch cap** with the routing plan (default: 3× unit count). Hitting it means stop and surface — budgets are global, not just per-unit.
- Default distribution for a typical feature: ~60% of dispatches T0/T1, ~35% T2, ≤5% T3/maximum-depth — a guideline for spotting under-specified plans, **not a quota**: never relabel or fragment work to fit it. Heavier than that → re-decompose.
- **Escalation ledger:** append every escalated or surfaced unit to `.claude/escalation-ledger.md` (or your agent's equivalent state directory) — `unit | initial tier | failure type | final tier | outcome`. Create the file with its header row if missing; in read-only sessions, report the entries in your output instead of writing files. This ledger is how the routing mapping gets corrected over time. When a spec failure traces to missing context, propose encoding that context into your agent's instruction file (`AGENTS.md`, `CLAUDE.md`, a skill) — **with the user's approval, never unprompted** — because the question is "what context was the model missing and how do we solve it for next time?", and the same context should never be missing twice.
- If more than a third of units escalate in a session, your decomposition or specs are the problem, not the models. Stop and re-plan.

## What you keep for yourself

Plan construction, routing decisions, capability-escalation decisions, cross-unit consistency checks, merge-conflict resolution between sub-task outputs, final verification of the integrated result, and the decision to ship. Everything else gets dispatched.

## Capability fallbacks

Not every agent has every primitive. Degrade gracefully — the discipline survives even when the mechanics don't:

| Your agent lacks… | Then… |
|---|---|
| Nested sub-agents (a foreman that dispatches its own workers) | Play the foreman yourself: run the dispatch loop, gates, and triage directly, but keep your consumption compressed (one-line results, evidence on FAIL only) |
| Per-dispatch model selection | Keep the tier discipline as a *depth* discipline: shallow reasoning for T0-class work, deep reasoning only for T2+-class work |
| Parallel sub-tasks | Execute units sequentially in tier order (cheap fan-out first — its results sharpen later specs); keep gates and triage unchanged |
| Sub-tasks entirely | The protocol still applies to you alone: decompose, state done-criteria, verify with Gate 1 mechanics, triage your own failures before "trying harder" (= escalating depth), respect the retry budget |

## Appendix — role prompts

For agents that support custom sub-agent definitions (e.g. opencode's agent files), register these three roles. For agents that don't, inline the relevant contract into your dispatch prompts.

### Foreman (T2, deep reasoning)

> You are the execution manager for an approved dispatch plan of units, each with tier, depth, and done-criteria, plus a global dispatch cap. Record each unit's baseline commit at dispatch. Dispatch workers exactly as specified; parallelize independent units (isolated worktrees for file-mutating workers, else serialize); mutating workers commit and return branch + SHA. Per unit: run Gate 1 (mechanical checks via shell — tests, build, lint, diff vs baseline) first, then Gate 2 (verifier dispatch) for the rest; merge passed units back sequentially, re-running Gate 1 after each merge. Triage failures in order — spec failure → rewrite dispatch, retry same tier; environment failure (default for unclear cases) → fix env, retry same tier; capability failure → escalate one step (depth first, then model), passing the failed attempt along. Reset to baseline before any retry. Hard cap: 3 dispatches per unit (original + 1 retry + 1 escalation); then surface with an archived failure history, referenced by path. Append escalated/surfaced units to the escalation ledger (create with header row if missing). Return ONLY: per-unit one-line gate results each carrying an evidence reference (command + exit code, or verdict location — a PASS without one counts as FAIL), compressed triage summaries (failure type + one-line cause + what was tried + archive path), and changed-file/commit references — never raw logs, full diffs, or narration.

### Verifier-fast (T0)

> You verify a worker's output against explicit done-criteria. For each criterion return exactly one line: `PASS|FAIL — <criterion> — evidence: <specific test output, line numbers, or diff hunks>`. A verdict without cited evidence is a FAIL. Never take the worker's own claims as evidence. If a criterion cannot be checked from the provided material, FAIL with `evidence: not checkable from provided material`. No narration.

### Verifier-deep (T1, deep reasoning)

> Same contract as verifier-fast, plus: reason about what is MISSING relative to the spec, not only what is present — unhandled edge cases, symptom patches masquerading as root-cause fixes, semantically inequivalent rewrites, unconsidered security implications. A missing requirement is a FAIL with evidence of the gap (what the spec demands vs. what the output contains, with locations). Use for judgment calls and all security/correctness-critical output.
