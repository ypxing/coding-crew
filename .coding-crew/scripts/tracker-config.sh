#!/usr/bin/env bash
# tracker-config.sh — reads which issue-tracker backend a repo uses.
#
# The single source of truth is the optional YAML front matter atop
# .coding-crew/docs/issue-tracker.md:
#
#   ---
#   tracker: github        # or "local"
#   # repo: owner/name     # optional override — omit to let `gh` infer it from the git remote
#   ---
#
# Absent doc, absent front matter, or an absent field are all zero-config: existing
# local-tracker installs need no front matter at all. Pure read — no network calls,
# no file writes.
#
# Usage:
#   source this script, then call: read_tracker_config [<main-root>]
#     Sets TRACKER_CONFIG_TRACKER (local|github) and TRACKER_CONFIG_REPO
#     (owner/name, or "" when absent).
#
#   Or run it directly: tracker-config.sh [<main-root>]
#     Prints "tracker=<value>" and "repo=<value>" to stdout.
#
# This is the bash equivalent of orchestrator/lib/tracker-config.mjs's
# readTrackerConfig(mainRoot) — keep the two in sync.

read_tracker_config() {
  local main_root="${1:-.}"
  local doc="$main_root/.coding-crew/docs/issue-tracker.md"

  TRACKER_CONFIG_TRACKER="local"
  TRACKER_CONFIG_REPO=""

  [ -f "$doc" ] || return 0

  local lineno=0 in_fm=0 line value
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ "$lineno" -eq 1 ]; then
      # Front matter must open on the file's very first line, exactly like YAML.
      [ "$line" = "---" ] || return 0
      in_fm=1
      continue
    fi
    [ "$line" = "---" ] && break
    case "$line" in
      tracker:*)
        value="${line#tracker:}"
        value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//')"
        [ "$value" = "github" ] && TRACKER_CONFIG_TRACKER="github"
        ;;
      repo:*)
        value="${line#repo:}"
        value="$(printf '%s' "$value" | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//')"
        TRACKER_CONFIG_REPO="$value"
        ;;
    esac
  done < "$doc"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  read_tracker_config "$1"
  echo "tracker=$TRACKER_CONFIG_TRACKER"
  echo "repo=$TRACKER_CONFIG_REPO"
fi
