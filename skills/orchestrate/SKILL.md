---
name: orchestrate
description: >-
  Multi-agent orchestration for substantive implementation work. Use when a task
  decomposes into more than ~3 independent units, spans multiple files or
  subsystems, or benefits from parallel workers with verification gates —
  features, migrations, audits, large refactors, multi-bug sweeps. Routes each
  unit to the cheapest capable model, verifies with evidence-gated checks, and
  escalates only on genuine capability failures. Do NOT use for trivial turns,
  single-file fixes, or quick lookups — work directly instead.
---

# Orchestrator Protocol

You are the **orchestrator**. Your job is to decompose work, dispatch sub-agents with the right model and reasoning depth, verify their output, and integrate results. You do not implement anything yourself that a sub-agent can do — your own tokens are the most expensive in the system and are reserved for planning, routing, escalation decisions, and synthesis.

**Trivial-task escape hatch:** if this skill was invoked on a task that is actually trivial (single-file fix, quick lookup, conversational turn), skip this protocol entirely and work directly — orchestration overhead would exceed the task.

## Core loop

1. **Decompose** the task into independent units with explicit inputs, outputs, and done-criteria.
2. **Classify** each unit by complexity tier (below).
3. **Delegate execution to a foreman.** For any plan with more than ~3 units, hand the full dispatch plan to an **opus foreman** sub-agent that runs the loop: dispatches workers, runs gates, triages failures, manages retries within budget. You re-enter only for capability escalations past the foreman's authority, plan changes, and final integration. For small plans (≤3 units), dispatch directly yourself — you then run Gates 1 and 2 for those units too; direct mode skips the foreman, never the gates. Sub-agents run in parallel wherever units don't depend on each other; serialize only true dependencies. **Dispatch mechanics:** the foreman itself MAY run as a background agent — you spawned it, so its completion notification routes back to you. Workers and verifiers are different: whether dispatched by the foreman or by you in direct mode, they are always **synchronous** — pass `run_in_background: false` explicitly (the harness defaults to background) — and parallelism within a wave means multiple Agent calls in a single message (parallel tool use), each result returning inline as its tool result. Background worker dispatch is forbidden: a sub-agent's background children don't reliably notify it (the moment the dispatcher idles, completions escalate to the main session), and a worker can never message its dispatcher (agent handles are session-scoped). A worker's final text IS its report — dispatch prompts never instruct a worker to SendMessage or report to anyone. Retries are fresh synchronous dispatches carrying the failed attempt's report and verdict — never a SendMessage-resume of an idle worker, whose completion would route to the main session too. **Parallelism caveat:** parallel dispatch applies freely to read-only workers. Prefer giving file-mutating workers **worktree isolation** (the Task tool's worktree option) so they run in parallel without colliding; when isolation isn't available, serialize them — workers sharing a working tree fight over lockfiles, build caches, and dev-server ports. **Integration protocol:** record each unit's baseline commit at dispatch; isolated workers commit their work and return branch + commit SHA, not just file paths. Passed units are merged back sequentially, re-running Gate 1 after each merge; merge conflicts come to you (semantic conflict resolution is yours). Diff-scope checks measure against the recorded baseline, and a failed attempt's changes are reset to baseline before any retry — no contamination between attempts.
4. **Verify tiered** — never read raw sub-agent output yourself as the first check:
   - **Gate 1 (mechanical, ~free):** done-criteria must be machine-checkable wherever possible — a passing test, a clean build, a clean lint run, a grep-checkable invariant, a diff limited to declared files, and where the change has runtime surface, an end-to-end check against a real dev environment. Run these as bash commands.
   - **Gate 2 (cheap review):** for output that can't be mechanically checked, dispatch a verifier **one tier below the producer, floor at haiku** (sonnet output → haiku verifier, opus output → sonnet verifier). Security- or correctness-critical output gets sonnet minimum regardless of producer. The verifier must return PASS/FAIL with **cited evidence** — specific test output, line numbers, or diff hunks proving each criterion. A verdict without evidence is a FAIL. Haiku verifies comparison-against-criteria; anything requiring judgment about what's *missing* (root cause vs. symptom, semantic equivalence, edge-case coverage) goes to sonnet.
   - **Gate 3 (you):** only gate-passed, foreman-summarized output reaches you. You check cross-unit consistency and integration, not unit-level correctness. Gate results arrive as one line each **with an evidence reference** — the exact command run + exit code, or where the verifier verdict lives. Full logs and failure histories go to the run archive (layout and checkpoint contract below), referenced by path: auditable on demand without flowing through your context. Evidence bodies are attached only on FAIL.
   - **Ship gate:** before declaring the task done, run an automated review over the **integrated diff** — a code-review pass, plus a security review for anything touching auth, input handling, secrets, or infrastructure (use the host's review skills if available, e.g. `/code-review`; otherwise dispatch a T2 reviewer). Unit gates catch unit-level bugs; the ship gate catches what only exists after integration. Ship-gate findings get **one fix round** (dispatched as fresh units) and one re-review; anything still failing is surfaced to the user — never a fix/review loop.
   - Never trust a sub-agent's self-report of success. A claim of success without a gate-evidence reference is a FAIL — and this applies to foreman summaries too: a PASS line without its evidence reference is a FAIL.
5. **Triage failures before escalating** — most failures are not capability failures:
   - **Spec failure** (ambiguous done-criteria, missing context, wrong assumptions in the dispatch) → rewrite the dispatch, retry at the **same** tier. Escalating a bad spec buys an expensive wrong answer.
   - **Environment failure** (flaky test, missing dep, wrong branch, stale state) → fix the environment, retry same tier.
   - **Capability failure** (spec was correct and complete, model genuinely couldn't do it) → escalate, including the failed attempt and the failure reason in the new dispatch.
   - **How to tell:** reread the dispatch first — if a competent human would need a clarifying question, it's a spec failure. If the same check fails without the worker's change (flaky test, missing dep, merge conflict, timeout, permissions), it's an environment failure — unclear cases default here, since environment retries are cheapest. Only when the spec was unambiguous and the environment clean is it a capability failure.
6. **Retry budget:** an *attempt* is one worker dispatch. Per unit, at most **3 dispatches**: the original, one same-tier retry (after a spec rewrite or environment fix), and one escalated attempt. An **escalation step** is a single bump — effort first if the model has headroom, otherwise the next model tier; a unit already at T3/max has nowhere to go and is surfaced instead. Re-decomposing a surfaced unit grants a fresh budget **once**; units descended from an already re-decomposed unit are surfaced, not retried. After the budget: stop and surface the unit to the user with the archive path to its full failure history. A surfaced unit parks only itself and units that depend on it — independent gate-passed units still ship; report clearly what shipped and what's parked. Never enter an escalation ladder.

## Run archive and checkpoint

Every run gets an archive at `.claude/orchestrate-runs/<run>/` with exactly this layout — no variants, no empty scaffolding:

- `checkpoint.json` — machine-readable run state, the recovery source of truth. Created before the first dispatch.
- `dispatch-log.md` — human-readable narrative of the run, in order. Narrative only — never the recovery source.
- `dispatch/` — every worker prompt as sent, written at dispatch time.
- `reports/` — every worker return, written on return.
- `gates/` — Gate 1 command output and Gate 2 verdicts, written when the gate runs.
- `failures/` — full failure histories for retried, escalated, and surfaced units, written at triage.

**Checkpoint contract — REQUIRED.** `checkpoint.json` holds:

```json
{
  "runId": "…",
  "integrationBranch": "…",
  "baselineSha": "…",
  "lastIntegratedSha": "…",
  "dispatchTally": { "used": 0, "cap": 0 },
  "units": [
    { "id": "…", "status": "pending|in-flight|integrated|failed|surfaced", "sha": "…", "evidenceRef": "…" }
  ],
  "nextAction": "…"
}
```

(`sha` and `evidenceRef` are optional per unit.) Write discipline: the foreman rewrites the whole file atomically **before dispatching each round** and **after each integration**. Checkpoint-before-dispatch is as mandatory as the gates — a foreman turn that dispatches with a stale checkpoint is a protocol violation. When a process dies, recovery reads `checkpoint.json` first and the integration branch's git log second; the narrative log is for humans.

## Model routing

Pick the cheapest model that can reliably do the unit. Route per dispatch via the Task tool's `model` parameter.

| Tier | Model | Use for |
|---|---|---|
| T0 — Mechanical | `haiku` | File/symbol lookups, grep-style exploration, reading and summarizing files, renaming, formatting, boilerplate, running commands and reporting output, simple single-file edits with an exact spec, **Gate 2 verification of criteria-checkable output** |
| T1 — Standard | `sonnet` | Feature implementation from a clear spec, writing tests, bug fixes with a known root cause, docs, refactors scoped to 1–3 files, API integration following an existing pattern |
| T2 — Complex | `opus` | Multi-file refactors needing cross-file context, root-cause investigation of non-obvious bugs, code review of critical paths, migration planning, concurrency/state-machine logic, security-sensitive code |
| T3 — Frontier | `fable` | Only for units where the sub-agent itself must sustain long autonomous investigation with verification (large ambiguous debugging, architecture decisions with unclear constraints). Rare — usually YOU are the frontier-tier reasoning and T2 suffices below you |

**Routing heuristics:**
- If you can write the spec so precisely that correctness is checkable mechanically → drop one tier.
- If the unit requires holding lots of cross-file context simultaneously → minimum T2.
- If the unit is on the critical path and a wrong answer is expensive to detect → route one tier up rather than relying on retry.
- High-volume fan-out (e.g. "check all 40 files for X") → always T0, aggregate yourself.
- **Reader split:** targeted extraction and fan-out reads ("what does function X do", "list the exports", "find where Y is called") → haiku. Open-ended comprehension or synthesis reads ("how does this subsystem work", "what matters here"), or reads feeding a critical routing/planning decision → sonnet. Haiku's failure mode as a reader is *silent omission* — expensive to detect. If you can phrase the question precisely enough that the answer is checkable, it's a haiku read.
- **Downward probe:** occasionally route one low-risk, mechanically verifiable unit a tier below the table's default. If it passes, note it — the table may have drifted too conservative.

## Reasoning depth (effort / thinking)

Effort levels: `low` → `medium` → `high` → `xhigh` → `max`. Haiku does not support effort — for T0 the model choice IS the depth control.

**Mechanics — three levers, in order of preference:**
1. **Subagent frontmatter `effort`** — for predefined agents, set `effort:` in the frontmatter. Maintain variants where it pays off (e.g. `reviewer-fast` at `medium`, `reviewer-deep` at `xhigh`).
2. **`ultrathink` keyword** — for ad-hoc Task dispatches where you can't set effort per invocation, include the word `ultrathink` in the sub-agent's prompt to request deeper reasoning on that unit.
3. **Prompt-level guidance** — tell the sub-agent explicitly how much to deliberate ("verify against the test suite before answering" vs. "answer directly, no exploration").

**Depth routing:**

| Depth | When |
|---|---|
| low | Latency-sensitive, fully-specified, mechanically checkable output; Gate 2 verification passes |
| medium | Cost-sensitive standard work where a rare miss is cheap to catch |
| high (default) | Normal implementation and analysis — leave it here unless you have a reason |
| xhigh | Debugging without a known cause, design trade-offs, review of security/correctness-critical code |
| max | Last resort for the single hardest unit. Prone to overthinking — never use for routine work, never for more than one concurrent dispatch |

**Model × depth interaction:** prefer bumping effort before bumping model — Sonnet at xhigh often matches Opus at high for a fraction of the cost. Bump the model instead when the unit needs breadth of context or judgment, not just more deliberation.

## Dispatch contract

Every sub-agent prompt must contain, in this order:
1. **Objective** — one sentence, the outcome, not the steps.
2. **Context** — only what's needed: relevant file paths, constraints, conventions. Sub-agents share nothing with you or each other; over-include rather than assume.
3. **Done-criteria** — *decidable*: mechanically checkable wherever possible (exact test command, invariant, expected diff scope), otherwise judgeable from evidence by a Gate 2 verifier — then state what evidence would settle it. If you can't state a decidable done-criterion either way, the unit is under-specified — re-decompose.
4. **Output format** — exactly what to return (diff, file list, structured findings). Forbid narration. The sub-agent's **final text is its report** — never instruct it to SendMessage, notify, or report to any agent; it can't reach its dispatcher anyway (agent handles are session-scoped).
5. **Depth instruction** — `ultrathink` if xhigh-equivalent reasoning is needed, or explicit "be direct, don't explore" for low-depth units.

## Orchestrator token conservation

Your tokens are the most expensive in the system, and everything you read compounds — it stays in your context and is re-processed every subsequent turn. Minimize what flows through you:

- **Never read files directly.** Dispatch a reader that returns a summary scoped to what you actually need — haiku for targeted extraction, sonnet for open-ended comprehension (see the reader split above).
- **Cap sub-agent returns.** Every dispatch specifies a max return size (e.g. "return ≤150 tokens: files changed, test result, one-line summary"). Full diffs and logs stay with the foreman; you get references, not contents.
- **Failure histories arrive compressed.** The foreman's triage summary (failure type + one-line cause + what was tried) is what you read — never raw failed output.
- **Plan in one pass.** Front-load decomposition and routing so execution runs without you. Iterative "dispatch one, look, dispatch next" loops through your context are the most expensive orchestration pattern possible.
- **Foreman authority:** the foreman resolves spec and environment failures autonomously and owns the full retry budget. Only capability escalations to T2+ and plan-invalidating discoveries come back to you.

## Budget discipline

- Announce the routing plan (units → model/depth) before dispatching, in one compact table — including a **global dispatch cap** (default: 3× unit count). Hitting the global cap means stop and surface, exactly like a per-unit budget: budgets are global, not just per-unit.
- Default distribution for a typical feature: ~60% of dispatches T0/T1, ~35% T2, ≤5% T3/max — a guideline for spotting under-specified plans, **not a quota**: never relabel or fragment genuinely complex work to fit it. If your plan is heavier, re-decompose.
- **Escalation ledger:** at session end, append every escalated or surfaced unit to `.claude/escalation-ledger.md` — unit description, initial tier, failure type (spec/env/capability), final tier, outcome. Create the file with its header row if it doesn't exist. This ledger is how the routing table gets corrected over time. When a spec failure traces to **missing context**, don't just log it — encode that context into `CLAUDE.md` or the relevant skill, so the question shifts from "did the model read the code?" to "what context was the model missing and how do we solve it for next time?" The same context should never be missing twice.
- If more than a third of units escalate in a session, your decomposition or specs are the problem, not the models. Stop and re-plan.

## What you keep for yourself

Plan construction, routing decisions, capability-escalation decisions, cross-unit consistency checks, merge-conflict resolution between sub-agent outputs, final verification of the integrated result, and the decision to ship. Failure triage and unit-level verification belong to the foreman and the gates. Everything else gets dispatched.
