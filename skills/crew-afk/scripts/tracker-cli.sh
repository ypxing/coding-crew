#!/usr/bin/env bash
# tracker-cli.sh — finds the tracker CLI (tracker/cli.mjs) and asks it which tracker a repo uses.
#
# Sourced from $SCRIPT_DIR by every crew-afk script that branches on the tracker (close-issue.sh,
# close-shipped.sh, issue-labels.sh, promote-findings.sh, session-init.sh), so the lookup lives
# in one place:
#
#   . "$SCRIPT_DIR/tracker-cli.sh"
#   resolve_tracker_cli "$MAIN_ROOT" || exit 1
#
# Sets TRACKER_CLI (the cli.mjs path) and TRACKER_KIND (local|github), from
# `node "$TRACKER_CLI" config --main-root <main-root>`. Returns non-zero with the reason on stderr
# when no cli.mjs is found, node is missing, or `config` fails (its stderr passes through) — never
# a silent local. tests/tracker-lookup.bats pins the lookup order.
#
# A set $CREW_TRACKER_CLI is the only answer: it names the CLI a test means to run, so a path that
# does not exist is an error rather than a fall-through to whichever copy the search finds next.

# tracker_cli_candidates <main-root> — where cli.mjs is looked for, first existing file wins:
# the .coding-crew/ the orchestrator runs from, the project install, a source checkout, the
# user-level install.
tracker_cli_candidates() {
  local main_root="$1" c
  for c in "${CREW_INSTALL_DIR:+$CREW_INSTALL_DIR/tracker/cli.mjs}" \
    "$main_root/.coding-crew/tracker/cli.mjs" \
    "$main_root/tracker/cli.mjs" \
    "${HOME:+$HOME/.coding-crew/tracker/cli.mjs}"; do
    [ -n "$c" ] && printf '%s\n' "$c"
  done
  return 0
}

resolve_tracker_cli() {
  local main_root="${1:-.}" c out key value
  TRACKER_CLI=""
  TRACKER_KIND=""
  if [ -n "${CREW_TRACKER_CLI:-}" ]; then
    if [ ! -f "$CREW_TRACKER_CLI" ]; then
      echo "ERROR: CREW_TRACKER_CLI=$CREW_TRACKER_CLI does not exist" >&2
      return 1
    fi
    TRACKER_CLI="$CREW_TRACKER_CLI"
  else
    while IFS= read -r c; do
      if [ -f "$c" ]; then TRACKER_CLI="$c"; break; fi
    done <<< "$(tracker_cli_candidates "$main_root")"
  fi
  if [ -z "$TRACKER_CLI" ]; then
    echo "ERROR: tracker CLI (.coding-crew/tracker/cli.mjs) not found — re-run install.sh" >&2
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "ERROR: the tracker CLI needs Node (node not found on PATH) — install Node, then re-run install.sh" >&2
    return 1
  fi
  out="$(node "$TRACKER_CLI" config --main-root "$main_root")" || return 1
  while IFS='=' read -r key value; do
    [ "$key" = tracker ] && TRACKER_KIND="$value"
  done <<< "$out"
  if [ -z "$TRACKER_KIND" ]; then
    echo "ERROR: $TRACKER_CLI config printed no tracker= line — re-run install.sh" >&2
    return 1
  fi
  return 0
}
