# orca — an orca-managed worktree, and an interactive run in an orca terminal: uncapped, a person watches it.
# Sourced by crew-afk.sh, which sets MAIN and die.
prepare() { # <slug> <base-branch>
  command -v orca >/dev/null || die "orca not found on PATH"
  local out path
  out=$(orca worktree show --worktree "name:$1" --json 2>/dev/null) ||
    out=$(orca worktree create --repo "path:$MAIN" --name "$1" --base-branch "$2" --json) || die "orca worktree create failed"
  path=$(jq -r '.result.worktree.path // empty' <<<"$out")
  [ -n "$path" ] || die "orca named no worktree path: $out"
  echo "$path"
}

launch() { # <slug> <worktree> <argv…>
  local slug="$1" wt="$2"
  shift 2
  # --command is typed into the terminal's shell, so the argv goes in quoted.
  orca terminal create --worktree "path:$wt" --title "$slug" --command "$(printf '%q ' "$@")" --json >/dev/null ||
    die "orca terminal create failed"
}
