#!/usr/bin/env bash
set -euo pipefail

# Session initialization and feature branch setup for afk-sprint
# Usage: source this script or run it directly
# Optional: Pass --jira TICKET-123 as arguments

# Parse --jira flag from arguments
JIRA_TICKET=""
for arg in "$@"; do
  if [[ "$arg" =~ ^--jira$ ]]; then
    shift
    JIRA_TICKET="$1"
    break
  elif [[ "$arg" =~ ^--jira[[:space:]]+([A-Z]+-[0-9]+)$ ]]; then
    JIRA_TICKET="${BASH_REMATCH[1]}"
    break
  fi
done

# Detect default branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')

# Fallback to "main" if origin/HEAD is not set
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH="main"
fi

# If on default branch, create or switch to feature branch
if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  # Find first ready issue to extract slug for branch naming
  FIRST_ISSUE=$(find .scratch/*/issues/*.md -type f ! -path '*/done/*' -print | head -n 1)
  
  if [ -z "$FIRST_ISSUE" ]; then
    echo "No issues found. Create issues in .scratch/<feature-slug>/issues/ before running afk-sprint."
    exit 1
  fi
  
  # Extract issue slug from filename: strip leading digits and .md extension
  ISSUE_SLUG=$(basename "$FIRST_ISSUE" | sed 's/^[0-9]*-//' | sed 's/\.md$//')
  
  # Build branch name with optional JIRA prefix
  if [ -n "$JIRA_TICKET" ]; then
    SUGGESTED_BRANCH="feature/$JIRA_TICKET-$ISSUE_SLUG"
  else
    SUGGESTED_BRANCH="feature/$ISSUE_SLUG"
  fi
  
  # Check if branch exists: switch if yes, create if no
  if git rev-parse --verify "$SUGGESTED_BRANCH" >/dev/null 2>&1; then
    git checkout "$SUGGESTED_BRANCH"
  else
    git checkout -b "$SUGGESTED_BRANCH"
  fi
  
  # Update current branch after switch/create
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

# Derive feature-slug from current branch name
FEATURE_SLUG="$CURRENT_BRANCH"
# Strip 'feature/' prefix if present
FEATURE_SLUG="${FEATURE_SLUG#feature/}"
# Strip JIRA prefix pattern (e.g., PROJ-123-)
FEATURE_SLUG=$(echo "$FEATURE_SLUG" | sed 's/^[A-Z]\+-[0-9]\+-//')

# Validate feature-slug is non-empty after stripping
if [ -z "$FEATURE_SLUG" ]; then
  echo "ERROR: Could not derive feature slug from branch name '$CURRENT_BRANCH'"
  exit 1
fi

# Auto-create .scratch/<feature-slug>/issues/ directory structure if needed
mkdir -p ".scratch/$FEATURE_SLUG/issues"

# Initialize session tracking
mkdir -p .scratch
TS=$(date +%Y%m%dT%H%M%S)
[ -s .scratch/commands.log ] && mv .scratch/commands.log ".scratch/commands-$TS.log"
touch .scratch/commands.log

# Validate git repository
if ! git rev-parse HEAD >/dev/null 2>&1; then
  echo "ERROR: Not in a git repository or HEAD is invalid"
  exit 1
fi

git rev-parse HEAD > .scratch/.session-start-sha

# Check for jq dependency
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed."
  echo "Install with: apt-get install jq (Debian/Ubuntu) or brew install jq (macOS)"
  exit 1
fi

# Initialize sprint state tracking
STATE_FILE=".scratch/$FEATURE_SLUG/sprint-state.json"
BASE_SHA=$(git rev-parse HEAD)

if [ ! -f "$STATE_FILE" ]; then
  # Create new state file with initial branch entry
  echo "{}" | jq --arg branch "$CURRENT_BRANCH" \
                  --arg sha "$BASE_SHA" \
                  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                  '.branches[$branch] = {base_sha: $sha, created_at: $timestamp}' \
                  > "$STATE_FILE"
else
  # Read existing state, add/update current branch entry
  jq --arg branch "$CURRENT_BRANCH" \
     --arg sha "$BASE_SHA" \
     --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.branches[$branch] = {base_sha: $sha, created_at: $timestamp}' \
     "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

echo "Session initialized: branch=$CURRENT_BRANCH, feature=$FEATURE_SLUG"
