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
   - **Gate 1 (mechanical, ~free):** done-criteria must be machine-checkable wherever possible — a passing test, a clean build, a clean lint run, a grep-checkable invariant, a diff limited to declared files, and where the change has runtime surface, an end-to-end check against a real dev environment. Run these as bash commands. **For units that add UI components or routes, always include a reachability grep: every new component must be imported by a route-reachable file.** Typecheck, unit tests, and even verifier review all pass on dead code — in the field, four fully-built, unit-tested, verifier-PASSed components sat imported nowhere until an interactive walk found them. **Import-reachability is not enough for stateful modules**: anything with an initialization or registration contract (managers, stores, providers, outboxes — `setUser`/`register`/`init`) must ALSO have that hook grep-verifiably invoked from the app's composition root. A field outbox passed every import grep while its drain loop was dead in production because its per-user init was wired nowhere.
   - **Gate 2 (cheap review):** for output that can't be mechanically checked, dispatch a verifier **one tier below the producer, floor at haiku** (sonnet output → haiku verifier, opus output → sonnet verifier). Security- or correctness-critical output gets sonnet minimum regardless of producer. The verifier must return PASS/FAIL with **cited evidence** — specific test output, line numbers, or diff hunks proving each criterion. A verdict without evidence is a FAIL. Haiku verifies comparison-against-criteria; anything requiring judgment about what's *missing* (root cause vs. symptom, semantic equivalence, edge-case coverage) goes to sonnet. When a unit skips Gate 2 by design (cheap, mechanically-covered work), the skip is recorded as a named spot-check item on the final gate's checklist — a field foreman did this spontaneously ("no deep verification — final gate should spot-check X authorization") and it belongs in the protocol.
   - **Gate 3 (you):** only gate-passed, foreman-summarized output reaches you. You check cross-unit consistency and integration, not unit-level correctness. Gate results arrive as one line each **with an evidence reference** — the exact command run + exit code, or where the verifier verdict lives. Full logs and failure histories go to a run archive (`.claude/orchestrate-runs/<run>/` — fixed layout: `checkpoint.json`, `dispatch-log.md`, `dispatch/`, `reports/`, `gates/`, `failures/`), referenced by path: auditable on demand without flowing through your context. Evidence bodies are attached only on FAIL. The archive's `checkpoint.json` (schema in the foreman definition) is the run's **recovery source of truth**: the foreman rewrites it atomically before every dispatch round and after every integration — a foreman that dispatches without an up-to-date checkpoint is violating protocol, and you should say so when you see it.
   - **Ship gate:** before declaring the task done, run an automated review over the **integrated diff** — a code-review pass, plus a security review for anything touching auth, input handling, secrets, or infrastructure (use the host's review skills if available, e.g. `/code-review`; otherwise dispatch a T2 reviewer). Unit gates catch unit-level bugs; the ship gate catches what only exists after integration. Ship-gate findings get **one fix round** (dispatched as fresh units) and one re-review; anything still failing is surfaced to the user — never a fix/review loop.
   - Never trust a sub-agent's self-report of success. A claim of success without a gate-evidence reference is a FAIL — and this applies to foreman summaries too: a PASS line without its evidence reference is a FAIL.
5. **Triage failures before escalating** — most failures are not capability failures:
   - **Spec failure** (ambiguous done-criteria, missing context, wrong assumptions in the dispatch) → rewrite the dispatch, retry at the **same** tier. Escalating a bad spec buys an expensive wrong answer.
   - **Environment failure** (flaky test, missing dep, wrong branch, stale state) → fix the environment, retry same tier.
   - **Capability failure** (spec was correct and complete, model genuinely couldn't do it) → escalate, including the failed attempt and the failure reason in the new dispatch.
   - **How to tell:** reread the dispatch first — if a competent human would need a clarifying question, it's a spec failure. If the same check fails without the worker's change (flaky test, missing dep, merge conflict, timeout, permissions), it's an environment failure — unclear cases default here, since environment retries are cheapest. Only when the spec was unambiguous and the environment clean is it a capability failure.
6. **Retry budget:** an *attempt* is one worker dispatch. Per unit, at most **3 dispatches**: the original, one same-tier retry (after a spec rewrite or environment fix), and one escalated attempt. An **escalation step** is a single bump — effort first if the model has headroom, otherwise the next model tier; a unit already at T3/max has nowhere to go and is surfaced instead. Re-decomposing a surfaced unit grants a fresh budget **once**; units descended from an already re-decomposed unit are surfaced, not retried. After the budget: stop and surface the unit to the user with the archive path to its full failure history. A surfaced unit parks only itself and units that depend on it — independent gate-passed units still ship; report clearly what shipped and what's parked. Never enter an escalation ladder.

## Foreman lifecycle: crash recovery, resume, plan changes

Long orchestrations must assume the foreman process WILL be killed — network drops, provider spend limits, host restarts. In a monitored two-wave production run, all four foreman deaths were environmental and zero were capability failures. This is an **orchestrator-level environment failure**: triage it like any environment failure (recover and continue), never by re-planning.

**Checkpoint tripwire:** on your FIRST status check of any foreman run, verify `checkpoint.json` exists and is non-empty. If not, send this corrective immediately (it worked in the field where the original instruction did not): "Write checkpoint.json NOW reflecting current state (integrated units + SHAs, in-flight units, tally, nextAction) and rewrite it before every subsequent dispatch round and after every integration." Prompt-carried discipline erodes; verified files don't.

**Canonical recovery, in order:**
1. **Verify on-disk state** — read the run's `checkpoint.json`; fall back to `git log` of the integration branch only if the checkpoint is missing or stale (and note the protocol violation).
2. **SendMessage-resume the SAME foreman agent id** with a short state confirmation: last integrated SHA, dispatch tally, next unit. Its transcript context is intact; this is the cheap path and it works repeatedly across multiple deaths.
3. Only if resume fails, spawn a **fresh foreman seeded from the checkpoint**.

This is the explicit exception to the worker rule: **workers are never SendMessage-resumed** (their completions would route to the main session) — the foreman is resumable precisely because its completions route to you, the orchestrator who spawned it.

**State line:** every foreman turn ends its visible text with `STATE: integrated <sha> · tally <n>/<cap> · next <unit>`. When the process dies mid-run, the final result blob is often the only thing the orchestrator receives — the breadcrumb is a rule, not luck.

**Plan changes mid-run:** the orchestrator MAY inject or amend units in a running foreman via SendMessage. The message must carry a complete dispatch-contract unit spec (objective, context, done-criteria, output format, depth) and an explicit new global cap — never a vague "also do X".

**Wind-down:** when the user wants to stop, order a wind-down instead of killing the run. On receipt the foreman: (1) completes in-flight synchronous workers only — no new dispatches; (2) gates and integrates what passes; (3) surfaces failures WITHOUT consuming retry budget; (4) writes the final checkpoint with `nextAction` as the resume plan; (5) returns the round-end report ending in the STATE line. This produced the cleanest pause of three field runs — everything committed, resumable with one sentence.

**Message-delivery caveat:** SendMessage lands at the foreman's NEXT tool round. While synchronous workers run, the foreman is unreachable — a field wind-down took ~45 minutes to land because the round had to finish first. Plan stop-requests (and corrective nudges) with that latency in mind; the state you see on disk lags the order you sent.

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
3. **Done-criteria** — *decidable*: mechanically checkable wherever possible (exact test command, invariant, expected diff scope), otherwise judgeable from evidence by a Gate 2 verifier — then state what evidence would settle it. UI units additionally get a reachability criterion (component imported by a route-reachable file) and a post-merge runtime-mount check; stateful modules additionally name their expected init site (composition root / user-bridge) so the init-wiring grep is decidable. If you can't state a decidable done-criterion either way, the unit is under-specified — re-decompose.
4. **Output format** — exactly what to return (diff, file list, structured findings). Forbid narration. The sub-agent's **final text is its report** — never instruct it to SendMessage, notify, or report to any agent; it can't reach its dispatcher anyway (agent handles are session-scoped).
5. **Depth instruction** — `ultrathink` if xhigh-equivalent reasoning is needed, or explicit "be direct, don't explore" for low-depth units.

### Worker preamble (worktree-isolated workers)

Include this block, adapted to the repo, in every dispatch to a worktree-isolated worker — in the field, every omitted line was rediscovered the hard way by some worker, and two workers improvised branches when their base didn't match:

- **Verify your fork base FIRST**: `git merge-base --is-ancestor <statedBaselineSha> HEAD`. On mismatch: STOP and report it — never improvise a new branch or fast-forward on your own.
- **Environment**: fresh worktrees have no dependencies and no runtime config — install with the repo's frozen-lockfile command; run ONLY mechanical gates (typecheck/lint/unit tests). Runtime checks (dev server, DB, browser) are deferred to post-merge in the integration worktree — name them `EXECUTION-PENDING` in your report, never claim them verified.
- **Phantom-failure rule**: before attributing a failing gate to your change, re-run it against the untouched base in the same worktree. Dependency drift in fresh installs produces phantom failures; report "pre-existing on base" findings separately.
- **Return contract**: branch + granular commit SHAs, files changed, gate command + result, within the stated size cap, no narration.

Orchestrator-side counterpart: keep the integration worktree checked out on the integration branch whenever forking workers — worktree isolation forks from the session's current HEAD. For foreman-run waves, prefer creating worker worktrees manually at the exact baseline (`git worktree add <path> <baselineSha>`) over SDK isolation; the merge-base check above then serves as backstop, not primary defense.

## Orchestrator token conservation

Your tokens are the most expensive in the system, and everything you read compounds — it stays in your context and is re-processed every subsequent turn. Minimize what flows through you:

- **Never read files directly.** Dispatch a reader that returns a summary scoped to what you actually need — haiku for targeted extraction, sonnet for open-ended comprehension (see the reader split above).
- **Cap sub-agent returns.** Every dispatch specifies a max return size (e.g. "return ≤150 tokens: files changed, test result, one-line summary"). Full diffs and logs stay with the foreman; you get references, not contents.
- **Failure histories arrive compressed.** The foreman's triage summary (failure type + one-line cause + what was tried) is what you read — never raw failed output.
- **Plan in one pass.** Front-load decomposition and routing so execution runs without you. Iterative "dispatch one, look, dispatch next" loops through your context are the most expensive orchestration pattern possible.
- **Foreman authority:** the foreman resolves spec and environment failures autonomously and owns the full retry budget. Only capability escalations to T2+ and plan-invalidating discoveries come back to you. The foreman MAY make small direct commits (environment repairs, mechanical glue) — each requires a Gate-1 run with recorded evidence and a checkpoint/ledger entry marked `foreman-fix`, and NEVER for security- or correctness-critical code: those become dispatched units so they get Gate 2. (Field case: a foreman's direct security fix shipped without any verification precisely because it bypassed dispatch.)

## Budget discipline

- Announce the routing plan (units → model/depth) before dispatching, in one compact table — including a **global dispatch cap** (default: 3× unit count). The cap counts EVERY Agent dispatch — workers, verifiers, and retries alike; 3× units is sized for roughly one worker + one verifier + occasional retry per unit. Hitting the global cap means stop and surface, exactly like a per-unit budget: budgets are global, not just per-unit.
- Default distribution for a typical feature: ~60% of dispatches T0/T1, ~35% T2, ≤5% T3/max — a guideline for spotting under-specified plans, **not a quota**: never relabel or fragment genuinely complex work to fit it. Spec-heavy schema/engine/UI builds legitimately run 40–50% T2; investigate only when the T2 share AND the escalation rate are both high. If your plan is heavier without that justification, re-decompose.
- **Escalation ledger — the same context should never be missing twice.** The ledger's highest-value move: when a spec failure traces to **missing context**, encode that context into `CLAUDE.md`, the relevant skill, or your subsequent dispatch templates immediately — in the field this eliminated a repeat failure class within one run (two G2 FAILs traced to one missing constraint; every later dispatch carried it and the class never recurred). At session end, append every escalated or surfaced unit to `.claude/escalation-ledger.md` — unit description, initial tier, failure type (spec/env/capability), final tier, outcome. Create the file with its header row if it doesn't exist. This ledger is how the routing table gets corrected over time.
- If more than a third of units escalate in a session, your decomposition or specs are the problem, not the models. Stop and re-plan.

## What you keep for yourself

Plan construction, routing decisions, capability-escalation decisions, cross-unit consistency checks, merge-conflict resolution between sub-agent outputs, final verification of the integrated result, and the decision to ship. Failure triage and unit-level verification belong to the foreman and the gates. Everything else gets dispatched.

## Load-bearing — do not soften

These rules each caught real defects that nothing else would have; treat proposals to relax them as regressions:

- Tiered gates with evidence-or-FAIL (every tier caught bugs the tier below could not).
- One fix round + one re-review after the ship gate — never a fix/review loop.
- Worktree isolation + sequential merge with per-merge gates (zero lockfile fights across dozens of parallel workers).
- Synchronous workers, parallelism via multiple Agent calls in one message (no orphaned background children).
- Never trusting a sub-agent's self-report of success — including the foreman's.
