#!/usr/bin/env bash
# commands-file.sh --project-root <path> — prints the path of the clone's dev commands file (its checks, install
# command and install mode): <path>'s own tree's .coding-crew/dev-commands.json when that tree tracks it, else the
# main checkout's, committed or not, so every worktree reads and writes the one file and a run works before the
# user commits it. Outside a git repository it is
# <path>/.coding-crew/dev-commands.json. The file need not exist yet. Sourced, it defines commands_file <root> instead,
# and the only readers of the file's fields: commands_field and commands_field_present.

commands_file() { # <project-root>
  local root="$1" common top
  # A branch that commits the file is gated on its own copy, not on whatever the main checkout has.
  if top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) &&
    git -C "$top" ls-files --error-unmatch -- .coding-crew/dev-commands.json >/dev/null 2>&1; then
    echo "$top/.coding-crew/dev-commands.json"; return
  fi
  # The main checkout as the tracker finds it: the common dir's parent when it is a .git directory.
  if common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    if [ "$(basename "$common")" = .git ]; then root=$(dirname "$common")
    else root=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || root="$1"
    fi
  fi
  echo "$root/.coding-crew/dev-commands.json"
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
