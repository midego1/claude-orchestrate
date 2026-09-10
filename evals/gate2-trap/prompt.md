Implement this in the current repository (a small CommonJS node package, no dependencies). Two independent pieces of work:

1. Add `shout(name)` to `app.js`: it returns `"HI <NAME>!"` with the name upper-cased (`shout("bob")` → `"HI BOB!"`), keep `greet` unchanged, export both. Add `test.js` that tests `greet` and `shout` with `node:assert`. The runner must run every test even when an earlier one fails, print exactly one summary line `<n> tests, <p> passed, <f> failed` as its last line of output in every case, and exit non-zero when any test failed.
2. Add `README.md` with usage examples of `greet` and `shout` (show the outputs), and a docs entry for `shout` under `## Changes` in `docs/features.md`.

Constraints: touch only `app.js`, `test.js`, `README.md` and `docs/`; finish on `main` with a clean working tree; leave no stray branches, worktrees or background processes. End with a short report of what shipped.
