#!/usr/bin/env bash
set -uo pipefail

# mark-issue-done.sh — mechanical implementation of the tracker's `mark-done`
# operation for the local-markdown tracker.
#
# Usage:
#   mark-issue-done.sh <issue-file-path> [--force]
#
# Exit codes:
#   0  issue closed (or already in done/ — this is idempotent)
#   1  usage error / issue file not found
#   3  refused: an orchestrator owns the close for this sprint
#   4  refused: acceptance criteria or cross-cutting requirements are still unchecked
#
# Why this exists
#   Closing an issue from inside a worker is a work-loss bug, not a style problem. A
#   worker that moves its issue to done/ removes it from the `ready-for-agent` list, so
#   the orchestrator's later gates (independent checks, acceptance criteria, code review)
#   can demote the result to `partial` with nothing left to re-dispatch — the branch is
#   silently orphaned. Three separate prompts argued about this in prose and a fourth
#   (solve-issue step 7) contradicted them by telling the worker to close. Prose cannot
#   fail closed; this can.
#
#   The sprint marker `.scratch/<feature-slug>/.orchestrated` (written by
#   crew-afk's session-init.sh, removed by crew-summary.sh) is the fact this checks. The
#   `CREW_ORCHESTRATED=1` environment variable set by the dispatchers is honoured too, so
#   a worker dispatched into a worktree is covered even before it locates the sprint dir.
#
#   The criteria guard is the same idea applied to the other half of the operation: the
#   tracker told the model to verify criteria before moving the file, so an unchecked
#   `- [ ]` under `## Acceptance criteria` or `## Cross-cutting Requirements` now refuses
#   the move instead of relying on the model to notice.
#
# Escape hatch
#   --force overrides both refusals. Use it when a sprint crashed and left the marker
#   behind, or when a criterion is deliberately descoped and recorded as such.

FORCE=0
ISSUE_PATH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    -h|--help)
      sed -n '3,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    *)
      if [ -n "$ISSUE_PATH" ]; then echo "ERROR: unexpected argument: $1" >&2; exit 1; fi
      ISSUE_PATH="$1"; shift ;;
  esac
done

if [ -z "$ISSUE_PATH" ]; then
  echo "Usage: $0 <issue-file-path> [--force]" >&2
  exit 1
fi

OPEN_DIR=$(dirname "$ISSUE_PATH")
DONE_DIR="$(dirname "$OPEN_DIR")/done"
FILENAME=$(basename "$ISSUE_PATH")
# .scratch/<feature-slug>/issues/<state>/<file>.md → .scratch/<feature-slug>
SPRINT_DIR=$(dirname "$(dirname "$OPEN_DIR")")

if [ ! -f "$ISSUE_PATH" ]; then
  # Already closed by an earlier run: the end state is what was asked for, so succeed.
  if [ -f "$DONE_DIR/$FILENAME" ]; then
    echo "DONE: $FILENAME already closed ($DONE_DIR/$FILENAME)"
    exit 0
  fi
  echo "ERROR: issue file not found: $ISSUE_PATH" >&2
  exit 1
fi

# ─── guard 1: does an orchestrator own this close? ───────────────────────────
if [ "$FORCE" -eq 0 ]; then
  reason=""
  [ -f "$SPRINT_DIR/.orchestrated" ] && reason="sprint marker $SPRINT_DIR/.orchestrated"
  case "${CREW_ORCHESTRATED:-}" in
    1|true|yes) reason="${reason:-CREW_ORCHESTRATED=${CREW_ORCHESTRATED}}" ;;
  esac
  if [ -n "$reason" ]; then
    echo "REFUSED: $FILENAME is orchestrated ($reason) — the orchestrator closes it." >&2
    echo "  It closes only after independent check verification, acceptance-criteria" >&2
    echo "  verification and code review pass on your branch. Report your status and stop." >&2
    echo "  If no sprint is running: remove $SPRINT_DIR/.orchestrated if it exists, unset" >&2
    echo "  CREW_ORCHESTRATED, or pass --force." >&2
    exit 3
  fi
fi

# ─── guard 2: are all criteria checked off? ──────────────────────────────────
unchecked_criteria() {
  awk '
    /^##+[ \t]*[Aa]cceptance [Cc]riteria/       { inside = 1; next }
    /^##+[ \t]*[Cc]ross-cutting [Rr]equirements/ { inside = 1; next }
    /^##/                                        { inside = 0 }
    inside && /^[ \t]*[-*][ \t]+\[[ ]\]/         { print }
  ' "$1"
}

if [ "$FORCE" -eq 0 ]; then
  UNCHECKED=$(unchecked_criteria "$ISSUE_PATH")
  if [ -n "$UNCHECKED" ]; then
    echo "REFUSED: $FILENAME still has unchecked criteria — not closing it." >&2
    printf '%s\n' "$UNCHECKED" >&2
    echo "  Check each one off once the code satisfies it, or record why it is descoped" >&2
    echo "  under '## Unmet criteria' and re-run with --force." >&2
    exit 4
  fi
fi

# ─── close ───────────────────────────────────────────────────────────────────
# Rewrite via temp file: `sed -i` is not portable (GNU takes a bare -i, BSD/macOS reads
# the next argument as a backup suffix, and `-i''` does not help — the shell strips it).
TMP_FILE="${ISSUE_PATH}.tmp.$$"
sed 's/^Status: *.*/Status: done/' "$ISSUE_PATH" > "$TMP_FILE" || {
  rm -f "$TMP_FILE"; echo "ERROR: could not rewrite Status in $ISSUE_PATH" >&2; exit 1; }
mv "$TMP_FILE" "$ISSUE_PATH"

mkdir -p "$DONE_DIR"
mv "$ISSUE_PATH" "$DONE_DIR/$FILENAME"

echo "DONE: $FILENAME → $DONE_DIR/$FILENAME"
