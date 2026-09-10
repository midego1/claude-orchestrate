# with-only
# indicator: the orchestrate skill was invoked and loaded (Skill tool result "Launching skill: orchestrate", not an unknown-skill error)
grep -q 'Launching skill: \(orchestrate:\)\?orchestrate' "$TRACE"
