# claude-orchestrate: contributor rules

This repo is a Claude Code plugin: prose that agents follow (`skills/orchestrate/`, `agents/`, `templates/`), a CLI they call (`bin/orchestrate`), hooks (`hooks/hooks.json`, `scripts/hooks/`), and schemas. The prose is the protocol; the CLI is where the protocol is enforced.

## Rules of the repo

- **Enforce, do not exhort.** A rule an agent keeps forgetting becomes a CLI command or a hook, not a louder sentence. Every "must" in SKILL.md should have a command that refuses when it is broken (cap, lease epoch, run artifact, stale checkpoint). Field evidence: prose-only rules get summarised away; CLI-enforced ones hold.
- **Never weaken a rule.** The maintenance note at the end of SKILL.md is binding. Anecdotes and rationale move to `skills/orchestrate/REFERENCE.md`; thresholds, must/never statements and procedure steps stay in SKILL.md, DIRECT-MODE.md, foreman.md or the templates at their current strictness. A rewrite is checked rule by rule, not word by word.
- **Word guidance, soft targets with a hard ceiling.** SKILL.md ≈ 4,500 words (ceiling 5,200), `agents/foreman.md` ≈ 3,000 (3,400), DIRECT-MODE.md ≈ 1,200 (1,400), verifiers ≈ 450. These files load into the most expensive context on every run. Above the ceiling, move content to REFERENCE.md or into the CLI; never trim wording to hit a number.
- **Harness claims need evidence.** Any sentence about Claude Code behaviour (env vars, hook fields, fork mode, tool availability) needs a verbatim docs quote or a live probe in this session. Known trap: `CLAUDE_CODE_DISABLE_FORK_MODE` does not exist; fork mode is `CLAUDE_CODE_FORK_SUBAGENT=0`, and `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` is the deterministic foreground switch. Keep `run_in_background: false` on dispatches; the foreman's Agent probe decides the mode.
- **CLI constraints.** `bin/orchestrate` is bash 3.2 (macOS default) plus python3 stdlib; no jq, no flock (use the `mkdir` lock), no bash 4 features. Every mutating subcommand runs under the archive lock and writes the checkpoint atomically after schema validation. Exit codes: 0 ok, 1 error, 2 refused by policy, 3 gate or merge failure.
- **Tests before commit.** `ORCH_TEST_TMP=<tmp> bash tests/cli.sh` and `HOME=<tmp> bash tests/hooks.sh` must be green; a new subcommand or hook behaviour ships with checks. `bash -n` every shell file, `python3 -m json.tool` every JSON.
- **Placeholders are an interface.** `templates/*.md` placeholder names (`<absolute worktree path>`, `<baselineSha>`, `<diffRange>`, …) are filled by `orchestrate contract new` / `contract verify`; renaming one is a CLI change.
- **Plugin root convention.** Agents locate the CLI with `ls -d ~/.claude/plugins/cache/claude-orchestrate/orchestrate/*/ | sort -V | tail -1` (plugin install) or the repo checkout; `${CLAUDE_PLUGIN_ROOT}` is a hook placeholder only.

## Release

1. Bump `.claude-plugin/plugin.json`.
2. Add a `## [x.y.z] — date` section to CHANGELOG.md under `[Unreleased]` with a one-line `**Why update:**` (the update notifier reads that exact line) and one bullet per shipped change naming the field finding it closes.
3. PR to `main`; the installed plugin updates with `claude plugin update orchestrate@claude-orchestrate` and needs a session restart for hooks and skill text.

## Field feedback loop

Each release starts from a field report (see CHANGELOG). New findings go through: reproduce or quote → decide CLI vs prose → implement with tests → adversarial review → live run in a fresh session (`/orchestrate` on a small repo, report the eight questions in the handoff prompt) → scored eval (`evals/run.sh`, see `evals/README.md`: the same task with and without the plugin, outcome and protocol graders, cost per arm; `claude plugin eval` once early access is on).
