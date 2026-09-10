# outcome: commits since the baseline touch only the files the task names
base="$(cat .git/eval-baseline)"
files="$(git diff --name-only "$base" HEAD | sort)"
echo "$files"
bad="$(echo "$files" | grep -v -E '^(app\.js|test\.js|README\.md|docs/features\.md|docs/_pending/.*)$' || true)"
[ -z "$bad" ] || { echo "out of scope: $bad"; exit 1; }
[ -n "$files" ]
