#!/usr/bin/env bash
set -euo pipefail

# session-init.sh — name the sprint's feature branch (creating the ref if new) and write sprint.env.
# Usage: session-init.sh [--feature-slug <slug>] [--jira <KEY>] [--branch-prefix <prefix>]
#          [--fix-findings <level>] [--print-branch]   (print the slug and branches, touch nothing)
# Never checks a branch out: the orchestrator keeps the feature branch in its `_feature` worktree.
# --promote is an alias of --fix-findings; --prd-audit and --coverage are accepted and ignored.
FEATURE_SLUG_ARG=""
FIX_FINDINGS_OPT="actionable"
JIRA_KEY=""
PRINT_BRANCH=0
BRANCH_PREFIX="feature/"
JIRA_KEY_FORMAT='^[A-Z][A-Z0-9]+-[0-9]+$'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-slug)
      FEATURE_SLUG_ARG="${2:?--feature-slug requires a value}"
      shift 2
      ;;
    --print-branch)
      PRINT_BRANCH=1
      shift
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

# The one place a feature branch is named, so the name cannot drift between callers. A name git
# would refuse stops the run here, naming the branch.
feature_branch_name() {
  local name="$BRANCH_PREFIX${JIRA_KEY:+$JIRA_KEY-}$1"
  if ! git check-ref-format --branch "$name" >/dev/null 2>&1; then
    echo "ERROR: '$name' is not a valid branch name (git check-ref-format --branch rejects it) — check --branch-prefix / afk.branchPrefix ('$BRANCH_PREFIX')." >&2
    exit 1
  fi
  printf '%s\n' "$name"
}

# --jira only names a new branch; warn only when the kept name is not the one it would build.
warn_jira_ignored() {
  [ -n "$JIRA_KEY" ] || return 0
  local expected
  expected=$(feature_branch_name "$FEATURE_SLUG" 2>/dev/null) || expected=""
  [ "$FEATURE_BRANCH" != "$expected" ] || return 0
  echo "WARNING: --jira $JIRA_KEY ignored: $1" >&2
}

# A slug with a prior sprint.env pins to the FEATURE_BRANCH it recorded, never to whatever the main
# checkout is on. Prints nothing when there is no prior session.
recorded_feature_branch() {
  local prior_env="$MAIN_ROOT/.scratch/$1/sprint.env"
  [ -f "$prior_env" ] || return 0
  grep -m1 '^export FEATURE_BRANCH=' "$prior_env" | sed -E 's/^export FEATURE_BRANCH="?([^"]*)"?$/\1/'
}

# A new feature branch forks from the local default branch: warn (only) when origin is ahead, after
# a best-effort fetch; any failure stays silent.
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

# Read early: under github, a missing CLI or node or an invalid config must stop here rather than
# scan .scratch/ for issues that live on GitHub.
# shellcheck source=main-root.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/main-root.sh"
MAIN_ROOT="${MAIN_ROOT:-$(main_root || pwd)}"
# shellcheck source=tracker-cli.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tracker-cli.sh"
resolve_tracker_cli "$MAIN_ROOT" || exit 1

# Under github there is no local issue to derive the slug from: require it.
if [ "$TRACKER_KIND" = "github" ] && [ -z "$FEATURE_SLUG_ARG" ]; then
  echo "ERROR: --feature-slug is required under tracker: github (no local .scratch/ issues to scan for one)." >&2
  echo "Pass --feature-slug <slug> explicitly." >&2
  exit 1
fi

# The slug is where the issues live, never derived from the branch name: that would point sprint
# state, traces and the PRD lookup at a directory with no issues.
if [ -n "$FEATURE_SLUG_ARG" ]; then
  FEATURE_SLUG="$FEATURE_SLUG_ARG"
else
  FIRST_ISSUE=$(find "$MAIN_ROOT/.scratch" -path '*/issues/open/*.md' -type f | head -n 1)

  if [ -z "$FIRST_ISSUE" ]; then
    echo "No issues found. Create issues in .scratch/<feature-slug>/issues/open/ before running afk-run."
    exit 1
  fi
  FEATURE_SLUG=$(printf '%s' "${FIRST_ISSUE#"$MAIN_ROOT"/.scratch/}" | sed 's|/.*||')
fi
# Before any branch is named from it: an empty slug would make feature_branch_name blame the prefix.
if [ -z "$FEATURE_SLUG" ]; then
  echo "ERROR: Could not derive the feature slug from the first issue's path '${FIRST_ISSUE:-}'" >&2
  exit 1
fi

DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="main"

FEATURE_BRANCH=$(recorded_feature_branch "$FEATURE_SLUG")
if [ -n "$FEATURE_BRANCH" ]; then
  warn_jira_ignored "sprint '$FEATURE_SLUG' resumes on its recorded branch '$FEATURE_BRANCH'."
else
  FEATURE_BRANCH=$(feature_branch_name "$FEATURE_SLUG")
fi

