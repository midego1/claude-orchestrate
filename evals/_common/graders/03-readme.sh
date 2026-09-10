# outcome: README.md exists with usage examples of both functions
[ -f README.md ] || { echo "no README.md"; exit 1; }
grep -q 'greet(' README.md && grep -q 'shout(' README.md && grep -q 'HI BOB!' README.md
