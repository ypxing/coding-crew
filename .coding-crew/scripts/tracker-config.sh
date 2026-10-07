#!/usr/bin/env bash
# tracker-config.sh — reads which issue-tracker backend a repo uses.
#
# The answer is tracker/tracker-config.mjs's readTrackerConfig(mainRoot) — the repo's
# .coding-crew/config.json `tracker` section, else the legacy .coding-crew/docs/issue-tracker.md
# front matter, else local — asked through `node cli.mjs config`, so there is one reader.
#
# Usage:
#   source this script, then call: read_tracker_config [<main-root>]
#     Sets TRACKER_CONFIG_TRACKER (local|github) and TRACKER_CONFIG_CONFIGURED (yes|no).
#     Returns non-zero, with the reason on stderr, when the config is invalid or the
#     tracker CLI or node cannot be found — never a silent local.
#
#   Or run it directly: tracker-config.sh [<main-root>]
#     Prints "tracker=<value>" and "configured=<yes|no>" to stdout.

_TRACKER_CONFIG_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

read_tracker_config() {
  local main_root="${1:-.}" cli="" c out key value

  TRACKER_CONFIG_TRACKER="local"
  TRACKER_CONFIG_CONFIGURED="no"

  # Beside this script at ../tracker/ when installed (.coding-crew/scripts/), ../../tracker/ in a
  # source checkout (scripts/tracker/) — as mark-issue-done.sh finds it.
  for c in "${CREW_TRACKER_CLI:-}" \
    "$_TRACKER_CONFIG_SH_DIR/../tracker/cli.mjs" "$_TRACKER_CONFIG_SH_DIR/../../tracker/cli.mjs" \
    "$main_root/.coding-crew/tracker/cli.mjs" \
    "${HOME:+$HOME/.coding-crew/tracker/cli.mjs}"; do
    if [ -n "$c" ] && [ -f "$c" ]; then cli="$c"; break; fi
  done
  if [ -z "$cli" ]; then
    echo "tracker-config.sh: tracker CLI (.coding-crew/tracker/cli.mjs) not found — re-run install.sh" >&2
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "tracker-config.sh: the tracker CLI needs Node (node not found on PATH)" >&2
    return 1
  fi

  out="$(node "$cli" config --main-root "$main_root")" || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      tracker) TRACKER_CONFIG_TRACKER="$value" ;;
      configured) TRACKER_CONFIG_CONFIGURED="$value" ;;
    esac
  done <<< "$out"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  read_tracker_config "${1:-.}" || exit 1
  echo "tracker=$TRACKER_CONFIG_TRACKER"
  echo "configured=$TRACKER_CONFIG_CONFIGURED"
fi
