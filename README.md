# claude-orchestrate

**Multi-agent orchestration plugin for [Claude Code](https://claude.com/claude-code).** Your frontier model plans, routes, and verifies; cheap workers do the volume. Every unit of work is routed to the cheapest model that can reliably do it, checked by evidence-gated verification (a sub-agent's "done!" is never trusted), and escalated only on genuine capability failures — under a hard retry budget so costs can't spiral.

---

## ⚡ When does it activate?

**Automatically**, when your task is substantive:

- decomposes into **more than ~3 independent units**, or
- spans **multiple files or subsystems**, or
- benefits from **parallel workers** (features, migrations, audits, large refactors, multi-bug sweeps).

It deliberately stays **out of the way** on trivial turns — single-file fixes, quick lookups, conversational questions. Those are faster done directly, and the skill's description tells the model exactly that.

**Manually**, any time:

```
/orchestrate <your task>
```

e.g. `/orchestrate migrate all 40 API routes to the new error-handling pattern`

> **Tip — make auto-activation near-deterministic:** skill triggering is description-based. Add a one-line rule to your repo's `CLAUDE.md` (see [Install](#install)) and the orchestrator fires reliably on every substantive task.

## 🎛️ Ideal setup: which model to select in Claude Code

The model you select in Claude Code **is the orchestrator** — it does the decomposition, routing, escalation judgment, and final integration. The workers don't change with your selection (their models are pinned per dispatch), so this choice is purely about the quality of the *judgment* at the top.

| Setting | Recommended | Why |
|---|---|---|
| **Session model** | **Fable 5** (`/model claude-fable-5`) | The orchestrator's whole job is judgment: decomposition quality determines everything downstream. A bad plan at the top causes escalation cascades below. |
| **Reasoning effort** | **`xhigh`** | Deep reasoning over a deliberately *small* token surface — the orchestrator never reads files or raw logs, so you pay frontier prices only for planning. Not `max`: that's prone to overthinking on repeated routine routing decisions. |
| **Claude Code version** | **≥ 2.1.172** | Nested sub-agents: the foreman must dispatch workers of its own. |

Running Opus or Sonnet as the session model works too — the protocol is model-agnostic — but plan quality, and therefore total cost, degrades: weaker decomposition means more retries and escalations below.

---

## What it does

Given a substantive task, the orchestrator:

1. **Decomposes** it into independent units, each with explicit inputs, outputs, and machine-checkable done-criteria.
2. **Classifies** each unit into a complexity tier (T0–T3) and announces the routing plan as one compact table — before spending anything.
3. **Hands execution to a foreman** (an Opus sub-agent) that dispatches workers in parallel, runs verification gates, triages failures, and manages retries — without the expensive top model in the loop.
4. **Verifies everything through gates.** Mechanical checks first (tests, builds, grep invariants — free), then cheap verifier agents that must cite evidence. A verdict without evidence is a FAIL.
5. **Escalates only real capability failures** — after triage rules out bad specs and broken environments — one tier at a time, capped at 2 attempts + 1 escalation per unit.
6. **Integrates** gate-passed results, checks cross-unit consistency, and ships.

The net effect: frontier-quality output at a fraction of frontier cost, with failure containment built in.

## How it works

```
  YOU select the session model  ──►  ORCHESTRATOR (Fable 5 @ xhigh)
                                      plans · routes · escalates · integrates
                                      never reads files or raw output directly
                                          │
                                          │  full dispatch plan (units, tiers, criteria)
                                          ▼
                                     FOREMAN (opus @ high)
                                      dispatch loop · failure triage · retries
                                          │
              ┌───────────────────────────┼───────────────────────────┐
              ▼                           ▼                           ▼
        worker (haiku)             worker (sonnet)              worker (opus)
        T0: lookups, fan-out,      T1: implementation           T2: cross-file
        boilerplate, exact-        from a clear spec,           refactors, root-cause
        spec edits                 tests, docs                  hunts, security code
              │                           │                           │
              └───────────────────────────┼───────────────────────────┘
                                          ▼
                            GATE 1 · mechanical (bash, ~free)
                            tests pass · build clean · diff in scope
                                          ▼
                            GATE 2 · evidence-cited review
                            verifier-fast (haiku): criteria comparison
                            verifier-deep (sonnet @ xhigh): what's MISSING
                                          ▼
                            GATE 3 · orchestrator
                            cross-unit consistency only —
                            one line per unit, evidence attached only on FAIL
```

### The three ideas that carry the design

**1. Failure triage before escalation.** Most sub-agent failures are *not* capability failures. The foreman triages in strict order:

| Failure type | Meaning | Response |
|---|---|---|
| **Spec failure** | Ambiguous criteria, missing context, wrong assumption in the dispatch | Rewrite the dispatch, retry **same** tier — escalating a bad spec buys an expensive wrong answer |
| **Environment failure** | Flaky test, missing dep, wrong branch, stale state | Fix the environment, retry same tier |
| **Capability failure** | Spec was correct and complete; the model genuinely couldn't do it | Escalate **one** tier (effort first, then model), passing the failed attempt along |

Hard cap: **2 attempts + 1 escalation per unit**, then the unit is surfaced to you with its full failure history. No escalation ladders, ever.

**2. Evidence-gated verification.** No sub-agent's self-report of success is ever trusted. Verifiers must return PASS/FAIL *per criterion* with cited evidence — specific test output, line numbers, diff hunks. "Looks correct" is a FAIL. The deep verifier additionally reasons about what is **missing** relative to the spec: unhandled edge cases, symptom patches masquerading as root-cause fixes, semantically inequivalent rewrites.

**3. Orchestrator token conservation.** Everything the top model reads stays in its context and is re-processed every subsequent turn. So the orchestrator never reads files (readers summarize instead — haiku for targeted extraction, sonnet for open-ended comprehension), every dispatch caps its return size, failure histories arrive compressed, and planning happens in one pass rather than dispatch-look-dispatch loops.

### Model routing

| Tier | Model | Use for |
|---|---|---|
| **T0 — Mechanical** | haiku | Lookups, grep-style exploration, fan-out reads, renaming, formatting, boilerplate, exact-spec single-file edits, criteria verification |
| **T1 — Standard** | sonnet | Implementation from a clear spec, tests, known-root-cause bug fixes, docs, 1–3 file refactors, open-ended comprehension reads |
| **T2 — Complex** | opus | Cross-file refactors, root-cause investigation of non-obvious bugs, critical-path review, migration planning, concurrency logic, security-sensitive code |
| **T3 — Frontier** | fable | Rare: units needing long autonomous investigation with unclear constraints — usually the orchestrator itself is the frontier tier and T2 suffices below it |

Key heuristics (full set in [`SKILL.md`](skills/orchestrate/SKILL.md)):

- Spec so precise it's mechanically checkable → **drop a tier**.
- Wrong answer expensive to detect → **route up** rather than rely on retry.
- **Reader split:** targeted questions ("what does X do?") → haiku; open questions ("how does this subsystem work?") → sonnet. Haiku's failure mode as a reader is *silent omission* — the expensive kind.
- Target distribution: ~60% T0/T1, ~35% T2, ≤5% T3. Heavier than that → the decomposition is wrong, not the models.

### Reasoning depth

Effort is a second, cheaper lever than model choice — Sonnet at `xhigh` often matches Opus at `high` for a fraction of the cost.

| Depth | When |
|---|---|
| low | Fully-specified, mechanically checkable output |
| medium | Cost-sensitive standard work where a rare miss is cheap to catch |
| **high** (default) | Normal implementation and analysis |
| xhigh | Debugging without a known cause, design trade-offs, security/correctness review |
| max | Last resort, single hardest unit only — prone to overthinking |

## What's inside

| Component | Model / effort | Role |
|---|---|---|
| [`skills/orchestrate`](skills/orchestrate/SKILL.md) | (loads into your session) | The full protocol: decomposition, routing tables, gates, triage rules, dispatch contract, budget discipline |
| [`agents/foreman`](agents/foreman.md) | opus @ high | Execution manager: dispatch loop, gates, triage, retries, escalation ledger |
| [`agents/verifier-fast`](agents/verifier-fast.md) | haiku | Gate 2: PASS/FAIL per done-criterion, evidence required |
| [`agents/verifier-deep`](agents/verifier-deep.md) | sonnet @ xhigh | Gate 2 for judgment calls: also reasons about what's *missing* vs. the spec |

## Install

### As a plugin (recommended)

```
/plugin marketplace add midego1/claude-orchestrate
/plugin install orchestrate@claude-orchestrate
```

### Team-wide, per repo

Add to your repo's `.claude/settings.json` — everyone on the team gets it automatically:

```json
{
  "extraKnownMarketplaces": {
    "claude-orchestrate": {
      "source": { "source": "github", "repo": "midego1/claude-orchestrate" }
    }
  },
  "enabledPlugins": {
    "orchestrate@claude-orchestrate": true
  }
}
```

### Manual copy

Copy `skills/orchestrate/` into your repo's `.claude/skills/` and `agents/*.md` into `.claude/agents/`.

### Recommended: activation nudge in CLAUDE.md

```markdown
## Orchestration

For substantive multi-unit tasks (>~3 independent units, multi-file changes,
or work that benefits from parallel workers), use the `orchestrate` skill.
Trivial turns and single-file fixes: work directly, no orchestration.
```

`CLAUDE.md` is read at the start of every session, so this makes activation near-deterministic instead of relying on description matching alone.

## Runtime artifacts

The foreman appends every escalated or surfaced unit to `.claude/escalation-ledger.md` in **your** repo (created on first use):

```
unit | initial tier | failure type | final tier | outcome
```

This ledger is the system's feedback loop: it shows where the routing table is mis-calibrated. If more than a third of units escalate in a session, the decomposition or the specs are the problem — not the models.

## FAQ

**Does this cost more than just doing the work directly?**
For trivial tasks, yes — which is why it doesn't trigger on them. For substantive tasks it's cheaper *and* better: the volume runs on haiku/sonnet instead of your frontier model, and the gates catch plausible-but-wrong output before it compounds.

**What if a worker claims success but is wrong?**
That's the core design case. Claims of success without gate evidence are FAILs by definition. Gate 1 runs the actual tests; Gate 2 verifiers must cite evidence per criterion.

**Can I use this without Fable 5?**
Yes — any session model works. You lose orchestration judgment quality, which shows up as more retries and escalations downstream, not as a hard failure.

**Why is the orchestrator forbidden from reading files?**
Its context compounds: everything it reads is re-processed on every later turn of the session. Readers return scoped summaries instead, so frontier tokens are spent on judgment, not on I/O.

## License

[MIT](LICENSE)
