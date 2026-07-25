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

# Rewrite the Status line in-place
sed -i 's/^Status: .*/Status: done/' "$ISSUE_PATH"

# Move to sibling done/ directory
OPEN_DIR=$(dirname "$ISSUE_PATH")
DONE_DIR=$(dirname "$OPEN_DIR")/done
mkdir -p "$DONE_DIR"

FILENAME=$(basename "$ISSUE_PATH")
mv "$ISSUE_PATH" "$DONE_DIR/$FILENAME"

echo "Closed: $FILENAME → $DONE_DIR/$FILENAME"
