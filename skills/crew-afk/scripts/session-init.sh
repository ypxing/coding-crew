#!/usr/bin/env bash
set -euo pipefail

# Session initialization and feature branch setup for afk-run
# Usage: source this script or run it directly
# Optional: Pass --jira TICKET-123 or --feature-slug <slug> as arguments

# Parse --feature-slug flag (consumed here; remaining args forwarded to feature-branch-setup.sh)
#
# --coverage and --promote are the sprint's two policy flags. They are captured here, once,
# where the user's arguments arrive, and written into sprint.env — so the step that acts on
# them reads a variable instead of the orchestrator remembering a flag for a whole sprint.
FEATURE_SLUG_ARG=""
COVERAGE_OPT=0
PROMOTE_OPT="critical"
REMAINING_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-slug)
      FEATURE_SLUG_ARG="${2:?--feature-slug requires a value}"
      shift 2
      ;;
    --coverage)
      COVERAGE_OPT=1
      shift
      ;;
    --promote)
      PROMOTE_OPT="${2:?--promote requires critical or critical-high}"
      case "$PROMOTE_OPT" in
        critical|critical-high) ;;
        *) echo "ERROR: --promote must be 'critical' or 'critical-high' (got '$PROMOTE_OPT')" >&2; exit 1 ;;
      esac
      shift 2
      ;;
    *)
      REMAINING_ARGS+=("$1")
      shift
      ;;
  esac
done

# Resume a prior sprint onto the exact feature branch it started on, before anything
# else runs. Without this, re-running crew-afk from wherever the shell happens to be
# sitting (an issue's own branch left over from a prior round, a detached HEAD, a
# colleague's branch) gets silently adopted as the new "feature branch" the moment it
# isn't the repo's default branch — the FEATURE_SLUG_ARG branch's own default-branch
# heuristic below reads "not on default" as "already on the right one". A slug that
# already has a `.scratch/<slug>/sprint.env` from an earlier session instead pins to
# the FEATURE_BRANCH that file recorded, checking out that branch if the shell isn't
# there yet — deliberately never trusting the current HEAD once a session exists.
# Returns 0 (handled — resumed or already there) or 1 (no prior session; caller keeps
# its own create/switch logic).
resume_feature_branch() {
  local slug="$1"
  local prior_env=".scratch/$slug/sprint.env"
  [ -f "$prior_env" ] || return 1
  local prior_branch
  prior_branch=$(grep -m1 '^export FEATURE_BRANCH=' "$prior_env" | sed -E 's/^export FEATURE_BRANCH="?([^"]*)"?$/\1/')
  [ -n "$prior_branch" ] || return 1
  local now
  now=$(git rev-parse --abbrev-ref HEAD)
  if [ "$now" = "$prior_branch" ]; then
    return 0
  fi
  if ! git rev-parse --verify "$prior_branch" >/dev/null 2>&1; then
    echo "ERROR: sprint '$slug' was started on branch '$prior_branch', but that branch no longer exists." >&2
    echo "Checkout or recreate it before re-running, or pass a different --feature-slug." >&2
    exit 1
  fi
  echo "Resuming sprint '$slug': switching to its feature branch '$prior_branch' (was on '$now')"
  git checkout "$prior_branch"
  return 0
}

if [ -n "$FEATURE_SLUG_ARG" ]; then
  # Use the provided slug directly — bypass first-issue detection
  if resume_feature_branch "$FEATURE_SLUG_ARG"; then
    :
  else
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

  # Same resume guard as the FEATURE_SLUG_ARG branch above: a slug with a recorded
  # session pins to its own feature branch instead of letting feature-branch-setup.sh's
  # default-branch heuristic adopt whatever branch the shell happens to be on.
  if resume_feature_branch "$DERIVED_FROM_PATH"; then
    :
  else
    # Use shared feature branch setup script (handles branch creation/switching with JIRA support)
    # feature-branch-setup.sh is copied into this skill's scripts/ directory during install.sh
    bash "$(dirname "$0")/feature-branch-setup.sh" "$FIRST_ISSUE" "${REMAINING_ARGS[@]+"${REMAINING_ARGS[@]}"}"
  fi
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
export CREW_COVERAGE="$COVERAGE_OPT"
export CREW_PROMOTE="$PROMOTE_OPT"
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
