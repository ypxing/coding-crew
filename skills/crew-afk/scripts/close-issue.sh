#!/usr/bin/env bash
set -euo pipefail

# close-issue.sh — mechanical issue close: rewrite Status line and move file
#
# Usage: close-issue.sh <issue-file-path>
#
# What it does:
#   1. Validates the issue file exists.
#   2. Rewrites the `Status:` line to `Status: done`.
#   3. Moves the file from .../issues/open/ to .../issues/done/.
#
# What it does NOT do:
#   - Verify acceptance criteria (that is a separate agent step, run before this).
#   - Any judgment or content analysis.

ISSUE_PATH="${1:-}"

if [ -z "$ISSUE_PATH" ]; then
  echo "Usage: $0 <issue-file-path>" >&2
  exit 1
fi

if [ ! -f "$ISSUE_PATH" ]; then
  echo "ERROR: issue file not found: $ISSUE_PATH" >&2
  exit 1
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

echo "Closed: $FILENAME → $DONE_DIR/$FILENAME"
