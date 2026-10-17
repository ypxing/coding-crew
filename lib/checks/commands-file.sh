#!/usr/bin/env bash
# commands-file.sh --project-root <path> — prints the path of the checkout's dev commands file (its checks, install
# command and install mode): <root>/.coding-crew/dev-commands.json when the tree has one (a team commits it to share
# the commands), else dev-commands.json in the clone's git common dir, which every worktree of the clone shares, no
# tree holds and nothing commits. The file need not exist yet. Sourced, it defines commands_file <root> instead,
# and the only readers of the file's fields: commands_field and commands_field_present.

commands_file() { # <project-root>
  local tracked="$1/.coding-crew/dev-commands.json" common
  [ ! -f "$tracked" ] || { echo "$tracked"; return; }
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "$tracked"; return; }
  echo "$common/coding-crew/dev-commands.json"
}

# _commands_token <file> <key> — the raw value of "<key>": a quoted string (escapes kept) or null; empty when
# absent. Matched anywhere in the file, so a model's response with prose or a code fence around the object reads
# the same.
_commands_token() {
  [ -f "$1" ] || return 0
  grep -o "\"$2\"[[:space:]]*:[[:space:]]*\(\"\([^\"\\\\]\|\\\\.\)*\"\|null\)" "$1" 2>/dev/null | head -1 \
    | sed -E "s/^\"$2\"[[:space:]]*:[[:space:]]*//" || true
}

commands_field() { # <file> <key> — the string value, \" \\ and \/ unescaped; empty for null or an absent key
  local raw; raw=$(_commands_token "$1" "$2")
  case "$raw" in \"*\") raw="${raw#\"}"; printf '%s' "${raw%\"}" | sed 's/\\\(["\\/]\)/\1/g' ;; esac
}

commands_field_present() { # <file> <key> — exit 0 when the key is there, null included
  [ -n "$(_commands_token "$1" "$2")" ]
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ $# -eq 2 ] && [ "$1" = --project-root ] && [ -d "$2" ] || { echo "usage: commands-file.sh --project-root <existing dir>" >&2; exit 2; }
  commands_file "$2"
fi
