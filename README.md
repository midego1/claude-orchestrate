# claude-orchestrate

Multi-agent orchestration plugin for [Claude Code](https://claude.com/claude-code). Decomposes substantive tasks into units, routes each unit to the **cheapest model that can reliably do it**, verifies output through **evidence-gated checks** (never trusting a sub-agent's self-report), and escalates only on genuine capability failures — with a hard retry budget so costs can't spiral.

Designed for running a frontier model (e.g. Fable 5 or Opus) as your session model: the expensive model plans, routes, and integrates; cheap workers do the volume.

## What's inside

| Component | What it does |
|---|---|
| `skills/orchestrate` | The orchestration protocol. Auto-triggers on substantive multi-unit tasks; stays out of the way on trivial turns. |
| `agents/foreman` | Execution manager (opus, high effort). Runs the dispatch loop: dispatches workers, runs gates, triages failures, manages retries. |
| `agents/verifier-fast` | Gate 2 verifier (haiku). PASS/FAIL per done-criterion, with cited evidence. |
| `agents/verifier-deep` | Gate 2 verifier for judgment calls (sonnet, xhigh effort). Also reasons about what is *missing* relative to the spec. |

## How it works

```
you (frontier model) ─ decompose, classify, route          ← plans & integrates only
        │
        ▼
     foreman (opus) ─ dispatch loop, triage, retries       ← owns execution
        │
        ├── workers (haiku/sonnet/opus, routed per unit)
        │
        ├── Gate 1: mechanical checks (bash — tests, build, grep invariants)
        └── Gate 2: verifier-fast / verifier-deep           ← evidence or it didn't happen
```

Three ideas carry the design:

1. **Failure triage before escalation.** Most sub-agent failures are spec failures or environment failures, not capability failures. Escalating a bad spec buys an expensive wrong answer — so the foreman rewrites and retries at the same tier first. Hard cap: 2 attempts + 1 escalation per unit.
2. **Evidence-gated verification.** A verdict without cited evidence (test output, line numbers, diff hunks) is a FAIL. A sub-agent's claim of success is never accepted on its own.
3. **Orchestrator token conservation.** Everything the top model reads compounds in its context. So: readers instead of direct file reads, capped sub-agent returns, compressed failure summaries, one-pass planning.

### Model routing (summary)

| Tier | Model | For |
|---|---|---|
| T0 | haiku | Lookups, fan-out reads, formatting, boilerplate, exact-spec edits, criteria verification |
| T1 | sonnet | Implementation from a clear spec, tests, known-root-cause fixes, 1–3 file refactors, open-ended comprehension reads |
| T2 | opus | Cross-file refactors, root-cause investigation, critical-path review, security-sensitive code |
| T3 | fable | Rare: long autonomous investigation with unclear constraints |

Full routing heuristics, depth (effort) routing, the dispatch contract, and budget discipline live in [`skills/orchestrate/SKILL.md`](skills/orchestrate/SKILL.md).

## Install

### As a plugin (recommended)

```
/plugin marketplace add midego1/claude-orchestrate
/plugin install orchestrate@claude-orchestrate
```

### Team-wide, per repo

Add to your repo's `.claude/settings.json` so everyone gets it automatically:

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

Copy `skills/orchestrate/` into `.claude/skills/` and `agents/*.md` into `.claude/agents/` of your repo.

### Recommended: activation nudge in CLAUDE.md

Skill triggering is description-based. For near-deterministic activation, add a short rule to your repo's `CLAUDE.md`:

```markdown
For substantive multi-unit tasks (>~3 independent units, multi-file changes,
or work that benefits from parallel workers), use the `orchestrate` skill.
Trivial turns and single-file fixes: work directly.
```

## Requirements

- **Claude Code ≥ 2.1.172** (nested sub-agents: the foreman dispatches workers of its own).
- Works best with a frontier model (Fable 5 / Opus) as the session model and effort at `xhigh` — the orchestrator's whole job is judgment, and its token surface is deliberately small.

## Runtime artifacts

The foreman appends every escalated or surfaced unit to `.claude/escalation-ledger.md` in **your** repo (`unit | initial tier | failure type | final tier | outcome`), creating it on first use. This ledger is how the routing table gets corrected over time: if more than a third of units escalate, the decomposition or specs are the problem, not the models.

## License

[MIT](LICENSE)
