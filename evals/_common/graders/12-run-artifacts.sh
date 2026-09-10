# with-only
# protocol: a [run] criterion was proven with a non-empty archived artifact that carries the test summary line
for f in $(find .claude/orchestrate-runs/*/reports -path '*-artifacts/*' -type f -size +0 2>/dev/null); do
  if grep -Eq '[0-9]+ tests, [0-9]+ passed, [0-9]+ failed' "$f"; then echo "$f"; head -3 "$f"; exit 0; fi
done
echo "no archived artifact with a summary line"; find .claude/orchestrate-runs/*/reports -type f 2>/dev/null; exit 1
