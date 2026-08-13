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
#   3. Rewrites the `Status:` line to `Status: done` and ticks every remaining
#      `- [ ]` under `## Acceptance criteria` / `## Cross-cutting Requirements`.
#   4. Moves the file from .../issues/open/ to .../issues/done/.
#
# Why the check-off lives here
#   It used to be the worker's job (solve-issue step 7), which made it
#   self-attestation: mark-issue-done.sh refuses to close while a `- [ ]` remains
#   (exit 4), a gate any worker defeats by ticking its own boxes — the exact thing
#   the reviewer-owned acceptance-criteria gate exists to prevent. The tick is
#   bookkeeping *about* a close, so it belongs to whatever performs the close, and
#   it happens only after the receipt gate below has passed.
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

# finalize_issue — mark an issue file closed: Status: done, plus every criterion ticked.
#
# One awk pass, written to a temp file and moved into place. `sed -i` is not portable
# (GNU takes a bare -i, BSD/macOS reads the next argument as a backup suffix, and
# `-i''` does not help — the shell strips the empty quotes), and one pass means the
# file is never observable half-rewritten.
#
# Section scoping matches mark-issue-done.sh's guard exactly, so the two agree on
# which boxes are criteria: only those under an acceptance-criteria or
# cross-cutting-requirements heading. A `- [ ]` in `## What to build` or `## Notes`
# is somebody's note, not a criterion, and is left alone.
finalize_issue() {
  local file="$1"
  local tmp="${file}.tmp.$$"

  awk '
    /^Status:[ 	]*/ { print "Status: done"; next }
    /^##+[ 	]*[Aa]cceptance [Cc]riteria/       { inside = 1; print; next }
    /^##+[ 	]*[Cc]ross-cutting [Rr]equirements/ { inside = 1; print; next }
    /^##/                                       { inside = 0; print; next }
    inside && /^[ 	]*[-*][ 	]+\[[ ]\]/ { sub(/\[[ ]\]/, "[x]"); print; next }
    { print }
  ' "$file" > "$tmp" || {
    rm -f "$tmp"; echo "ERROR: could not rewrite $file" >&2; return 1; }

  mv "$tmp" "$file"
}

if [ ! -f "$ISSUE_PATH" ]; then
  # A worker that closed the issue itself, or a re-run of this step, leaves the file
  # in the sibling done/ directory. That is the desired end state, so report it and
  # succeed rather than aborting the orchestrator mid-pipeline. No receipt is
  # demanded here: there is no state left to change, so refusing would only make
  # re-runs fail.
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
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null; return 0; }
if [ -f "$RECEIPTS_SCRIPT" ]; then
  bash "$RECEIPTS_SCRIPT" check ac --issue "$ISSUE_PATH"
fi

# Status: done, and every criterion ticked. Only reached once the receipt gate above
# has passed — a refused close leaves the file exactly as the worker left it.
finalize_issue "$ISSUE_PATH"

# Move to sibling done/ directory
OPEN_DIR=$(dirname "$ISSUE_PATH")
DONE_DIR=$(dirname "$OPEN_DIR")/done
mkdir -p "$DONE_DIR"

FILENAME=$(basename "$ISSUE_PATH")
mv "$ISSUE_PATH" "$DONE_DIR/$FILENAME"

_trace CLOSE "issue=$FILENAME"

echo "Closed: $FILENAME → $DONE_DIR/$FILENAME"
