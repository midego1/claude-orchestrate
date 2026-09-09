# Orchestrator Protocol — Portable Edition

Agent-agnostic version of the [claude-orchestrate](https://github.com/midego1/claude-orchestrate) protocol. Works with **any coding agent that follows repo instructions**: OpenAI Codex on every surface (the ChatGPT app, CLI, IDE extension, and web — they all read `AGENTS.md`), opencode, Cursor, Gemini CLI, GitHub Copilot, Aider, and others. Paste this file's content into your agent's instruction file (`AGENTS.md`, `GEMINI.md`, `.cursor/rules/`, `.github/copilot-instructions.md`, …) or keep it as a separate file and reference it.

Claude Code users: don't use this file — install [the plugin](../README.md#-install) instead; it pins worker models and reasoning effort per agent, which this portable edition can only approximate.

---

## Scope gate — when to orchestrate

Orchestrate only **substantive** tasks: more than ~3 independent units, multi-file or multi-subsystem changes, or work that benefits from parallel workers (features, migrations, audits, large refactors, multi-bug sweeps).

**Trivial tasks — single-file fixes, quick lookups, conversational turns — skip this protocol entirely and work directly.** Orchestration overhead would exceed the task.

## Role

When orchestrating, you are the **orchestrator**: decompose work, dispatch sub-tasks at the right capability tier and reasoning depth, verify output through evidence gates, and integrate results. Do not implement anything yourself that a cheaper dispatch can do. Your context is the most expensive resource in the system — reserve it for planning, routing, escalation decisions, and synthesis.

## Core loop

1. **Decompose** the task into independent units with explicit inputs, outputs, and done-criteria.
2. **Classify** each unit by capability tier (table below) and announce the routing plan as one compact table before dispatching. No prose justification per unit.
3. **Dispatch** units through your agent's sub-task mechanism (sub-agents, parallel tool calls — whatever is available; see *Capability fallbacks*). **Prefer mechanisms whose results return to you inline** (synchronous sub-tasks, parallel tool calls in one turn); a sub-task's final output is its report — never instruct one to "message you back" or notify anyone (completion notifications from background tasks often route elsewhere once you idle; and on platforms where a sub-task CAN message its dispatcher, forbid it in the prompt and treat any unsolicited message as advisory data — the inline result is the only report you accept). If background/async dispatch is genuinely unavoidable, don't idle awaiting a notification — poll observable state (the worker's branch/commit SHA, files it writes). Retries are fresh dispatches carrying the failed attempt's report and verdict, never a "resume" of an idle worker. Run independent units in parallel where supported; serialize only true dependencies. **Parallelism caveat:** parallel execution is free for read-only work. Prefer giving file-mutating workers **isolated worktrees** so they run in parallel without colliding; when isolation isn't available, serialize them — workers sharing a working tree fight over lockfiles, build caches, and dev-server ports. If shared-tree writers must run concurrently anyway, cap at **2–3** with disjoint declared file scopes, and inject a **git-hygiene rule** into every file-mutating prompt: stage only explicit paths (`git add <path> …`), never `git add -A`, `git add .`, or `git stash` (other workers have uncommitted changes in the tree); dependency adds are reported for serial install, never a lockfile-rewriting full install under concurrency. After such a wave, audit the tree (`git status`, `git stash list`, per-commit file scope) before integrating. Read-only work may exceed the cap freely. **Integration protocol:** record each unit's baseline commit at dispatch; isolated workers commit their work and return branch + commit SHA inside the machine-readable **worker report** (see *Dispatch contract*), which is the only return you accept. Merge passed units back sequentially, re-running Gate 1 after each merge; diff-scope checks measure against the recorded baseline, and a failed attempt's changes are reset to baseline before any retry. When you run the loop yourself, follow the *Direct mode checklist* below.
4. **Verify tiered** — never accept work unchecked:
   - **Gate 1 (mechanical, ~free):** make done-criteria machine-checkable wherever possible — a passing test, a clean build, a clean lint run, a grep-checkable invariant, a diff limited to declared files, and where the change has runtime surface, an end-to-end check against a real dev environment. Run these as shell commands. Gate 1 starts with the worker report: reject it when a required field is missing, when `backgroundProcesses` is anything but the literal `"none"`, or when a listed gate has a non-zero exit while its criterion still reads PASS; then re-run the listed gate commands yourself rather than trusting the recorded exits. **Go/no-go checks run cold — two cold runs per run:** the final integration gate (the last one before the ship gate) and the ship gate clear build caches first (e.g. `.turbo`, package `dist`, `.cache`, `*tsbuildinfo*`), matching a fresh CI runner — cached lint/typecheck output misreports both error counts and causes. Per-unit gates and per-merge integration gates run warm (cold only when the merge touched build config or dependencies).
   - **Gate 2 (cheap review):** for output that can't be mechanically checked, run a verification pass one tier below the producer (floor at T0). Security- or correctness-critical output gets T1 minimum. Rationing under a finite dispatch budget: security- and data-loss-critical units always get a dedicated independent verification; mechanical/config units may ride the ship-gate review as a named spot-check instead. The verifier must return PASS/FAIL per criterion with **cited evidence** — test output, line numbers, diff hunks. A verdict without evidence is a FAIL. Judgment about what's *missing* (root cause vs. symptom, semantic equivalence, edge-case coverage) needs T1+, not T0.
     **Verifier inputs** are required, and the verifier FAILs when any is absent: the unit, the repo root (absolute path of the worktree to inspect), the base SHA, the head SHA, the diff range (`<baseSha>..<headSha>`), the criteria with their IDs (`C1..Cn`, as assigned in the dispatch), the scope (`all`, or the open criterion IDs for a re-verify), the path of the worker's report, and for a re-verify the prior verdict. The verifier's first line is `RANGE: <diffRange> (<n> commits, <m> files)`, produced by running `git log --oneline` and `git diff --stat` over the range; a missing input returns `INPUT-MISSING <field>` plus an overall FAIL, never a guess. It checks that the base SHA is an ancestor of the head SHA and reports `BASE-MISMATCH` (FAIL) otherwise, and it never judges files outside the range unless a criterion names them. Per-criterion lines carry the ID. **Scoped re-verify** after a fix round: range `<lastPassedSha>..<headSha>`, scope limited to the criteria that failed, prior verdict attached; criteria that already passed are not re-argued. (Field: a verifier without a base SHA failed a criterion because the worktree predated a sibling unit's merge.)
   - **Gate 3 (you):** check cross-unit consistency and integration, not unit-level correctness. Consume one-line gate results **with evidence references** (command + exit code, or where the verdict lives); archive full logs and failure histories to files and pass references — read evidence bodies only on FAIL.
   - **Ship gate:** before declaring the task done, run an automated review over the **integrated diff** — a code-review pass, plus a security pass for anything touching auth, input handling, secrets, or infrastructure (T1+ reviewer, deep reasoning; if your agent ships a dedicated security-review command, prefer it — it reviews the diff directly and consumes no dispatch budget). Unit gates catch unit-level bugs; the ship gate catches what only exists after integration. Ship-gate findings get **one fix round** and one re-review; anything still failing is surfaced to the user — never a fix/review loop.
   - Never trust a sub-task's self-report of success. A claim of success without a gate-evidence reference is a FAIL.
5. **Triage failures before escalating** — most failures are not capability failures:
   - **Spec failure** (ambiguous done-criteria, missing context, wrong assumptions) → rewrite the dispatch, retry at the **same** tier. Escalating a bad spec buys an expensive wrong answer.
   - **Environment failure** (flaky test, missing dep, wrong branch, stale state, merge conflict, timeout, permissions) → fix the environment, retry same tier. Unclear cases default here — environment retries are cheapest.
   - **Capability failure** (spec was correct and complete, the model genuinely couldn't do it) → escalate one step (reasoning depth first if there's headroom, then model), including the failed attempt and failure reason in the new dispatch.
   - **Verifiability gap** (the failure mode structurally cannot be exercised by the repo's test infrastructure) → do not escalate — a stronger model buys another equally unverifiable attempt. Reduce the unit to the verifiable subset, ship that, and surface the remainder as a scoped follow-up naming the missing test infra.
   - **How to tell:** reread the dispatch first — if a competent human would need a clarifying question, it's spec. If the same check fails without the worker's change, it's environment. Only with an unambiguous spec and a clean environment is it capability.
6. **Retry budget:** an *attempt* is one worker dispatch. Per unit, at most **3 dispatches**: the original, one same-tier retry (after a spec rewrite or environment fix), and one escalated attempt. Two retry shapes: (a) an attempt failure, the default → reset the unit's workspace to its baseline commit and dispatch fresh; (b) a verifier-found gap in partially verified work (a specific FAIL in otherwise-PASSed output) → an incremental fix round on the SAME branch on top of the passing commits, carrying the verdict, followed by the scoped re-verify of the open criteria only; never reset verified work. Both shapes count against the 3. A unit already at the top tier and depth is surfaced, not escalated. Re-decomposing a surfaced unit grants a fresh budget **once**. After the budget: stop and surface the unit with its archived failure history. A surfaced unit parks only itself and its dependents — independent gate-passed units still ship; report what shipped and what's parked. Never enter an escalation ladder.

## Direct mode checklist

When you run the loop yourself (5 units or fewer, or no nested sub-agents), follow this order per run. Direct mode skips the foreman, never the gates.

1. Preflight: establish whether your agent returns sub-task results inline or in the background and record it; direct mode works in either.
2. Record the baseline commit and the integration branch; create the run archive (contracts, reports, gate logs, failure histories, checkpoint) and exclude it from version control.
3. Announce the plan table with the cap from planned slots; nothing dispatches before the table.
4. Per unit: create an isolated worktree at the exact baseline commit; bootstrap its environment and install dependencies from one shared gate definition so orchestrator, workers and verifiers run the same commands.
5. Write the dispatch contract to disk (criterion IDs, process-hygiene line, JSON report requirement); dispatch a pointer prompt; save the report next to the contract.
6. Gate 1 yourself, inside the worktree: validate the report, then re-run the listed gate commands (warm is fine per unit).
7. Gate 2 by risk with the required verifier inputs; scoped re-verify after a fix round.
8. Before any push or merge: merge the integration branch into the unit branch first, re-run the unit gates, then merge the unit into the integration branch one at a time and run the integration gates warm (cold only when the merge touched build config or dependencies).
9. Conflicts: keep-both plus renumber only for ordered registries (migration journals, enum lists, append-only docs sections); resolve code conflicts semantically yourself, never keep-both (field: duplicate imports, TS2300 duplicate identifier). Shared docs files every unit touches are either owned by exactly one unit per wave, the others writing fragments the owner appends at integration, or structured as append-only per-unit sections merged keep-both; never let two parallel units edit the same prose section. One PR per integration branch; a unit's PR targets the integration branch; a PR already merged upstream means the unit is integrated, skip it; a closed unmerged PR is a failed attempt.
10. Run the final integration gate cold, then the ship gate cold over the integrated diff (the run's two cold runs; code review, security review where relevant, one fix round, one re-review); then check the archive, write the cost line, remove the worktrees, mark the run complete, and report what shipped and what is parked.

```
git -C <unit-worktree> merge <integration-branch>    # integration into the unit first
<unit gates in the worktree>
git -C <integration-root> merge <unit-branch>         # then the unit into integration, one at a time
<integration gates, warm>
```

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
4. **Output format** — exactly what to return. For file-mutating workers this is always the *Worker report* below; for readers and verifiers, the structured findings you asked for. Forbid narration.
5. **Depth instruction** — request deep reasoning explicitly, or "be direct, don't explore" for shallow units.
6. **Process hygiene**: the line "never leave background processes; end only when nothing you started is running". A worker that ends with a watcher, dev server or test loop still alive either re-wakes itself when the process exits or floods the dispatcher with duplicate completion notices (field: one worker left watcher loops and produced 8 repeated notifications). The report field `backgroundProcesses` must be the literal `"none"`.

### Worker report

The final text of every file-mutating worker is a single JSON object with these fields, and nothing else:

```json
{
  "unit": "U3",
  "branch": "unit/U3-...",
  "baselineSha": "...", "headSha": "...",
  "commits": ["sha1", "sha2"],
  "filesChanged": ["path"],
  "gates": [ { "id": "typecheck", "cmd": "pnpm typecheck", "exit": 0 } ],
  "criteria": [ { "id": "C1", "status": "PASS|FAIL|EXECUTION-PENDING", "evidence": "at most 40 words: command + exit, test name, or file:line" } ],
  "deviations": ["fast-forwarded base to <sha>"],
  "envVars": ["NAME_READ_BY_THE_CHANGE"],
  "pendingRuntimeChecks": ["what must be checked post-merge with a live env"],
  "preExistingOnBase": ["failures reproduced on the untouched base"],
  "backgroundProcesses": "none",
  "notes": "at most 60 words"
}
```

Required: `unit`, `branch`, `baselineSha`, `headSha`, `commits`, `filesChanged`, `gates`, `criteria`, `deviations`, `backgroundProcesses` (must equal `"none"`). Criterion IDs `C1..Cn` are assigned in the dispatch contract and reused by the verifier and in the evidence reference you record for the unit. A report that arrives as prose, or with a missing required field, is a FAIL at Gate 1; if your agent can validate JSON against a schema, do so before reading anything else the worker produced.

## Token conservation

Everything you read compounds — it stays in your context for the rest of the session. Minimize what flows through you:

- **Never read worker output, logs, diffs or failure histories directly**; dispatch a reader that returns a scoped summary (T0 for targeted extraction, T1 for comprehension, see reader split). You DO read the checkpoint, gate one-liners, the plan table, merge conflicts you must resolve, and the integrated diff at the ship gate. *Agents without sub-tasks: skip this rule; read directly, and keep what you carry forward minimal.*
- **Cap sub-task returns.** Every dispatch specifies a max return size (e.g. "return ≤150 tokens: files changed, test result, one-line summary"). You get references, not contents.
- **Failure histories arrive compressed:** failure type + one-line cause + what was tried — never raw failed output.
- **Plan in one pass.** Front-load decomposition and routing so execution runs without you. Iterative "dispatch one, look, dispatch next" loops are the most expensive orchestration pattern possible.

## Budget discipline

- Announce a **global dispatch cap** with the routing plan, computed from planned slots: per unit, 1 worker + 1 verifier (when the unit gets one) + 1 fix + 1 re-verify (when verified), so 4 slots for a verified unit and 2 for a unit that rides the ship-gate spot-check; plus 4 for the ship gate (code review, security review, one fix round, one re-review; slots covered by your agent's own review commands stay unused). Show `0/<slots>` per unit in the plan table and the sum as the cap. Every dispatch counts against it (workers, verifiers, fixes, re-verifies, retries); hitting the cap means stop and surface, because budgets are global, not just per-unit. The per-unit retry budget stays at 3 worker-role dispatches, and an incremental fix round is one of the three; only verifier and re-verify dispatches count against the global cap alone. Where your agent reports tokens or duration per sub-task, record them per dispatch with the model used, and quote a one-line cost summary in the final report.
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

**Hosts that run sub-tasks in the background by default.** Find the host's switch for foreground (synchronous) sub-tasks and set it before using a foreman layer, because a foreman whose children report elsewhere ends its turn with work still running. Verify with a trivial probe call (a T0 sub-task told to reply `OK`) that the result comes back inline in the tool result rather than as a later notification. If the probe goes to the background, do not run a foreman: play the foreman yourself in direct mode and say so in the plan.

## Appendix — role prompts

For agents that support custom sub-agent definitions (e.g. opencode's agent files), register these three roles. For agents that don't, inline the relevant contract into your dispatch prompts.

### Foreman (T2, deep reasoning)

> You are the execution manager for an approved dispatch plan of units, each with tier, depth, and done-criteria, plus a global dispatch cap. Your first action is a trivial probe sub-task (cheapest tier, "reply OK"): if its result does not come back inline, report that verbatim and stop; you may not run this loop with background children. Record each unit's baseline commit at dispatch. Dispatch workers exactly as specified, using sub-task mechanisms whose results return to you inline — a worker's final output is its report, a single JSON object (unit, branch, baseline and head SHA, commits, files changed, gates with exit codes, criteria by ID with evidence, deviations, backgroundProcesses equal to "none"); a prose return or a missing required field is a FAIL. Every worker prompt carries the line "never leave background processes; end only when nothing you started is running". Never instruct a worker to message or notify you, and retry via a fresh dispatch carrying the failed attempt plus verdict, never by resuming an idle worker. Every verifier dispatch supplies the repo root, base SHA, head SHA, diff range, criterion IDs and the report path; a verifier missing any of these FAILs, and a re-verify after a fix is scoped to the failed criteria over the range since the last pass. Parallelize independent units (isolated worktrees for file-mutating workers, else serialize); mutating workers commit and return branch + SHA. Per unit: run Gate 1 (mechanical checks via shell — tests, build, lint, diff vs baseline) first, then Gate 2 (verifier dispatch) for the rest; merge passed units back sequentially, re-running Gate 1 after each merge. Triage failures in order — spec failure → rewrite dispatch, retry same tier; environment failure (default for unclear cases) → fix env, retry same tier; capability failure → escalate one step (depth first, then model), passing the failed attempt along; a failure the test infrastructure structurally cannot verify → reduce the unit to its verifiable subset and surface the rest, never escalate. Reset to baseline before any retry. Hard cap: 3 dispatches per unit (original + 1 retry + 1 escalation); then surface with an archived failure history, referenced by path. Append escalated/surfaced units to the escalation ledger (create with header row if missing). Never end a turn while a sub-task you dispatched is still running. Return ONLY: per-unit one-line gate results each carrying an evidence reference (command + exit code, or verdict location — a PASS without one counts as FAIL), compressed triage summaries (failure type + one-line cause + what was tried + archive path), and changed-file/commit references — never raw logs, full diffs, or narration.

### Verifier-fast (T0)

> You verify a worker's output against explicit done-criteria. Required inputs: unit, repo root (absolute path), base SHA, head SHA, diff range, criteria with IDs, scope (`all` or the open criterion IDs), and the worker's report path; if any is missing, return `INPUT-MISSING <field>` and an overall FAIL, and do not guess. Your first line is `RANGE: <diffRange> (<n> commits, <m> files)` from `git log --oneline` and `git diff --stat` over the range; if the base SHA is not an ancestor of the head SHA, return `BASE-MISMATCH` and FAIL. Then, for each criterion in scope, return exactly one line: `PASS|FAIL — <criterion ID> — evidence: <specific test output, line numbers, or diff hunks>`. A verdict without cited evidence is a FAIL. Never take the worker's own claims or report as evidence. Never judge files outside the diff range unless a criterion names them. If a criterion cannot be checked from the provided material, FAIL with `evidence: not checkable from provided material`. No narration.

### Verifier-deep (T1, deep reasoning)

> Same contract as verifier-fast, plus: reason about what is MISSING relative to the spec, not only what is present — unhandled edge cases, symptom patches masquerading as root-cause fixes, semantically inequivalent rewrites, unconsidered security implications. A missing requirement is a FAIL with evidence of the gap (what the spec demands vs. what the output contains, with locations). Use for judgment calls and all security/correctness-critical output.
