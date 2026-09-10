# with-only
# protocol: at least one Gate 2 verdict (per-criterion PASS/FAIL lines with evidence, VERDICT: PASS) was archived under gates/ (any file name; the template suggests gates/<unit>-gate2-<n>.md)
f="$(grep -l -E '^VERDICT: PASS' .claude/orchestrate-runs/*/gates/* 2>/dev/null | xargs grep -l -E '^PASS — C[0-9]+ — evidence:' 2>/dev/null | head -1)"
[ -n "$f" ] || { echo "no archived Gate 2 verdict with evidence lines"; ls .claude/orchestrate-runs/*/gates/ 2>/dev/null; exit 1; }
echo "$f"; grep -c -E '^PASS — C[0-9]+ — evidence:' "$f"
