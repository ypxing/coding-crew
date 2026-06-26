#!/usr/bin/env bash
# Non-interactive tracker setup. Picks the single available template, or defaults
# to 'local' when multiple exist. Exits 1 if no templates are found.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
DEST="$REPO_ROOT/.coding-crew/docs/issue-tracker.md"

if [ -f "$DEST" ]; then
  echo "Tracker already configured: $DEST"
  exit 0
fi

REPO_TRACKERS="$REPO_ROOT/.coding-crew/docs/templates/trackers"
USER_TRACKERS="$HOME/.coding-crew/docs/templates/trackers"

if [ -d "$REPO_TRACKERS" ] && [ -n "$(find "$REPO_TRACKERS" -name "*.md" -print -quit 2>/dev/null)" ]; then
  TRACKERS_DIR="$REPO_TRACKERS"
elif [ -d "$USER_TRACKERS" ] && [ -n "$(find "$USER_TRACKERS" -name "*.md" -print -quit 2>/dev/null)" ]; then
  TRACKERS_DIR="$USER_TRACKERS"
else
  echo "ERROR: No tracker templates found. Re-run the crew-agents install script." >&2
  exit 1
fi

TEMPLATES=$(find "$TRACKERS_DIR" -name "*.md" | sort)
COUNT=$(echo "$TEMPLATES" | grep -c "." || true)

if [ "$COUNT" -eq 1 ]; then
  CHOSEN="$TEMPLATES"
else
  CHOSEN=$(echo "$TEMPLATES" | grep "local" | head -1)
  [ -z "$CHOSEN" ] && CHOSEN=$(echo "$TEMPLATES" | head -1)
fi

mkdir -p "$(dirname "$DEST")"
cp "$CHOSEN" "$DEST"
echo "Tracker configured: $DEST"
