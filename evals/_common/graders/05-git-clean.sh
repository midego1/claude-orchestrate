# outcome: on main, clean tree, no leftover worktrees or unit branches
git status --short | tee /dev/stderr | grep -q . && { echo "dirty tree"; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "not on main"; exit 1; }
[ "$(git worktree list | wc -l | tr -d ' ')" = 1 ] || { git worktree list; echo "worktrees left"; exit 1; }
exit 0
