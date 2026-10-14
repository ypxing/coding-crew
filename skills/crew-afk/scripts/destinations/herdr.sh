# herdr — a worktree herdr creates beside the main checkout, and an interactive run in a new herdr pane:
# uncapped, a person watches it. Sourced by crew-afk.sh, which sets MAIN, WORKTREES, SLUG and die.

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

launch() { # <worktree> <argv…>; argv[0] is the agent herdr starts
  local wt="$1" out workspace pane
  shift
  # worktree open returns the workspace already open on it, so a re-run lands beside the last one.
  out=$(herdr worktree open --path "$wt" --cwd "$MAIN" --no-focus) || die "herdr worktree open failed"
  workspace=$(jq -r '.result.workspace.workspace_id // empty' <<<"$out")
  [ -n "$workspace" ] || die "herdr worktree open named no workspace: $out"
  out=$(herdr tab create --workspace "$workspace" --cwd "$wt" --label "$SLUG" --no-focus) || die "herdr tab create failed"
  pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")
  [ -n "$pane" ] || die "herdr tab create named no pane: $out"
  herdr agent start "$SLUG" --kind "$1" --pane "$pane" -- "${@:2}" >/dev/null || die "herdr agent start failed"
}
