#!/bin/sh
# Update notifier for the orchestrate plugin.
#
# Runs on SessionStart (matcher: startup). Compares the installed plugin
# version against the repo's main branch, at most once per hour, and — when
# a newer version exists — emits a notice with the changelog's "Why update"
# line and the exact update command.
#
# This script NEVER updates anything itself. Updating is the user's choice.
# Any failure (no network, missing curl, parse error) exits 0 silently —
# a broken notifier must never break a session.

set -u 2>/dev/null || true

REPO_RAW="https://raw.githubusercontent.com/midego1/claude-orchestrate/main"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}"
[ -n "$PLUGIN_ROOT" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0

# Rate limit: at most one remote check per hour.
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-orchestrate"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0
STAMP="$CACHE_DIR/last-update-check"
NOW=$(date +%s)
if [ -f "$STAMP" ]; then
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  case "$LAST" in (*[!0-9]*) LAST=0;; esac
  [ $((NOW - LAST)) -lt 3600 ] && exit 0
fi
echo "$NOW" > "$STAMP" 2>/dev/null || true

# Local and remote versions.
LOCAL_V=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null | head -1)
[ -n "$LOCAL_V" ] || exit 0
REMOTE_V=$(curl -fsSL --max-time 4 "$REPO_RAW/.claude-plugin/plugin.json" 2>/dev/null \
  | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -n "$REMOTE_V" ] || exit 0
[ "$LOCAL_V" = "$REMOTE_V" ] && exit 0

# Only notify when remote is strictly newer (a dev checkout may be ahead).
NEWEST=$(printf '%s\n%s\n' "$LOCAL_V" "$REMOTE_V" | sort -V 2>/dev/null | tail -1)
[ "$NEWEST" = "$REMOTE_V" ] || exit 0

# Pull the "Why update" line for the remote version from the changelog.
WHY=$(curl -fsSL --max-time 4 "$REPO_RAW/CHANGELOG.md" 2>/dev/null \
  | awk -v ver="$REMOTE_V" '
      index($0, "## [" ver "]") == 1 { in_ver = 1; next }
      in_ver && /^## \[/ { exit }
      in_ver && /^\*\*Why update:\*\*/ {
        sub(/^\*\*Why update:\*\* */, ""); print; exit
      }')

MSG="orchestrate plugin: update available (v${LOCAL_V} -> v${REMOTE_V})."
[ -n "$WHY" ] && MSG="$MSG Why it matters: ${WHY}"
MSG="$MSG Full changelog: https://github.com/midego1/claude-orchestrate/blob/main/CHANGELOG.md"
MSG="$MSG — To update (your choice, nothing happens automatically): run /plugin -> Manage, or \`claude plugin update orchestrate@claude-orchestrate\`, then /reload-plugins."

# JSON-escape the message (quotes and backslashes; the text has no newlines).
ESCAPED=$(printf '%s' "$MSG" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"systemMessage":"%s"}\n' "$ESCAPED"
exit 0
