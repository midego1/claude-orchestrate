# outcome: node test.js exits 0 and its last stdout line is the summary line with 0 failed
set -e
[ -f test.js ] || { echo "no test.js"; exit 1; }
out="$(node test.js 2>&1)"; rc=$?
last="$(printf '%s\n' "$out" | tail -1)"
echo "$last"
[ $rc -eq 0 ] || { echo "exit $rc"; exit 1; }
printf '%s' "$last" | grep -Eq '^[0-9]+ tests, [0-9]+ passed, 0 failed$'
