#!/usr/bin/env bash
set -euo pipefail

# Session initialization and feature branch setup for afk-run
# Usage: source this script or run it directly
# Optional: Pass --jira TICKET-123 or --feature-slug <slug> as arguments

# Auto-detect platform directory
if [ -d ".claude" ]; then
  PLATFORM_DIR=".claude"
elif [ -d ".copilot" ]; then
  PLATFORM_DIR=".copilot"
else
  echo "Error: No .claude or .copilot directory found" >&2
  exit 1
fi

# Parse --feature-slug flag (consumed here; remaining args forwarded to feature-branch-setup.sh)
FEATURE_SLUG_ARG=""
REMAINING_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-slug)
      FEATURE_SLUG_ARG="${2:?--feature-slug requires a value}"
      shift 2
      ;;
    *)
      REMAINING_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ -n "$FEATURE_SLUG_ARG" ]; then
  # Use the provided slug directly — bypass first-issue detection
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  [ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

  if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
    SUGGESTED_BRANCH="feature/$FEATURE_SLUG_ARG"
    if git rev-parse --verify "$SUGGESTED_BRANCH" >/dev/null 2>&1; then
      echo "Switching to existing branch: $SUGGESTED_BRANCH"
      git checkout "$SUGGESTED_BRANCH"
    else
      echo "Creating new feature branch: $SUGGESTED_BRANCH"
      git checkout -b "$SUGGESTED_BRANCH"
    fi
  fi
else
  # Find first ready issue to determine branch name
  FIRST_ISSUE=$(find .scratch -path '*/issues/*.md' -not -path '*/done/*' -type f | head -n 1)

  if [ -z "$FIRST_ISSUE" ]; then
    echo "No issues found. Create issues in .scratch/<feature-slug>/issues/ before running afk-run."
    exit 1
  fi

  # Use shared feature branch setup script (handles branch creation/switching with JIRA support)
  # feature-branch-setup.sh is copied into this skill's scripts/ directory during install.sh
  bash "$(dirname "$0")/feature-branch-setup.sh" "$FIRST_ISSUE" "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
fi

# Get current branch after setup
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Derive feature-slug: use provided value if given, otherwise derive from branch name
if [ -n "$FEATURE_SLUG_ARG" ]; then
  FEATURE_SLUG="$FEATURE_SLUG_ARG"
else
  FEATURE_SLUG="$CURRENT_BRANCH"
  # Strip 'feature/' prefix if present
  FEATURE_SLUG="${FEATURE_SLUG#feature/}"
  # Strip JIRA prefix pattern (e.g., PROJ-123-)
  FEATURE_SLUG=$(echo "$FEATURE_SLUG" | sed -E 's/^[A-Z]+-[0-9]+-//')
fi

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
