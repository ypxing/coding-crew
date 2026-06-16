#!/usr/bin/env bash
set -euo pipefail

# Feature branch setup for single-issue workflows
# Usage: feature-branch-setup.sh <issue-path> [--jira TICKET-123]
# Creates or switches to feature branch based on issue slug

ISSUE_PATH="${1:?Issue path required}"
shift

if [ ! -f "$ISSUE_PATH" ]; then
  echo "ERROR: Issue file not found: $ISSUE_PATH" >&2
  exit 1
fi

JIRA_TICKET=""

# Parse optional --jira flag
while [[ $# -gt 0 ]]; do
  case "$1" in
    --jira)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --jira requires a ticket ID" >&2
        exit 1
      fi
      # Validate JIRA ticket format (uppercase letters, dash, digits)
      if [[ ! "$2" =~ ^[A-Z]+-[0-9]+$ ]]; then
        echo "ERROR: Invalid JIRA ticket format: $2 (expected format: PROJ-123)" >&2
        exit 1
      fi
      JIRA_TICKET="$2"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Use PROJECT_ROOT if set, otherwise current directory
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')

# Fallback to "main" if origin/HEAD is not set
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH="main"
fi

if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  # On default branch - need to create or switch to feature branch
  # Extract issue slug from filename: strip leading digits and .md extension
  ISSUE_SLUG=$(basename "$ISSUE_PATH" | sed 's/^[0-9]*-//' | sed 's/\.md$//')
  
  # Build branch name with optional JIRA prefix
  if [ -n "$JIRA_TICKET" ]; then
    SUGGESTED_BRANCH="feature/$JIRA_TICKET-$ISSUE_SLUG"
  else
    SUGGESTED_BRANCH="feature/$ISSUE_SLUG"
  fi
  
  # Check if branch exists: switch if yes, create if no
  if git -C "$PROJECT_ROOT" rev-parse --verify "$SUGGESTED_BRANCH" >/dev/null 2>&1; then
    echo "Switching to existing branch: $SUGGESTED_BRANCH"
    git -C "$PROJECT_ROOT" checkout "$SUGGESTED_BRANCH"
  else
    echo "Creating new feature branch: $SUGGESTED_BRANCH"
    git -C "$PROJECT_ROOT" checkout -b "$SUGGESTED_BRANCH"
  fi
  
  CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
  echo "Now on branch: $CURRENT_BRANCH"
else
  echo "Already on non-default branch: $CURRENT_BRANCH"
fi

exit 0
