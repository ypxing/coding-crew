#!/usr/bin/env bash
set -euo pipefail

# close-issue.sh — close an issue once its own acceptance-criteria receipt exists (receipts.sh):
# Status: done, every criterion ticked, file moved to done/ (github: body ticked, label swapped).
# Usage: close-issue.sh <issue-file-path>          # tracker: local
#        close-issue.sh <issue-number> <branch>    # tracker: github (the receipt is keyed by branch)
# The receipt for this issue's own slug stops a close off a sibling's branch. Ticking happens here,
# after the gate, through the tracker CLI's `tick`, then `mark-done --force` closes: the receipt is
# the re-verification, and the sprint's .orchestrated marker would refuse a plain mark-done.

ISSUE_PATH="${1:-}"

if [ -z "$ISSUE_PATH" ]; then
  echo "Usage: $0 <issue-file-path>" >&2
  exit 1
fi

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

  # Fetched live by the CLI, so a human's edit is kept. A failure only warns: the label swap marks the close.
  node "$TRACKER_CLI" tick "$ISSUE_NUMBER" --main-root "$MAIN_ROOT" >/dev/null \
    || echo "WARNING: could not tick the criteria on issue #$ISSUE_NUMBER" >&2

  # Merged into the feature branch is not shipped: the issue stays open, awaiting-merge, until the
  # PR's Closes keyword.
  node "$TRACKER_CLI" mark-done "$ISSUE_NUMBER" --force --main-root "$MAIN_ROOT" >/dev/null

  _trace CLOSE "issue=$ISSUE_NUMBER"

  echo "Closed: issue #$ISSUE_NUMBER (github: awaiting-merge — the feature PR's Closes #$ISSUE_NUMBER closes it)"
  exit 0
fi

# finalize_issue — every criterion ticked, then Status: done and the move to done/, both the CLI's:
# `mark-done` is the one writer of Status:, and --force because the receipt gate above is the check.
finalize_issue() {
  node "$TRACKER_CLI" tick "$1" --main-root "$MAIN_ROOT" >/dev/null || {
    echo "ERROR: could not tick the criteria in $1" >&2; return 1; }
  node "$TRACKER_CLI" mark-done "$1" --force --main-root "$MAIN_ROOT" >/dev/null || {
    echo "ERROR: could not close $1" >&2; return 1; }
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
FILENAME=$(basename "$ISSUE_PATH")

_trace CLOSE "issue=$FILENAME"

echo "Closed: $FILENAME → $DONE_DIR/$FILENAME"
