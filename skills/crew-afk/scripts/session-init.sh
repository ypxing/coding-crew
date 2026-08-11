#!/usr/bin/env bash
set -euo pipefail

# Session initialization and feature branch setup for afk-run
# Usage: source this script or run it directly
# Optional: Pass --jira TICKET-123 or --feature-slug <slug> as arguments

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
  FIRST_ISSUE=$(find .scratch -path '*/issues/open/*.md' -type f | head -n 1)

  if [ -z "$FIRST_ISSUE" ]; then
    echo "No issues found. Create issues in .scratch/<feature-slug>/issues/open/ before running afk-run."
    exit 1
  fi

  # The feature slug is a property of where the issues live, not of the branch name.
  # Deriving it from the branch (which feature-branch-setup.sh names after the first
  # issue) would point sprint state, traces and the PRD lookup at a directory that
  # holds no issues.
  DERIVED_FROM_PATH=$(printf '%s' "$FIRST_ISSUE" | sed 's|^\./||' | sed 's|^\.scratch/||' | sed 's|/.*||')

  # Use shared feature branch setup script (handles branch creation/switching with JIRA support)
  # feature-branch-setup.sh is copied into this skill's scripts/ directory during install.sh
  bash "$(dirname "$0")/feature-branch-setup.sh" "$FIRST_ISSUE" "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
fi

# Get current branch after setup
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Derive feature-slug: use provided value if given, otherwise use the directory the
# issues actually live in. Never derive it from the branch name — see above.
if [ -n "$FEATURE_SLUG_ARG" ]; then
  FEATURE_SLUG="$FEATURE_SLUG_ARG"
else
  FEATURE_SLUG="$DERIVED_FROM_PATH"
fi

# Validate feature-slug is non-empty after stripping
if [ -z "$FEATURE_SLUG" ]; then
  echo "ERROR: Could not derive feature slug from branch name '$CURRENT_BRANCH'"
  exit 1
fi

# Auto-create .scratch/<feature-slug>/issues/open/ directory structure if needed
mkdir -p ".scratch/$FEATURE_SLUG/issues/open"

# Archive previous traces/ dir if present, then create fresh traces/
TS=$(date +%Y%m%dT%H%M%S)
if [ -d ".scratch/$FEATURE_SLUG/traces" ]; then
  mv ".scratch/$FEATURE_SLUG/traces" ".scratch/$FEATURE_SLUG/traces-$TS"
fi
mkdir -p ".scratch/$FEATURE_SLUG/traces"

# Validate git repository
if ! git rev-parse HEAD >/dev/null 2>&1; then
  echo "ERROR: Not in a git repository or HEAD is invalid"
  exit 1
fi

# Check if .scratch is gitignored
if ! git check-ignore -q .scratch 2>/dev/null; then
  echo "WARNING: .scratch/ is not gitignored. Add it to .gitignore to prevent committing design docs and traces."
fi

git rev-parse HEAD > ".scratch/$FEATURE_SLUG/session-start-sha"

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
                  --arg slug "$FEATURE_SLUG" \
                  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                  '.feature_slug = $slug | .branches[$branch] = {base_sha: $sha, created_at: $timestamp}' \
                  > "$STATE_FILE"
else
  # Read existing state, add/update current branch entry
  jq --arg branch "$CURRENT_BRANCH" \
     --arg sha "$BASE_SHA" \
     --arg slug "$FEATURE_SLUG" \
     --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.feature_slug = $slug | .branches[$branch] = {base_sha: $sha, created_at: $timestamp}' \
     "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

# --- sprint.env ---------------------------------------------------------------
# One file the orchestrator sources at the top of every bash block, instead of
# re-deriving the feature slug in prose. The old derivation was
#   jq -r .feature_slug "$(ls -1 .scratch/*/sprint-state.json | head -n1)"
# an alphabetical-first glob that picks the wrong feature in any repo with two sprint
# directories — sitting directly beneath a comment warning "Never re-derive it". The
# slug is known here, exactly once, so it is written here.
MAIN_ROOT=$(git rev-parse --show-toplevel)
SPRINT_ENV="$MAIN_ROOT/.scratch/$FEATURE_SLUG/sprint.env"
cat > "$SPRINT_ENV" <<ENV
# Generated by session-init.sh — source this, never re-derive it.
export MAIN_ROOT="$MAIN_ROOT"
export FEATURE_SLUG="$FEATURE_SLUG"
export FEATURE_BRANCH="$CURRENT_BRANCH"
export SPRINT_DIR="$MAIN_ROOT/.scratch/$FEATURE_SLUG"
export STATE_FILE="$MAIN_ROOT/.scratch/$FEATURE_SLUG/sprint-state.json"
export TRACE_LOG="$MAIN_ROOT/.scratch/$FEATURE_SLUG/traces/orchestrator.log"
export DISPATCH_DIR="$MAIN_ROOT/.scratch/$FEATURE_SLUG/dispatch"
export REVIEW_DIR="$MAIN_ROOT/.scratch/$FEATURE_SLUG/reviews"
export CREW_SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
ENV

# Stable entry point: one path the orchestrator can source without knowing the slug.
cat > "$MAIN_ROOT/.scratch/sprint.env" <<ENV
# Generated by session-init.sh — points at the active sprint's environment.
. "$SPRINT_ENV"
ENV

# --- orchestration marker ------------------------------------------------------
# The one fact that stops a worker closing its own issue. A worker that moves its issue
# to done/ takes it out of the ready-for-agent list, so a later gate that demotes the
# result to `partial` has nothing left to re-dispatch and the unmerged branch is
# orphaned. `.coding-crew/scripts/mark-issue-done.sh` refuses while this file exists;
# crew-summary.sh removes it when the sprint ends.
date -u +%Y-%m-%dT%H:%M:%SZ > "$MAIN_ROOT/.scratch/$FEATURE_SLUG/.orchestrated"

if [ -f "$(dirname "$0")/trace.sh" ]; then
  bash "$(dirname "$0")/trace.sh" --log "$MAIN_ROOT/.scratch/$FEATURE_SLUG/traces/orchestrator.log" \
    SESSION "feature=$FEATURE_SLUG branch=$CURRENT_BRANCH" || true
fi

echo "Session initialized: branch=$CURRENT_BRANCH, feature=$FEATURE_SLUG"
echo "SPRINT_ENV: $SPRINT_ENV"
