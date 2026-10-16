# herdr — a worktree herdr creates beside the main checkout, and an interactive run in a new herdr pane:
# uncapped, a person watches it. Sourced by crew-afk.sh, which sets MAIN, WORKTREES and die.
prepare() { # <slug> <base-branch>
  command -v herdr >/dev/null || die "herdr not found on PATH"
  local wt="$WORKTREES/$1"
  if ! git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $wt"; then
    # Its own branch: solve-feature checks out the feature's, which may be checked out nowhere else.
    herdr worktree create --cwd "$MAIN" --branch "crew-afk/$1" --base "$2" --path "$wt" --label "$1" --no-focus >/dev/null ||
      die "herdr worktree create failed"
  fi
  echo "$wt"
}

launch() { # <slug> <worktree> <argv…>
  local slug="$1" wt="$2" out workspace pane
  shift 2
  # worktree open returns the workspace already open on it, so a re-run lands beside the last one.
  out=$(herdr worktree open --path "$wt" --cwd "$MAIN" --no-focus) || die "herdr worktree open failed"
  workspace=$(jq -r '.result.workspace.workspace_id // empty' <<<"$out")
  [ -n "$workspace" ] || die "herdr worktree open named no workspace: $out"
  out=$(herdr tab create --workspace "$workspace" --cwd "$wt" --label "$slug" --no-focus) || die "herdr tab create failed"
  pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")
  [ -n "$pane" ] || die "herdr tab create named no pane: $out"
  # Typed into the pane's shell, as orca's --command is, so the argv goes in quoted: `herdr agent start` waits
  # for an agent ready for input, and one given a prompt starts working instead, so it times out.
  herdr pane run "$pane" "$(printf '%q ' "$@")" >/dev/null || die "herdr pane run failed"
}
