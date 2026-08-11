#!/usr/bin/env bash
set -euo pipefail

# close-issue.sh — mechanical issue close: rewrite Status line and move file
#
# Usage: close-issue.sh <issue-file-path>
#
# What it does:
#   1. Validates the issue file exists.
#   2. Requires an acceptance-criteria receipt for *this issue's own slug*
#      (see receipts.sh). Without it the issue is not closed. This is what stops
#      an issue being closed off a sibling issue's verified branch — observed in
#      a real sprint, where one dispatch produced two "merged" issues.
#   3. Rewrites the `Status:` line to `Status: done`.
#   4. Moves the file from .../issues/open/ to .../issues/done/.
#
# What it does NOT do:
#   - Verify acceptance criteria (that is a separate agent step, run pre-merge, before this).
#     This only demands the receipt that step leaves behind.
#   - Any judgment or content analysis.

ISSUE_PATH="${1:-}"

if [ -z "$ISSUE_PATH" ]; then
  echo "Usage: $0 <issue-file-path>" >&2
  exit 1
fi

if [ ! -f "$ISSUE_PATH" ]; then
  # A worker that closed the issue itself, or a re-run of this step, leaves the file
  # in the sibling done/ directory. That is the desired end state, so report it and
  # succeed rather than aborting the orchestrator mid-pipeline. No receipt is
  # demanded here: there is no state left to change, so refusing would only make
  # re-runs fail.
  _open_dir=$(dirname "$ISSUE_PATH")
  _already="$(dirname "$_open_dir")/done/$(basename "$ISSUE_PATH")"
  if [ -f "$_already" ]; then
    TMP_FILE="${_already}.tmp.$$"
    sed 's/^Status: *.*/Status: done/' "$_already" > "$TMP_FILE"
    mv "$TMP_FILE" "$_already"
    echo "Closed: $(basename "$ISSUE_PATH") → $_already (already closed)"
    exit 0
  fi
  echo "ERROR: issue file not found: $ISSUE_PATH" >&2
  exit 1
fi

# Require this issue's own acceptance-criteria receipt before changing anything.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPTS_SCRIPT="$SCRIPT_DIR/receipts.sh"
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null; return 0; }
if [ -f "$RECEIPTS_SCRIPT" ]; then
  bash "$RECEIPTS_SCRIPT" check ac --issue "$ISSUE_PATH"
fi

# Rewrite the Status line. Done via temp file rather than `sed -i` because in-place
# editing is not portable: GNU sed accepts bare `-i`, but BSD/macOS sed reads the
# next argument as a backup suffix and then finds no script. `-i''` does not help —
# the shell strips the empty quotes, so sed still receives a bare `-i`. Writing to a
# temp file and moving it works identically on both platforms.
TMP_FILE="${ISSUE_PATH}.tmp.$$"
sed 's/^Status: *.*/Status: done/' "$ISSUE_PATH" > "$TMP_FILE"
mv "$TMP_FILE" "$ISSUE_PATH"

# Move to sibling done/ directory
OPEN_DIR=$(dirname "$ISSUE_PATH")
DONE_DIR=$(dirname "$OPEN_DIR")/done
mkdir -p "$DONE_DIR"

FILENAME=$(basename "$ISSUE_PATH")
mv "$ISSUE_PATH" "$DONE_DIR/$FILENAME"

_trace CLOSE "issue=$FILENAME"

echo "Closed: $FILENAME → $DONE_DIR/$FILENAME"
