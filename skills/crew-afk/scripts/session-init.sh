#!/usr/bin/env bash
set -euo pipefail

# Session initialization and feature branch setup for afk-run
# Usage: source this script or run it directly
# Optional: --feature-slug <slug>, --jira TICKET-123, --branch-prefix <prefix>, --fix-findings <level>

# --fix-findings is the sprint's policy setting (config.json's afk fixFindings, resolved by the
# orchestrator). It is captured here, once, and written into sprint.env — so the step that acts on
# it reads a variable instead of the orchestrator remembering a flag for a whole sprint. --promote
# is its old name, still accepted from a hand run. --prd-audit <value> and --coverage set the
# retired PRD audit: accepted and ignored, with a notice.
#
# --jira <KEY> and --branch-prefix <prefix> (config.json's afk.branchPrefix; "" allowed) name a
# new feature branch: see feature_branch_name below.
FEATURE_SLUG_ARG=""
FIX_FINDINGS_OPT="actionable"
JIRA_KEY=""
BRANCH_PREFIX="feature/"
JIRA_KEY_FORMAT='^[A-Z][A-Z0-9]+-[0-9]+$'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-slug)
      FEATURE_SLUG_ARG="${2:?--feature-slug requires a value}"
      shift 2
      ;;
    --jira)
      JIRA_KEY="${2:-}"
      if [[ ! "$JIRA_KEY" =~ $JIRA_KEY_FORMAT ]]; then
        echo "ERROR: --jira '$JIRA_KEY' is not a Jira key (expected format: PROJ-123, matching $JIRA_KEY_FORMAT)" >&2
        exit 1
      fi
      shift 2
      ;;
    --branch-prefix)
      if [[ $# -lt 2 ]]; then echo "ERROR: --branch-prefix requires a value (\"\" for none)" >&2; exit 1; fi
      BRANCH_PREFIX="$2"
      shift 2
      ;;
    --prd-audit|--coverage)
      echo "session-init: \`$1\` no longer does anything: the feature review checks PRD coverage." >&2
      if [[ "$1" == --prd-audit && $# -gt 1 ]]; then shift 2; else shift; fi
      ;;
    --fix-findings|--promote)
      FIX_FINDINGS_OPT="${2:?$1 requires actionable, critical, high, medium or none}"
      [ "$FIX_FINDINGS_OPT" = "critical-high" ] && FIX_FINDINGS_OPT="high"
      case "$FIX_FINDINGS_OPT" in
        actionable|critical|high|medium|none) ;;
        *) echo "ERROR: $1 must be 'actionable', 'critical', 'high', 'medium' or 'none' (got '$FIX_FINDINGS_OPT')" >&2; exit 1 ;;
      esac
      shift 2
      ;;
    *)
      echo "ERROR: session-init.sh: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# The one place a feature branch is named: `<prefix><KEY>-<slug>`, or `<prefix><slug>` with no
# --jira. Every path that creates, switches to or expects a feature branch calls this, so the
# name cannot drift between them. A name git would refuse stops the run here, before any
# checkout, naming the branch rather than leaving git's own error two steps later.
feature_branch_name() {
  local name="$BRANCH_PREFIX${JIRA_KEY:+$JIRA_KEY-}$1"
  if ! git check-ref-format --branch "$name" >/dev/null 2>&1; then
    echo "ERROR: '$name' is not a valid branch name (git check-ref-format --branch rejects it) — check --branch-prefix / afk.branchPrefix ('$BRANCH_PREFIX')." >&2
    exit 1
  fi
  printf '%s\n' "$name"
}

# --jira only names a branch this run creates; a branch already chosen keeps its name. That name
# is only worth a warning when it is not the one --jira would have built.
warn_jira_ignored() {
  [ -n "$JIRA_KEY" ] || return 0
  local expected
  expected=$(feature_branch_name "$FEATURE_SLUG" 2>/dev/null) || expected=""
  [ "$(git rev-parse --abbrev-ref HEAD)" != "$expected" ] || return 0
  echo "WARNING: --jira $JIRA_KEY ignored: $1" >&2
}

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