if [ "$PRINT_BRANCH" = 1 ]; then
  printf 'FEATURE_SLUG=%s\nFEATURE_BRANCH=%s\nDEFAULT_BRANCH=%s\n' "$FEATURE_SLUG" "$FEATURE_BRANCH" "$DEFAULT_BRANCH"
  exit 0
fi

# The branch is a ref, not a checkout: the orchestrator's `_feature` worktree has normally made it
# already; a hand run creates it here, from the default branch (else where the main checkout is).
if git rev-parse --verify -q "refs/heads/$FEATURE_BRANCH" >/dev/null; then
  echo "Using existing branch: $FEATURE_BRANCH"
else
  if [ -n "$(recorded_feature_branch "$FEATURE_SLUG")" ]; then
    echo "ERROR: sprint '$FEATURE_SLUG' was started on branch '$FEATURE_BRANCH', but that branch no longer exists." >&2
    echo "Recreate it before re-running, or pass a different --feature-slug." >&2
    exit 1
  fi
  warn_if_default_behind_origin
  BASE_REF="refs/heads/$DEFAULT_BRANCH"
  git rev-parse --verify -q "$BASE_REF" >/dev/null || BASE_REF="HEAD"
  echo "Creating new feature branch: $FEATURE_BRANCH"
  git branch "$FEATURE_BRANCH" "$BASE_REF"
fi
CURRENT_BRANCH="$FEATURE_BRANCH"

mkdir -p "$MAIN_ROOT/.scratch/$FEATURE_SLUG/issues/open"

TS=$(date +%Y%m%dT%H%M%S)
if [ -d "$MAIN_ROOT/.scratch/$FEATURE_SLUG/traces" ]; then
  mv "$MAIN_ROOT/.scratch/$FEATURE_SLUG/traces" "$MAIN_ROOT/.scratch/$FEATURE_SLUG/traces-$TS"
fi
mkdir -p "$MAIN_ROOT/.scratch/$FEATURE_SLUG/traces"

if ! git rev-parse "refs/heads/$FEATURE_BRANCH" >/dev/null 2>&1; then
  echo "ERROR: Not in a git repository or HEAD is invalid"
  exit 1
fi

if ! git -C "$MAIN_ROOT" check-ignore -q .scratch 2>/dev/null; then
  echo "WARNING: .scratch/ is not gitignored. Add it to .gitignore to prevent committing design docs and traces."
fi

git rev-parse "refs/heads/$FEATURE_BRANCH" > "$MAIN_ROOT/.scratch/$FEATURE_SLUG/session-start-sha"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed."
  echo "Install with: apt-get install jq (Debian/Ubuntu) or brew install jq (macOS)"
  exit 1
fi

STATE_FILE="$MAIN_ROOT/.scratch/$FEATURE_SLUG/sprint-state.json"
BASE_SHA=$(git rev-parse "refs/heads/$FEATURE_BRANCH")

if [ ! -f "$STATE_FILE" ]; then
  echo "{}" | jq --arg branch "$CURRENT_BRANCH" \
                  --arg sha "$BASE_SHA" \
                  --arg slug "$FEATURE_SLUG" \
                  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                  '.feature_slug = $slug | .branches[$branch] = {base_sha: $sha, created_at: $timestamp}' \
                  > "$STATE_FILE"
else
  jq --arg branch "$CURRENT_BRANCH" \
     --arg sha "$BASE_SHA" \
     --arg slug "$FEATURE_SLUG" \
     --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     '.feature_slug = $slug | .branches[$branch] = {base_sha: $sha, created_at: $timestamp}' \
     "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
fi

# The sprint's own environment, handed to every child. No repo-wide pointer to "the" sprint
# exists: several sprints share a repo.
SPRINT_ENV="$MAIN_ROOT/.scratch/$FEATURE_SLUG/sprint.env"
cat > "$SPRINT_ENV" <<ENV
# Generated by session-init.sh — source this, never re-derive it.
export MAIN_ROOT="$MAIN_ROOT"
export FEATURE_SLUG="$FEATURE_SLUG"
export FEATURE_BRANCH="$FEATURE_BRANCH"
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

# A worker that moves its own issue to done/ orphans a branch a later gate demotes to partial;
# mark-done refuses while this marker exists, and crew-summary.sh removes it at sprint end.
date -u +%Y-%m-%dT%H:%M:%SZ > "$MAIN_ROOT/.scratch/$FEATURE_SLUG/.orchestrated"

if [ -f "$(dirname "$0")/trace.sh" ]; then
  bash "$(dirname "$0")/trace.sh" --log "$MAIN_ROOT/.scratch/$FEATURE_SLUG/traces/orchestrator.log" \
    SESSION "feature=$FEATURE_SLUG branch=$CURRENT_BRANCH" || true
fi

echo "Session initialized: branch=$CURRENT_BRANCH, feature=$FEATURE_SLUG"
echo "SPRINT_ENV: $SPRINT_ENV"
