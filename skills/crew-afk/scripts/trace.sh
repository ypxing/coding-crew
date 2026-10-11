#!/usr/bin/env bash
set -uo pipefail

# trace.sh — append one line to the sprint's trace log: `<UTC time> INFO  [MARKER] text`, the
# format log.mjs writes (level padded to 5, so `grep -E ' (WARN|ERROR|FATAL) '` finds failures).
# Usage: trace.sh [--log <file>] [--level debug|info|warn|error|fatal] [--feature-slug <slug>] <MARKER> [text ...]
# The log: --log, else $TRACE_LOG, else --feature-slug's. With none, exit 2 — or, under
# CREW_ORCHESTRATED=1 (a dispatched agent's stray call), exit 0 without writing.
# Each step's own script calls this, so a skipped step can never be traced as if it ran.

LOG=""
SLUG=""
LEVEL=info
while [ $# -gt 0 ]; do
  case "$1" in
    --log) LOG="${2:-}"; shift 2 ;;
    --level) LEVEL="${2:-}"; shift 2 ;;
    --feature-slug) SLUG="${2:-}"; shift 2 ;;
    *) break ;;
  esac
done
case "$LEVEL" in
  debug|info|warn|error|fatal) ;;
  *) echo "trace.sh: unknown level: $LEVEL" >&2; exit 1 ;;
esac

MARKER="${1:-}"
[ -n "$MARKER" ] || { echo "trace.sh: a marker is required" >&2; exit 1; }
shift || true

if [ -z "$LOG" ]; then
  LOG="${TRACE_LOG:-}"
fi

if [ -z "$LOG" ] && [ -n "$SLUG" ]; then
  # shellcheck source=main-root.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/main-root.sh"
  root="${MAIN_ROOT:-$(main_root || true)}"
  [ -z "$root" ] || LOG="$root/.scratch/$SLUG/traces/orchestrator.log"
fi

if [ -z "$LOG" ] && [ "${CREW_ORCHESTRATED:-}" != 1 ]; then
  echo "trace.sh: no sprint to trace to — pass --feature-slug <slug> (or --log <file>)" >&2
  exit 2
fi

[ -n "$LOG" ] || exit 0

mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0
printf '%s %-5s [%s]%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$LEVEL" | tr '[:lower:]' '[:upper:]')" \
  "$MARKER" "${*:+ $*}" >> "$LOG" 2>/dev/null || true
exit 0
