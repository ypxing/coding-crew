#!/usr/bin/env bash
set -euo pipefail

# Squash commits for afk-run
# Usage: squash-commits.sh [--no-squash] [--feature-slug <slug>] [--co-author "<trailer>"] [completed_slug1 completed_slug2 ...]
# --co-author is the commit's trailer line verbatim (the orchestrator passes the coder runtime's);
# without it the commit has none. Completed slugs should be passed as remaining arguments after flags

# Parse arguments
NO_SQUASH=false
COAUTHOR_TRAILER=""
FEATURE_SLUG_ARG=""
COMPLETED_SLUGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-squash)
      NO_SQUASH=true
      shift
      ;;
    --co-author)
      COAUTHOR_TRAILER="${2:-}"
      shift 2
      ;;
    --feature-slug)
      FEATURE_SLUG_ARG="${2:?--feature-slug requires a value}"
      shift 2
      ;;
    -*)
      echo "squash-commits.sh: unknown flag: $1" >&2
      exit 2
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

# Resolve the sprint. Explicit --feature-slug wins, then the FEATURE_SLUG the orchestrator hands
# every child (sprint.childEnv()); there is no glob over .scratch/*/sprint-state.json — several
# sprints run in one repo, and this script reads only its own slug's state. It runs in the feature
# branch's worktree, so the sprint directory is under MAIN_ROOT, not under the cwd.
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

FEATURE_SLUG="${FEATURE_SLUG_ARG:-${FEATURE_SLUG:-}}"
if [ -z "$FEATURE_SLUG" ]; then
  echo "squash-commits.sh: no sprint to squash — pass --feature-slug <slug>" >&2
  exit 2
fi
# shellcheck source=main-root.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/main-root.sh"
MAIN_ROOT="${MAIN_ROOT:-$(main_root)}"
if [ -z "${STATE_FILE:-}" ] || [ "$(basename "$(dirname "${STATE_FILE}")")" != "$FEATURE_SLUG" ]; then
  STATE_FILE="$MAIN_ROOT/.scratch/$FEATURE_SLUG/sprint-state.json"
fi

if [ ! -f "$STATE_FILE" ]; then
  echo "Warning: No sprint state file found. Skipping squash."
  exit 0
fi

BASE_SHA=$(jq -r ".branches[\"$CURRENT_BRANCH\"].base_sha // empty" "$STATE_FILE")

if [ -z "$BASE_SHA" ]; then
  echo "Warning: No base SHA found in state file. Skipping squash."
  exit 0
fi

# If no slugs passed as CLI args, read from sprint-state.json
if [ ${#COMPLETED_SLUGS[@]} -eq 0 ]; then
  while IFS= read -r slug; do
    [ -n "$slug" ] && COMPLETED_SLUGS+=("$slug")
  done < <(jq -r '.completed_slugs[]? // empty' "$STATE_FILE" 2>/dev/null | tr -d '\r')
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
  ISSUE_FILE=$(find "$MAIN_ROOT/.scratch/$FEATURE_SLUG/issues/done" -name "*${slug}.md" -type f 2>/dev/null | head -n 1)
  if [ -n "$ISSUE_FILE" ]; then
    # `grep -v` exits 1 when it filters everything out, which under `set -euo pipefail`
    # would kill the script before the fallback below could run. Guard the pipeline so
    # an issue without a `## What to build` section degrades to the slug instead.
    TITLE=$(sed -n '/## What to build/,/^##/p' "$ISSUE_FILE" | grep -v '^##' | grep -v '^[[:space:]]*$' | head -n1 | sed 's/^[[:space:]]*//' || true)
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
# awk, not sed's \b/\u: those are GNU-only, and BSD sed (macOS) left the label lowercase.
FEATURE_LABEL=$(printf '%s\n' "$FEATURE_SLUG" | awk -F- '{ for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2) } 1' OFS=' ')
ISSUE_COUNT=${#ISSUE_TITLES[@]}
if [ $ISSUE_COUNT -eq 1 ]; then
  SUMMARY_LINE="$FEATURE_LABEL: ${ISSUE_TITLES[0]}"
else
  SUMMARY_LINE="$FEATURE_LABEL: ${ISSUE_TITLES[0]} (+$((ISSUE_COUNT - 1)) more)"
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

# Perform squash using reset + commit. The two steps are not atomic: a commit refused by
# a hook (commit-msg, pre-commit) or by signing would otherwise leave the branch reset to
# BASE_SHA with every merged issue's work only staged, so a failed commit puts the tip back.
ORIG_TIP=$(git rev-parse HEAD)
git reset --soft "$BASE_SHA"

# Create squashed commit with safe message handling: the message goes in on stdin, never through
# a shell-expanded argument. The trailer, when given, is the last paragraph.
MESSAGE="$SUMMARY_LINE

$ISSUE_BULLETS"
[ -n "$COAUTHOR_TRAILER" ] && MESSAGE="$MESSAGE
$COAUTHOR_TRAILER"
if ! printf '%s\n' "$MESSAGE" | git commit -F -
then
  git reset --soft "$ORIG_TIP"
  echo "ERROR: squash commit failed; branch restored to $ORIG_TIP, unsquashed." >&2
  exit 1
fi

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

_TRACE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trace.sh"
[ -f "$_TRACE_SCRIPT" ] && bash "$_TRACE_SCRIPT" SQUASH "commits=$COMMIT_COUNT issues=${#COMPLETED_SLUGS[@]}" 2>/dev/null || true
echo "Squashed $COMMIT_COUNT commits into 1."
