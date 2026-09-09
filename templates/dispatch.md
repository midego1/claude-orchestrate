<!-- Worker dispatch contract (file-referenced dispatch). Copy this file, fill every <placeholder>, write it to <archive>/dispatch/<unit>.md before `orchestrate dispatch open <unit> --role worker --epoch <epoch>`.
The Agent prompt is then the pointer sentence: "read <that path>, execute exactly, final text = report per the contract's output format; do not use SendMessage or any messaging tool; your final text is your entire report." Pass model and effort from the plan table and run_in_background: false (honored on some versions, never sufficient alone).
A retry is the same pointer plus the verifier's verdict path. On return: `orchestrate report save <unit> <file.json>` (Gate 1 starts there), then `orchestrate gate run <unit> unit --cwd <worktree>`, and only after Gate 1: `orchestrate dispatch close <unit> <n> --exit <Gate 1 result> --evidence gates/<unit>-unit-<n>.log --tokens <t> --duration <s>`.
The dispatcher fills the Gates line below from the manifest's unit stage with `{{baseline}}` already replaced by `<baselineSha>`; the worker never reads the manifest. -->

# Dispatch contract: <unit>

## 1. Objective

<One sentence: the outcome, not the steps.>

## 2. Context

Sub-agents share nothing with the dispatcher or each other; over-include rather than assume.

- Worktree: `<absolute worktree path>` on branch `unit/<unit>` (the `orchestrate worktree add` default; state the real name if `--branch` overrode it), created at baseline `<baselineSha>`.
- Integration branch: `<integrationBranch>` (do not merge into it; the dispatcher integrates).
- Files in scope: `<declared file scope>`. Changes outside it fail the diff-scope check.
- Constraints and conventions: `<relevant paths, patterns to follow, things that must not change>`.
- Related units running in parallel: `<ids and their file scopes, or none>`.
- Shared docs: `<either "you own <file> this wave" or "write your fragment to docs/_pending/<unit>.md; do not edit <file>">`.

## 3. Done-criteria (IDs C1..Cn; verifiers and `dispatch close --evidence` reuse them)

Each criterion is decidable: mechanically checkable wherever possible (exact command, invariant, expected diff scope), otherwise judgeable from evidence by a Gate 2 verifier, with the settling evidence stated. If no decidable criterion can be stated, the unit is under-specified: re-decompose instead of dispatching.

- C1: <criterion> · evidence: <exact command and expected exit, invariant, or diff scope>
- C2: <criterion> · evidence: <...>
- Cn: <criterion> · evidence: <...>

UI units add a reachability criterion (import-chain grep proving a route-reachable file imports the component; runtime mount evidence post-merge). Stateful modules name the expected init site (composition root) so the init-wiring grep is decidable.

## 4. Output format

Your final text is exactly ONE fenced `json` block matching `schemas/worker-report.schema.json`. Nothing before it, nothing after it, no narration.

```json
{
  "unit": "<unit>",
  "branch": "unit/<unit>",
  "baselineSha": "<baselineSha>", "headSha": "<sha of your last commit>",
  "commits": ["sha1", "sha2"],
  "filesChanged": ["path"],
  "gates": [ { "id": "typecheck", "cmd": "pnpm typecheck", "exit": 0 } ],
  "criteria": [ { "id": "C1", "status": "PASS|FAIL|EXECUTION-PENDING", "evidence": "≤ 40 words: command + exit, test name, or file:line" } ],
  "deviations": ["fast-forwarded base to <sha>", "..."],
  "envVars": ["NAME_READ_BY_THE_CHANGE"],
  "pendingRuntimeChecks": ["what must be checked post-merge with a live env"],
  "preExistingOnBase": ["failures reproduced on the untouched base"],
  "backgroundProcesses": "none",
  "notes": "≤ 60 words"
}
```

Required: `unit`, `branch`, `baselineSha`, `headSha`, `commits`, `filesChanged`, `gates`, `criteria`, `deviations`, `backgroundProcesses` (must equal the literal `"none"`). `criteria[].id` uses the IDs from section 3, one entry per criterion. Every gate you ran appears in `gates[]` with its real exit code; a non-zero exit needs the matching criterion marked FAIL or EXECUTION-PENDING. Empty arrays are fine; missing keys are not. Whole report ≤ <N> tokens.

## 5. Depth instruction

<`ultrathink` for xhigh-equivalent reasoning, or "be direct, don't explore" for low-depth units.>

## Standard worker preamble (canonical full text; REFERENCE.md quotes this block; never strip it; placeholders filled)

> You are in an isolated worktree at `<absolute worktree path>` on branch `<branch>`; baseline `<baselineSha>`.
> - **Verify your base FIRST:** run `git merge-base --is-ancestor <baselineSha> HEAD`. If it fails, exactly ONE self-remedy is permitted: when HEAD is an ancestor of the baseline (pure fast-forward, verify with the reverse check `git merge-base --is-ancestor HEAD <baselineSha>`), you MAY `git merge --ff-only <baselineSha>` and MUST disclose it in `deviations` as `fast-forwarded base to <sha>`. Any other mismatch: STOP and report; do not improvise a new branch, do not merge.
> - **Environment:** the manifest's `envBootstrap` (`<envBootstrap, e.g. cp -n .env.example .env>`) and `install` (`<install command, frozen lockfile, e.g. pnpm install --frozen-lockfile>`) already ran at `orchestrate worktree add` (log: `gates/<unit>-bootstrap.log`); re-run `<install command>` only if the dependency directory (e.g. `node_modules`) is missing. Runtime services are unavailable: run mechanical gates only (typecheck / lint / unit tests). Mark any done-criterion you cannot check without runtime **EXECUTION-PENDING** and list what must be checked in `pendingRuntimeChecks`; it is checked post-merge in the integration worktree. List every environment variable your change reads in `envVars`.
> - **Gates:** run exactly these commands (the manifest's unit gates with `{{baseline}}` already replaced by `<baselineSha>`): `<gate id: command, one per gate>`. Do not read the manifest yourself. Record each in `gates[]` with its exit code.
> - **Phantom-failure rule:** if a gate fails, re-run it on the untouched base in this same worktree before attributing it to your change (dependency drift in fresh installs produces phantom failures). Report "pre-existing on base" findings in `preExistingOnBase`; do not fix them, do not block on them.
> - **Never leave background processes:** end only when nothing you started is still running; `backgroundProcesses` must be the literal `none`. No watcher, dev server, or polling loop may outlive your final text.
> - **Return:** commit granularly. The JSON report carries branch name, commit SHAs, files changed, and each gate command with its result. ≤ <N> tokens, no narration.
> - **No messaging:** do not use SendMessage or any messaging tool. Your final text is your entire report; anything sent as a message is treated as advisory noise and will not be read as a result.

## Shared-worktree git hygiene (keep only when isolation is `shared`; delete for worktree-isolated workers)

> **Shared-worktree git hygiene.** Stage only explicit paths (`git add <path>`). NEVER `git add -A`, `git add .`, or `git stash`; other workers may have uncommitted changes in this tree. If your change adds a dependency, list it in `deviations` for the dispatcher to install serially; do not run a full install that rewrites the lockfile under concurrency.
