<!-- Scoped Gate 2 re-verification after an incremental fix round (retry shape b). Copy this file, fill every <placeholder>, write it to <archive>/dispatch/<unit>-reverify-<n>.md.
The Agent prompt is then the pointer sentence: "read <that path>, execute exactly, final text = report per the contract's output format; do not use SendMessage or any messaging tool; your final text is your entire report." Pass run_in_background: false (honored on some versions, never sufficient alone).
Wrap the call in `orchestrate dispatch open <unit> --role reverify --epoch <epoch> --model <same verifier model as the prior verdict: haiku for verifier-fast | sonnet for verifier-deep> --effort <same effort: low | xhigh>` (the verifier's own model and effort, never the unit's plan-row values) and `orchestrate dispatch close <unit> <n> --exit PASS|FAIL --evidence gates/<unit>-gate2-<n>.md`; same verifier type as the prior verdict; it counts against the global cap, not the unit's 3 worker dispatches.
Not this template: the ship-gate re-review runs over the integrated diff on the reserved pseudo-unit `ship` (`orchestrate dispatch open ship --role reverify --epoch <epoch> --model <m> --effort <x>`). -->

# Scoped Gate 2 re-verification: <unit>

Verifier: `<verifier-fast | verifier-deep>` (the same type that produced the prior verdict).

Only the open items from the prior verdict are under review. Do not re-litigate PASSed items. The diff is pinned to the fix round: `<lastPassedSha>..<headSha>`, where `lastPassedSha` is the commit the prior verdict evaluated and `headSha` is the head after the incremental fix on the SAME branch.

## Inputs

Every field is required. The verifier returns `INPUT-MISSING — <field>` and `VERDICT: FAIL` for any absent field and does not guess.

| field | value |
|---|---|
| unit | `<unit>` |
| repoRoot | `<absolute path of the unit worktree>` |
| baselineSha | `<baselineSha recorded at dispatch>` |
| headSha | `<headSha from the fix-round worker report>` |
| diffRange | `<lastPassedSha>..<headSha>` |
| scope | `<open criterion IDs, e.g. C2, C4>` |
| reportPath | `<archive>/reports/<unit>-<n>.json` (the fix-round report) |
| priorVerdictRef | `<archive>/gates/<unit>-gate2-<n-1>.md` |

## Criteria in scope (IDs and text exactly as in `dispatch/<unit>.md`)

- C2: <criterion text> · prior verdict: FAIL · <one line: what the prior verdict found> · settling evidence: <...>
- C4: <criterion text> · prior verdict: FAIL · <...> · settling evidence: <...>

Criteria not listed here PASSed at `<lastPassedSha>` and are out of scope.

## Instructions

1. First line: `RANGE: <lastPassedSha>..<headSha> (<n> commits, <m> files)`, from:

```
git -C <repoRoot> log --oneline <lastPassedSha>..<headSha> | wc -l
git -C <repoRoot> diff --stat <lastPassedSha>..<headSha>
```

2. Stale-baseline defence:

```
git -C <repoRoot> merge-base --is-ancestor <baselineSha> <headSha>
```

   On failure return `BASE-MISMATCH — <baselineSha> is not an ancestor of <headSha>` and `VERDICT: FAIL`, nothing else.

3. One line per criterion in scope, carrying its ID. Read `priorVerdictRef` only to learn what was open. `verifier-deep` also returns `MISSING` lines, limited to defects in or caused by the scoped range.
4. Last line: `VERDICT: PASS|FAIL`.

Rules: you are read-only; the worker report is a claim, never evidence; a verdict without cited evidence is a FAIL; evaluate only files inside the scoped `diffRange` unless the criterion names the file; a criterion not checkable from the material given is FAIL with `evidence: not checkable from provided material`; no narration.

## Output format

Exactly these lines, nothing before or after:

```
RANGE: <lastPassedSha>..<headSha> (<n> commits, <m> files)
PASS|FAIL — C2 — evidence: <specific test output, line numbers, or diff hunks>
PASS|FAIL — C4 — evidence: <...>
MISSING — <defect> — evidence: <...>        (verifier-deep only, zero or more)
VERDICT: PASS|FAIL
```
