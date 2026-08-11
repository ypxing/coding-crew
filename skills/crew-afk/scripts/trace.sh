#!/usr/bin/env bash
set -uo pipefail

# trace.sh — append one line to the sprint's orchestrator trace log.
#
# Usage:
#   trace.sh <MARKER> [text ...]
#   trace.sh --log <file> <MARKER> [text ...]
#
# Writes: [HH:MM:SSZ] [MARKER] text
#
# Every crew-afk script that performs a pipeline step calls this itself, so a trace
# marker is emitted by the code that did the work rather than by a prose instruction
# telling the orchestrator to echo it afterwards. A step that ran is therefore always
# traced, and a step that was skipped can never be traced as if it had run.
#
# The log is resolved in this order:
#   1. --log <file>
#   2. $TRACE_LOG
#   3. $MAIN_ROOT/.scratch/sprint.env (or the enclosing repo's) → its TRACE_LOG
#
# If none of those resolve, this exits 0 without writing. Tracing is observability:
# it must never fail the caller that is trying to make progress.

LOG=""
if [ "${1:-}" = "--log" ]; then
  LOG="${2:-}"
  shift 2
fi

MARKER="${1:-}"
[ -n "$MARKER" ] || { echo "trace.sh: a marker is required" >&2; exit 1; }
shift || true

if [ -z "$LOG" ]; then
  LOG="${TRACE_LOG:-}"
fi

if [ -z "$LOG" ]; then
  root="${MAIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
  if [ -n "$root" ] && [ -f "$root/.scratch/sprint.env" ]; then
    # shellcheck disable=SC1091
    . "$root/.scratch/sprint.env" 2>/dev/null || true
    LOG="${TRACE_LOG:-}"
  fi
fi

[ -n "$LOG" ] || exit 0

mkdir -p "$(dirname "$LOG")" 2>/dev/null || exit 0
printf '[%s] [%s]%s\n' "$(date -u +%H:%M:%SZ)" "$MARKER" "${*:+ $*}" >> "$LOG" 2>/dev/null || true
exit 0
