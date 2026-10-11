#!/usr/bin/env bash
set -euo pipefail

# close-issue.sh — close an issue once its own acceptance-criteria receipt exists (receipts.sh):
# Status: done, every criterion ticked, file moved to done/ (github: body ticked, label swapped).
# Usage: close-issue.sh <issue-file-path>          # tracker: local
#        close-issue.sh <issue-number> <branch>    # tracker: github (the receipt is keyed by branch)
# The receipt for this issue's own slug stops a close off a sibling's branch. Ticking lives here,
# after the gate, because a worker ticking its own boxes would defeat mark-done's guard.

ISSUE_PATH="${1:-}"

if [ -z "$ISSUE_PATH" ]; then
  echo "Usage: $0 <issue-file-path>" >&2
  exit 1
fi

# tick_criteria [status] — stdin → stdout: `- [ ]` under Acceptance criteria / Cross-cutting
# Requirements (mark-done's own scoping) becomes `- [x]`; with a status, the Status: line too.
tick_criteria() {
  awk -v status="${1:-}" '
    status != "" && /^Status:[ 	]*/            { print "Status: " status; next }
    /^##+[ 	]*[Aa]cceptance [Cc]riteria/       { inside = 1; print; next }
    /^##+[ 	]*[Cc]ross-cutting [Rr]equirements/ { inside = 1; print; next }
    /^##/                                       { inside = 0; print; next }
    inside && /^[ 	]*[-*][ 	]+\[[ ]\]/ { sub(/\[[ ]\]/, "[x]"); print; next }
    { print }
  '
}

# No CLI, no node or an invalid config is an error, never a silent local.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_ROOT="${MAIN_ROOT:-.}"
# shellcheck source=tracker-cli.sh
. "$SCRIPT_DIR/tracker-cli.sh"
resolve_tracker_cli "$MAIN_ROOT" || exit 1

if [ "$TRACKER_KIND" = "github" ]; then
  # The argument is an issue number here; the same ac-receipt gate applies.
  ISSUE_NUMBER="$ISSUE_PATH"
  case "$ISSUE_NUMBER" in
    ''|*[!0-9]*)
      echo "ERROR: expected a GitHub issue number under tracker: github, got: $ISSUE_NUMBER" >&2
      exit 1 ;;
  esac

  RECEIPTS_SCRIPT="$SCRIPT_DIR/receipts.sh"
  _trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" ${FEATURE_SLUG:+--feature-slug "$FEATURE_SLUG"} "$@" 2>/dev/null || true; return 0; }
  # Mirrors CREW_RECEIPTS=off, so a missing branch arg is no error when no check will run.
  if [ -f "$RECEIPTS_SCRIPT" ] && [ "${CREW_RECEIPTS:-on}" != "off" ]; then
    # The branch is what both the receipt write and this check split into feature/slug.
    BRANCH_ARG="${2:-}"
    if [ -z "$BRANCH_ARG" ]; then
      echo "ERROR: tracker: github requires the branch as a second argument: $0 <issue-number> <branch>" >&2
      exit 1
    fi
    bash "$RECEIPTS_SCRIPT" check ac --branch "$BRANCH_ARG"
  fi

  # Fetched live, so a human's edit is kept. A failure only warns: the label swap marks the close.
  if BODY="$(gh issue view "$ISSUE_NUMBER" --json body --jq .body)"; then
    TICKED="$(printf '%s\n' "$BODY" | tick_criteria)"
    if [ "$TICKED" != "$BODY" ]; then
      BODY_FILE="$(mktemp)"
      printf '%s\n' "$TICKED" > "$BODY_FILE"
      gh issue edit "$ISSUE_NUMBER" --body-file "$BODY_FILE" >/dev/null \
        || echo "WARNING: could not tick the criteria on issue #$ISSUE_NUMBER" >&2
      rm -f "$BODY_FILE"
    fi
  else
    echo "WARNING: could not fetch issue #$ISSUE_NUMBER to tick its criteria" >&2
  fi

  # Merged into the feature branch is not shipped: the issue stays open, awaiting-merge, until the
  # PR's Closes keyword. --force: the receipt is the re-verification, and .orchestrated would refuse.
  node "$TRACKER_CLI" mark-done "$ISSUE_NUMBER" --force --main-root "$MAIN_ROOT" >/dev/null

  _trace CLOSE "issue=$ISSUE_NUMBER"

  echo "Closed: issue #$ISSUE_NUMBER (github: awaiting-merge — the feature PR's Closes #$ISSUE_NUMBER closes it)"
  exit 0
fi


# finalize_issue — Status: done plus every criterion ticked, in one awk pass to a temp file: `sed -i`
# is not portable, and the file is never observable half-rewritten.
finalize_issue() {
  local file="$1"
  local tmp="${file}.tmp.$$"

  tick_criteria done < "$file" > "$tmp" || {
    rm -f "$tmp"; echo "ERROR: could not rewrite $file" >&2; return 1; }

  mv "$tmp" "$file"
}

if [ ! -f "$ISSUE_PATH" ]; then
  # Already in done/ (a re-run): the desired end state, so succeed. No receipt is demanded, as there
  # is no state left to change.
  _open_dir=$(dirname "$ISSUE_PATH")
  _already="$(dirname "$_open_dir")/done/$(basename "$ISSUE_PATH")"
  if [ -f "$_already" ]; then
    finalize_issue "$_already"
    echo "Closed: $(basename "$ISSUE_PATH") → $_already (already closed)"
    exit 0
  fi
  echo "ERROR: issue file not found: $ISSUE_PATH" >&2
  exit 1
fi

# Require this issue's own acceptance-criteria receipt before changing anything.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPTS_SCRIPT="$SCRIPT_DIR/receipts.sh"
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" ${FEATURE_SLUG:+--feature-slug "$FEATURE_SLUG"} "$@" 2>/dev/null || true; return 0; }
if [ -f "$RECEIPTS_SCRIPT" ]; then
  bash "$RECEIPTS_SCRIPT" check ac --issue "$ISSUE_PATH"
fi

# Only reached past the receipt gate: a refused close leaves the file as the worker left it.
finalize_issue "$ISSUE_PATH"

OPEN_DIR=$(dirname "$ISSUE_PATH")
DONE_DIR=$(dirname "$OPEN_DIR")/done
mkdir -p "$DONE_DIR"

FILENAME=$(basename "$ISSUE_PATH")
mv "$ISSUE_PATH" "$DONE_DIR/$FILENAME"

_trace CLOSE "issue=$FILENAME"

echo "Closed: $FILENAME → $DONE_DIR/$FILENAME"
