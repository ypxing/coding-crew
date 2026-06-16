#!/usr/bin/env bash
set -euo pipefail

# Squash commits for afk-run
# Usage: squash-commits.sh [--no-squash] [--platform claude|copilot] [completed_slug1 completed_slug2 ...]
# Completed slugs should be passed as remaining arguments after flags

# Parse arguments
NO_SQUASH=false
PLATFORM="claude"
COMPLETED_SLUGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-squash)
      NO_SQUASH=true
      shift
      ;;
    --platform)
      PLATFORM="$2"
      shift 2
      ;;
    *)
      COMPLETED_SLUGS+=("$1")
      shift
      ;;
  esac
done

if [ "$NO_SQUASH" = true ]; then
  echo "Skipping squash (--no-squash flag present)"
  exit 0
fi

# Derive feature-slug from current branch name
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
FEATURE_SLUG="$CURRENT_BRANCH"
# Strip 'feature/' prefix if present
FEATURE_SLUG="${FEATURE_SLUG#feature/}"
# Strip JIRA prefix pattern (e.g., PROJ-123-)
FEATURE_SLUG=$(echo "$FEATURE_SLUG" | sed 's/^[A-Z]\+-[0-9]\+-//')

STATE_FILE=".scratch/$FEATURE_SLUG/sprint-state.json"

if [ ! -f "$STATE_FILE" ]; then
  echo "Warning: No sprint state file found. Skipping squash."
  exit 0
fi

BASE_SHA=$(jq -r ".branches[\"$CURRENT_BRANCH\"].base_sha // empty" "$STATE_FILE")

if [ -z "$BASE_SHA" ]; then
  echo "Warning: No base SHA found in state file. Skipping squash."
  exit 0
fi

# Check if there are completed issues
if [ ${#COMPLETED_SLUGS[@]} -eq 0 ]; then
  echo "No completed issues to squash."
  exit 0
fi

# Build bulleted issue list and collect titles from completed slugs
ISSUE_BULLETS=""
ISSUE_TITLES=()
for slug in "${COMPLETED_SLUGS[@]}"; do
  ISSUE_FILE=$(find .scratch/*/issues/done -name "*${slug}.md" -type f 2>/dev/null | head -n 1)
  if [ -n "$ISSUE_FILE" ]; then
    TITLE=$(sed -n '/## What to build/,/^##/p' "$ISSUE_FILE" | grep -v '^##' | grep -v '^[[:space:]]*$' | head -n1 | sed 's/^[[:space:]]*//')
    if [ -z "$TITLE" ]; then
      TITLE=$(echo "$slug" | sed 's/^[0-9]*-//' | tr '-' ' ')
    fi
  else
    TITLE=$(echo "$slug" | sed 's/^[0-9]*-//' | tr '-' ' ')
  fi
  ISSUE_TITLES+=("$TITLE")
  ISSUE_BULLETS="${ISSUE_BULLETS}- ${TITLE}
"
done

# Summary: "Feature Name: first issue title (+N more)"
FEATURE_LABEL=$(echo "$FEATURE_SLUG" | tr '-' ' ' | sed 's/\b\(.\)/\u\1/g')
ISSUE_COUNT=${#ISSUE_TITLES[@]}
if [ $ISSUE_COUNT -eq 1 ]; then
  SUMMARY_LINE="$FEATURE_LABEL: ${ISSUE_TITLES[0]}"
else
  SUMMARY_LINE="$FEATURE_LABEL: ${ISSUE_TITLES[0]} (+$((ISSUE_COUNT - 1)) more)"
fi

# Co-authored-by trailer (platform-appropriate)
if [ "$PLATFORM" = "claude" ]; then
  COAUTHOR_TRAILER="Co-authored-by: Claude Code <claude@anthropic.com>"
else
  COAUTHOR_TRAILER="Co-authored-by: GitHub Copilot <noreply@github.com>"
fi

# Verify there are commits to squash
COMMIT_COUNT=$(git rev-list ${BASE_SHA}..HEAD --count)

if [ "$COMMIT_COUNT" -eq 0 ]; then
  echo "No commits to squash."
  exit 0
fi

# Validate BASE_SHA is an ancestor of HEAD
if ! git merge-base --is-ancestor "$BASE_SHA" HEAD 2>/dev/null; then
  echo "ERROR: Base SHA $BASE_SHA is not an ancestor of HEAD."
  echo "State file may be corrupted or wrong branch. Manual fix needed."
  exit 1
fi

# Perform squash using reset + commit
git reset --soft "$BASE_SHA"

# Create squashed commit with safe message handling
# Use git commit -F with here-doc for safe literal interpolation
git commit -F - << EOF
$SUMMARY_LINE

$ISSUE_BULLETS
$COAUTHOR_TRAILER
EOF

# Update state file with new HEAD SHA
NEW_HEAD=$(git rev-parse HEAD)
if jq --arg branch "$CURRENT_BRANCH" \
      --arg sha "$NEW_HEAD" \
      '.branches[$branch].base_sha = $sha' \
      "$STATE_FILE" > "$STATE_FILE.tmp"; then
  mv "$STATE_FILE.tmp" "$STATE_FILE"
else
  echo "Warning: Failed to update state file with new base SHA."
  rm -f "$STATE_FILE.tmp"
fi

echo "Squashed $COMMIT_COUNT commits into 1."
