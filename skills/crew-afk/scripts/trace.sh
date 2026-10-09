#!/usr/bin/env bash
set -uo pipefail

# trace.sh — append one line to the sprint's orchestrator trace log.
#
# Usage:
#   trace.sh [--log <file>] [--level debug|info|warn|error|fatal] <MARKER> [text ...]
#
# Writes: 2026-09-22T04:28:54Z INFO  [MARKER] text
#
# The format orchestrator/lib/log.mjs writes too: level second, padded to 5, so
# `grep -E ' (WARN|ERROR|FATAL) '` finds what went wrong. The level defaults to info; a
# caller that knows its outcome was a failure says so here.
#
# Every crew-afk script that performs a pipeline step calls this itself, so a trace
# marker is emitted by the code that did the work rather than by a prose instruction
# telling the orchestrator to echo it afterwards. A step that ran is therefore always
# traced, and a step that was skipped can never be traced as if it had run.
#
# The log is resolved in this order:
#   1. --log <file>
#   2. $TRACE_LOG
#   3. --feature-slug <slug> → $MAIN_ROOT/.scratch/<slug>/traces/orchestrator.log
#
# There is no repo-wide pointer to a "current" sprint (several run in one repo). With none of
# those, a hand run exits 2 naming --feature-slug; under CREW_ORCHESTRATED=1, which every
# dispatched agent (and so every test suite it runs) inherits along with the live sprint's
# MAIN_ROOT, it exits 0 without writing: the orchestrator hands its own scripts TRACE_LOG
# explicitly, so only a dispatch's stray calls lose it. Tracing is observability — a caller
# that is trying to make progress ignores a failure here.

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
