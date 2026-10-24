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
  local slug="$1" wt="$2" out handle=""
  shift 2
  # The worktree's startup shell takes the run when it is the only terminal: orca cannot tell an idle shell from
  # one busy with a non-agent command, so a terminal a person opened beside it is never typed into.
  out=$(orca terminal list --worktree "path:$wt" --json 2>/dev/null) &&
    handle=$(jq -r '.result.terminals | select(length == 1) | .[0] | select(.agentIdentity == null) | .handle // empty' \
      <<<"$out" 2>/dev/null) || handle=""
  if [ -n "$handle" ]; then
    # A re-run lists the same lone terminal again, so the stop names the one way out: closing it.
    out=$(orca terminal send --terminal "$handle" --text "$(printf '%q ' "$@")" --enter --json) ||
      die "orca terminal send failed: $(jq -ce '.error | {code, message}' <<<"$out" 2>/dev/null || echo "$out");" \
        "close terminal $handle in orca and re-run"
  else
    # --command is typed into the terminal's shell, so the argv goes in quoted.
    out=$(orca terminal create --worktree "path:$wt" --title "$slug" --command "$(printf '%q ' "$@")" --json) ||
      die "orca terminal create failed"
    handle=$(jq -r '.result.terminal.handle // empty' <<<"$out")
    [ -n "$handle" ] || die "orca terminal create named no terminal handle: $out"
  fi
  echo "$handle" >"$wt/.coding-crew/solve-feature/run.pane"
}

live() { # <logs-dir> — see crew-afk.sh
  local handle out err rc=0
  handle=$(cat "$1/run.pane" 2>/dev/null) && [ -n "$handle" ] || return 1
  err=$(mktemp)
  # No --environment: launch asked the same orca server from this machine, and a handle is that server's.
  out=$(orca terminal show --terminal "$handle" --json 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # A failure never counts the run as gone: an unknown handle's terminal_handle_stale may follow an orca restart.
    # Under --json orca prints its error on stdout, indented, so it goes on one line ahead of any stderr.
    jq -ce '.error | {code, message}' <<<"$out" 2>/dev/null || printf '%s\n' "$out"
    cat "$err"; rm -f "$err"
    echo "if the terminal is gone, delete $1/run.pane and re-run"
    return 2
  fi
  rm -f "$err"
  ! jq -e '.result.terminal.orphaned == true or .result.terminal.connected == false' >/dev/null <<<"$out" || return 1
  echo "orca terminal $handle"
}