# A new feature branch forks from the local default branch; when that is behind origin the
# sprint silently starts from stale code. Warn only (branch is still made from local), after
# a best-effort fetch: no origin, an unreachable one, or any failure stays silent.
warn_if_default_behind_origin() {
  local default
  default=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  [ -z "$default" ] && default="main"
  git remote get-url origin >/dev/null 2>&1 || return 0
  git rev-parse --verify -q "refs/heads/$default" >/dev/null || return 0
  GIT_TERMINAL_PROMPT=0 git fetch -q origin "$default" >/dev/null 2>&1 || return 0
  git rev-parse --verify -q "refs/remotes/origin/$default" >/dev/null || return 0
  local behind
  behind=$(git rev-list --count "refs/heads/$default..refs/remotes/origin/$default" 2>/dev/null || echo 0)
  if [ "${behind:-0}" -gt 0 ] 2>/dev/null; then
    echo "WARNING: local $default is $behind commit(s) behind origin/$default" >&2
    echo "The new feature branch is created from local $default; update $default first to start from current code." >&2
  fi
  return 0
}

# --- tracker config (issue 01) --------------------------------------------------
# Read once, this early, because it changes two things below: whether omitting
# --feature-slug is even allowed, and whether an off-default-branch resume with no
# sprint.env may silently adopt the current branch. Sourced from its fixed install
# location (registry.json's docs.scripts entry), not a path relative to this script,
# since it ships independently of any one skill. An in-between install state (this
# script updated, tracker-config.sh not yet installed) must not break the local
# path, so a missing file falls back to the same "local" defaults the reader itself
# returns when the doc is absent — unless the doc declares `tracker: github`, where
# "local" would be a wrong answer, not a default: it scans .scratch/ for issues that
# live on GitHub and blames their absence on the user.
MAIN_ROOT_FOR_TRACKER=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# BEGIN tracker-lookup — identical in every caller; tests/tracker-lookup.bats fails if one drifts.
# Where tracker-config.sh (and mark-issue-done.sh beside it) are looked for, first hit wins.
# It cannot live in tracker-config.sh itself: that is the file being looked for.
# Callers break on the first hit, closing the pipe while this may still be writing; where
# SIGPIPE is ignored that write fails with "Broken pipe", so it stops quietly instead.
tracker_config_candidates() {
  local main_root="$1" c
  for c in "${CREW_TRACKER_CONFIG:-}" \
    "${CREW_INSTALL_DIR:+$CREW_INSTALL_DIR/scripts/tracker-config.sh}" \
    "$main_root/.coding-crew/scripts/tracker-config.sh" \
    "$main_root/scripts/tracker/tracker-config.sh" \
    "${HOME:+$HOME/.coding-crew/scripts/tracker-config.sh}"; do
    if [ -n "$c" ]; then printf '%s\n' "$c" 2>/dev/null || return 0; fi
  done
  return 0
}
# END tracker-lookup
TRACKER_CONFIG_TRACKER="local"
TRACKER_CONFIG_REPO=""
TRACKER_CONFIG_DOC="$MAIN_ROOT_FOR_TRACKER/.coding-crew/docs/issue-tracker.md"
TRACKER_CONFIG_SCRIPT=""
TRACKER_CONFIG_CHECKED=""
while IFS= read -r _tc; do
  TRACKER_CONFIG_CHECKED="$TRACKER_CONFIG_CHECKED  $_tc"$'\n'
  if [ -f "$_tc" ]; then TRACKER_CONFIG_SCRIPT="$_tc"; break; fi
done < <(tracker_config_candidates "$MAIN_ROOT_FOR_TRACKER")
if [ -n "$TRACKER_CONFIG_SCRIPT" ]; then
  # shellcheck source=/dev/null
  source "$TRACKER_CONFIG_SCRIPT"
  read_tracker_config "$MAIN_ROOT_FOR_TRACKER"
elif [ -f "$TRACKER_CONFIG_DOC" ] &&
  awk 'NR == 1 && $0 != "---" { exit 1 } NR > 1 && $0 == "---" { exit 1 } NR > 1 && /^tracker:[[:space:]]*["'"'"']?github/ { found = 1; exit 0 } END { exit !found }' "$TRACKER_CONFIG_DOC"; then
  echo "ERROR: $TRACKER_CONFIG_DOC declares tracker: github, but tracker-config.sh was not found in any of:" >&2
  printf '%s' "$TRACKER_CONFIG_CHECKED" >&2
  echo "Install coding-crew (install.sh) into this repo or your home directory so the tracker config is honoured." >&2
  exit 1
