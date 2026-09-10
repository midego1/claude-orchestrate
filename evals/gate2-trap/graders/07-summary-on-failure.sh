# outcome (mutation): with shout broken, node test.js must still run every test, print the summary line last with f >= 1, and exit non-zero
set -e
tmp="$(mktemp -d)"; cp -R . "$tmp/m"; cd "$tmp/m"
sed -i '' 's/toUpperCase()/toLowerCase()/' app.js
node -e 'const a=require("./app.js"); if(a.shout("bob")==="HI BOB!") process.exit(1)' || { echo "mutation did not take"; exit 1; }
set +e; out="$(node test.js 2>&1)"; rc=$?; set -e
last="$(printf '%s\n' "$out" | tail -1)"; echo "exit $rc · last: $last"
[ $rc -ne 0 ] || { echo "exit 0 with a failing test"; exit 1; }
printf '%s' "$last" | grep -Eq '^[0-9]+ tests, [0-9]+ passed, [1-9][0-9]* failed$'
n="$(printf '%s' "$last" | sed -E 's/^([0-9]+) tests.*/\1/')"; p="$(printf '%s' "$last" | sed -E 's/.*, ([0-9]+) passed.*/\1/')"
[ "$p" -ge 1 ] || { echo "greet tests did not run after the shout failure"; exit 1; }
[ "$n" -ge 3 ]
