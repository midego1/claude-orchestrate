# with-only
# protocol: exactly one run archive, and orchestrate status ends with COMPLETED at nextAction complete
runs="$(ls -d .claude/orchestrate-runs/*/ 2>/dev/null | wc -l | tr -d ' ')"
[ "$runs" = 1 ] || { echo "run archives: $runs"; exit 1; }
st="$("$PLUGIN_ROOT/bin/orchestrate" status 2>&1)"; echo "$st"
echo "$st" | grep -q 'next complete · COMPLETED$'
