<!-- Gate 2 verifier dispatch. Copy this file, fill every <placeholder>, write it to <archive>/dispatch/<unit>-verify.md (the worker contract stays in dispatch/<unit>.md).
The Agent prompt is then the pointer sentence: "read <that path>, execute exactly, final text = report per the contract's output format; do not use SendMessage or any messaging tool; your final text is your entire report." Pass run_in_background: false (honored on some versions, never sufficient alone).
Freshness check before filling this file: if `git -C <wt> merge-base --is-ancestor <lastIntegratedSha> <headSha>` is false, first merge the integration branch into the unit branch (`git -C <wt> merge <integrationBranch>`), re-run `orchestrate gate run <unit> unit --cwd <wt>`, record the merge in `dispatch-log.md`, then fill `headSha` with the post-merge head and `diffRange` with `<baselineSha>..<headSha>`. `BASE-MISMATCH` below stays the ancestry check it is.
Wrap the call in `orchestrate dispatch open <unit> --role verifier --epoch <epoch> --model <haiku for verifier-fast | sonnet for verifier-deep> --effort <low | xhigh>` (always the verifier's own model and effort, never the unit's plan-row values: the CLI defaults to those and `orchestrate cost` would bill the verifier to the worker's model) and `orchestrate dispatch close <unit> <n> --exit PASS|FAIL --evidence gates/<unit>-gate2-<n>.md`; save the returned text to that gates/ path first. -->

# Gate 2 verification: <unit>

Verifier: `<verifier-fast | verifier-deep>` (from the plan table: one tier below the producer, floor haiku; security- or correctness-critical output gets `verifier-deep`).

## Inputs

Every field is required. The verifier returns `INPUT-MISSING — <field>` and `VERDICT: FAIL` for any absent field and does not guess.

| field | value |
|---|---|
| unit | `<unit>` |
| repoRoot | `<absolute path of the unit worktree>` |
| baselineSha | `<baselineSha recorded at dispatch>` |
| headSha | `<headSha from the worker report>` |
| diffRange | `<baselineSha>..<headSha>` |
| scope | `all` |
| reportPath | `<archive>/reports/<unit>-<n>.json` |
| priorVerdictRef | `none` (first verification) |

## Criteria (IDs exactly as in `dispatch/<unit>.md`)

- C1: <criterion text> · settling evidence: <exact command, invariant, diff scope, or what a judgment must rest on>
- C2: <criterion text> · settling evidence: <...>
- Cn: <criterion text> · settling evidence: <...>

## Instructions

1. First line: `RANGE: <diffRange> (<n> commits, <m> files)`, from:

```
git -C <repoRoot> log --oneline <diffRange> | wc -l
git -C <repoRoot> diff --stat <diffRange>
```

2. Stale-baseline defence:

```
git -C <repoRoot> merge-base --is-ancestor <baselineSha> <headSha>
```

   On failure return `BASE-MISMATCH — <baselineSha> is not an ancestor of <headSha>` and `VERDICT: FAIL`, nothing else.

3. One line per criterion in scope, carrying its ID. `verifier-deep` also returns `MISSING — <defect> — evidence: ...` lines for defects the criteria do not cover.
4. Last line: `VERDICT: PASS|FAIL`.

Rules: you are read-only; the worker report at `reportPath` is a claim, never evidence; a verdict without cited evidence is a FAIL; evaluate only files inside `diffRange` unless the criterion names the file; a criterion not checkable from the material given is FAIL with `evidence: not checkable from provided material`; no narration.

## Output format

Exactly these lines, nothing before or after:

```
RANGE: <diffRange> (<n> commits, <m> files)
PASS|FAIL — C1 — evidence: <specific test output, line numbers, or diff hunks>
PASS|FAIL — C2 — evidence: <...>
MISSING — <defect> — evidence: <...>        (verifier-deep only, zero or more)
VERDICT: PASS|FAIL
```
