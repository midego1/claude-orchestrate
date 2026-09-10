#!/usr/bin/env bash
# Builds the fixture repo for the orchestrate evals at $1: a two-function CommonJS package with a
# gates manifest, a docs registry and one commit on main. Mirrors the first live field run (v0.6.1).
set -e
dst="$1"; mkdir -p "$dst/docs" "$dst/.claude"; cd "$dst"
git init -q -b main
git config user.email eval@example.com; git config user.name eval
cat > app.js <<'JS'
function greet(name) { return "hi " + name }
module.exports = { greet }
JS
printf '{"name":"orchestrate-eval","version":"1.0.0"}\n' > package.json
printf '# Features\n\n## Changes\n\n## Other\n' > docs/features.md
cat > CLAUDE.md <<'MD'
# orchestrate-eval

Small CommonJS package. No dependencies, plain node. Tests are plain `node test.js`.
Multi-unit work in this repo goes through the `/orchestrate` skill when it is available in the session; when it is not, work directly.
MD
cat > .claude/orchestrate-gates.json <<'JSON'
{
  "install": "true",
  "envBootstrap": "true",
  "cachePaths": [".cache"],
  "gates": {
    "unit":        [ { "id": "load", "cmd": "node -e 'require(\"./app.js\")'" }, { "id": "test", "cmd": "test ! -f test.js || node test.js" } ],
    "integration": [ { "id": "load", "cmd": "node -e 'require(\"./app.js\")'" }, { "id": "test", "cmd": "node test.js" } ],
    "ship":        [ { "id": "load", "cmd": "node -e 'require(\"./app.js\")'" }, { "id": "test", "cmd": "node test.js" } ]
  },
  "docs": [ { "fragments": "docs/_pending", "target": "docs/features.md", "section": "## Changes" } ],
  "pricing": { "haiku": { "inPerMTok": 1, "outPerMTok": 5, "perMTok": 2 }, "sonnet": { "inPerMTok": 2, "outPerMTok": 10, "perMTok": 4 }, "opus": { "inPerMTok": 5, "outPerMTok": 25, "perMTok": 10 } }
}
JSON
git add -A && git commit -qm "init: greet + docs scaffold"
git rev-parse HEAD > .git/eval-baseline
echo "fixture at $dst ($(git rev-parse --short HEAD))"
