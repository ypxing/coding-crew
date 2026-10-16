#!/usr/bin/env bash
# commands-file.sh --project-root <path> — prints the path of the checkout's dev commands file (its checks, install
# command and install mode): <root>/.coding-crew/dev-commands.json when the tree has one (a team commits it to share
# the commands), else dev-commands.json in the clone's git common dir, which every worktree of the clone shares, no
# tree holds and nothing commits. The file need not exist yet. Sourced, it defines commands_file <root> instead.

commands_file() { # <project-root>
  local tracked="$1/.coding-crew/dev-commands.json" common
  [ ! -f "$tracked" ] || { echo "$tracked"; return; }
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "$tracked"; return; }
  echo "$common/coding-crew/dev-commands.json"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -eq 2 ] && [ "$1" = --project-root ] && [ -d "$2" ] || { echo "usage: commands-file.sh --project-root <existing dir>" >&2; exit 2; }
  commands_file "$2"
fi