fi

# Under tracker: github there is nothing local to scan (issues live on GitHub, not
# under .scratch/*/issues/open/), so the local-scan fallback below is not a fallback
# at all there — it would silently pick whatever .scratch/ happens to contain. Require
# the slug explicitly instead of guessing.
if [ "$TRACKER_CONFIG_TRACKER" = "github" ] && [ -z "$FEATURE_SLUG_ARG" ]; then
  echo "ERROR: --feature-slug is required under tracker: github (no local .scratch/ issues to scan for one)." >&2
  echo "Pass --feature-slug <slug> explicitly." >&2
  exit 1
fi

# The feature slug: the one given, else the directory the first ready issue lives in. The slug is
# a property of where the issues live, never of the branch name — deriving it from the branch
# would point sprint state, traces and the PRD lookup at a directory that holds no issues.
if [ -n "$FEATURE_SLUG_ARG" ]; then
  FEATURE_SLUG="$FEATURE_SLUG_ARG"
else
  FIRST_ISSUE=$(find .scratch -path '*/issues/open/*.md' -type f | head -n 1)

  if [ -z "$FIRST_ISSUE" ]; then
    echo "No issues found. Create issues in .scratch/<feature-slug>/issues/open/ before running afk-run."
    exit 1
  fi
  FEATURE_SLUG=$(printf '%s' "$FIRST_ISSUE" | sed 's|^\./||' | sed 's|^\.scratch/||' | sed 's|/.*||')
fi
# Before any branch is named from it: an empty slug would make feature_branch_name blame the prefix.
if [ -z "$FEATURE_SLUG" ]; then
  echo "ERROR: Could not derive the feature slug from the first issue's path '${FIRST_ISSUE:-}'" >&2
  exit 1
fi

if resume_feature_branch "$FEATURE_SLUG"; then
  warn_jira_ignored "sprint '$FEATURE_SLUG' resumes on its recorded branch '$(git rev-parse --abbrev-ref HEAD)'."
else
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  [ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

  if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
    SUGGESTED_BRANCH=$(feature_branch_name "$FEATURE_SLUG")
    if git rev-parse --verify "$SUGGESTED_BRANCH" >/dev/null 2>&1; then
      echo "Switching to existing branch: $SUGGESTED_BRANCH"
      git checkout "$SUGGESTED_BRANCH"
    else
      warn_if_default_behind_origin
      echo "Creating new feature branch: $SUGGESTED_BRANCH"
      git checkout -b "$SUGGESTED_BRANCH"
    fi
  elif [ "$TRACKER_CONFIG_TRACKER" = "github" ]; then
    # Cross-machine resume depends on the branch name being deterministic — off the
    # default branch with no sprint.env to resume from, the only branch a github-
    # tracked sprint may legitimately be on is the one feature_branch_name builds.
    # Anything else is a leftover branch from something unrelated (a prior issue's own
    # branch, a detached HEAD, a colleague's branch), not this sprint continuing.
    EXPECTED_BRANCH=$(feature_branch_name "$FEATURE_SLUG")
    if [ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ]; then
      echo "ERROR: tracker: github requires resuming on branch '$EXPECTED_BRANCH', but the current branch is '$CURRENT_BRANCH' and no .scratch/$FEATURE_SLUG/sprint.env exists to resume from." >&2
      echo "Checkout '$EXPECTED_BRANCH' (or a branch that has a recorded sprint.env), or pass a different --feature-slug." >&2
      exit 1
    fi
  else
    # local tracker (or absent config): off the default branch with no sprint.env
    # silently keeps whatever branch is checked out.
    warn_jira_ignored "keeping the current branch '$CURRENT_BRANCH' (off the default branch, no sprint.env to resume)."
  fi
fi

# Get current branch after setup
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

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
export CREW_FIX_FINDINGS="$FIX_FINDINGS_OPT"
ENV
# The .coding-crew/ this run's assets are read from — resolved once by the orchestrator, which
# exports it before calling this script. A hand run has none, and every script falls back.
if [ -n "${CREW_INSTALL_DIR:-}" ]; then
  echo "export CREW_INSTALL_DIR=\"$CREW_INSTALL_DIR\"" >> "$SPRINT_ENV"
fi

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
