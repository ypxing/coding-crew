#!/usr/bin/env bash
set -uo pipefail

# mark-issue-done.sh — the tracker's `mark-done` operation, for either tracker backend.
#
# Usage:
#   mark-issue-done.sh <issue-file-path | github-issue-number> [--force]
#
# Exit codes:
#   0  issue marked done (or already in done/ — this is idempotent)
#   1  usage error / issue not found / the tracker write failed
#   3  refused: an orchestrator owns the close for this sprint
#   4  refused: acceptance criteria or cross-cutting requirements are still unchecked
#
# A thin wrapper, kept for its callers (close-issue.sh, the ready-for-human steps, old installs'
# issue-tracker.md): both refusals and the done write are `tracker/cli.mjs mark-done`'s, once for
# every backend. This script only finds the CLI and maps its usage exit (2) to its own (1). A
# refusal is the CLI's `REFUSED: <issue> …` line on stderr, saying why and how to proceed.
#
# Why the refusals exist
#   Closing an issue from inside a worker is a work-loss bug, not a style problem. A worker that
#   closes its issue removes it from the `ready-for-agent` list, so the orchestrator's later gates
#   can demote the result to `partial` with nothing left to re-dispatch. The sprint marker
#   `.scratch/<feature-slug>/.orchestrated` (session-init.sh writes it, crew-summary.sh removes it)
#   and `CREW_ORCHESTRATED=1` (set by the dispatchers) are the facts checked; an unchecked `- [ ]`
#   under `## Acceptance criteria` or `## Cross-cutting Requirements` refuses too.
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

# ─── the tracker CLI ─────────────────────────────────────────────────────────
#
# The shared lookup finds (and loads) the tracker-config.sh reader, as in every shell caller;
# the CLI installs beside it (.coding-crew/scripts → .coding-crew/tracker) or sits at the repo
# root in a source checkout (scripts/tracker → tracker). Without MAIN_ROOT the CLI finds the main
# checkout from the cwd itself.
MAIN_ROOT_ARGS=()
[ -n "${MAIN_ROOT:-}" ] && MAIN_ROOT_ARGS=(--main-root "$MAIN_ROOT")
MAIN_ROOT="${MAIN_ROOT:-.}"
# BEGIN tracker-lookup — identical in every caller; tests/tracker-lookup.bats fails if one drifts.
# Where tracker-config.sh (and mark-issue-done.sh beside it) are looked for, first hit wins.
# It cannot live in tracker-config.sh itself: that is the file being looked for.
# Callers break on the first hit, closing the pipe while this may still be writing; where
# SIGPIPE is ignored that write fails with "Broken pipe", so it stops quietly instead.
tracker_config_candidates() {
  local main_root="$1" c
  for c in "${CREW_TRACKER_CONFIG:-}" \
    "${CREW_INSTALL_DIR:+$CREW_INSTALL_DIR/scripts/tracker-config.sh}" \
    "$main_root/.coding-crew/scripts/tracker-config.sh" \
    "$main_root/scripts/tracker/tracker-config.sh" \
    "${HOME:+$HOME/.coding-crew/scripts/tracker-config.sh}"; do
    if [ -n "$c" ]; then printf '%s\n' "$c" 2>/dev/null || return 0; fi
  done
  return 0
}
# END tracker-lookup
TRACKER_CONFIG_FOUND=""
while IFS= read -r _tc; do
  if [ -f "$_tc" ]; then TRACKER_CONFIG_FOUND="$_tc"; break; fi
done < <(tracker_config_candidates "$MAIN_ROOT")
if [ -n "$TRACKER_CONFIG_FOUND" ]; then
  # shellcheck source=/dev/null
  . "$TRACKER_CONFIG_FOUND"
  read_tracker_config "$MAIN_ROOT" || exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKER_CLI=""
for _cli in "${CREW_TRACKER_CLI:-}" \
  "$SCRIPT_DIR/../tracker/cli.mjs" "$SCRIPT_DIR/../../tracker/cli.mjs" \
  "${TRACKER_CONFIG_FOUND:+$(dirname "$TRACKER_CONFIG_FOUND")/../tracker/cli.mjs}" \
  "$MAIN_ROOT/.coding-crew/tracker/cli.mjs" \
  "${HOME:+$HOME/.coding-crew/tracker/cli.mjs}"; do
  if [ -n "$_cli" ] && [ -f "$_cli" ]; then TRACKER_CLI="$_cli"; break; fi
done
if [ -z "$TRACKER_CLI" ]; then
  echo "ERROR: tracker CLI (.coding-crew/tracker/cli.mjs) not found — re-run install.sh" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "ERROR: the tracker CLI needs Node (node not found on PATH)" >&2
  exit 1
fi

FORCE_ARGS=()
[ "$FORCE" -eq 1 ] && FORCE_ARGS=(--force)
node "$TRACKER_CLI" mark-done "$ISSUE_PATH" ${FORCE_ARGS[@]+"${FORCE_ARGS[@]}"} ${MAIN_ROOT_ARGS[@]+"${MAIN_ROOT_ARGS[@]}"}
rc=$?
# The CLI's usage exit (a bad argument, a ref it may not read) is this script's 1.
[ "$rc" -eq 2 ] && exit 1
exit "$rc"
