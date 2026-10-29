# herdr — a worktree herdr creates under ~/.coding-crew/worktrees, and an interactive run in a herdr pane:
# uncapped, a person watches it. Sourced by crew-afk.sh, which sets MAIN, WORKTREES and die.
prepare() { # <slug> <base-branch>
  command -v herdr >/dev/null || die "herdr not found on PATH"
  local wt="$WORKTREES/$1"
  if ! git -C "$MAIN" worktree list --porcelain | grep -xF "worktree $wt" >/dev/null; then
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
  # A fresh workspace's root pane is its idle startup shell (no agent): the run goes there instead of a new tab.
  pane=$(jq -r 'if (.result.root_pane.agent // "") == "" then .result.root_pane.pane_id // empty else empty end' <<<"$out")
  if [ -z "$pane" ]; then
    out=$(herdr tab create --workspace "$workspace" --cwd "$wt" --label "$slug" --no-focus) || die "herdr tab create failed"
    pane=$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")
    [ -n "$pane" ] || die "herdr tab create named no pane: $out"
  fi
  # Typed into the pane's shell, as orca's --command is, so the argv goes in quoted: `herdr agent start` waits
  # for an agent ready for input, and one given a prompt starts working instead, so it times out.
  herdr pane run "$pane" "$(printf '%q ' "$@")" >/dev/null || die "herdr pane run failed"
  echo "$pane" >"$wt/.coding-crew/solve-feature/run.pane"
}

live() { # <logs-dir> — see crew-afk.sh
  local pane err
  pane=$(cat "$1/run.pane" 2>/dev/null) && [ -n "$pane" ] || return 1
  if err=$(herdr pane get "$pane" 2>&1 >/dev/null); then echo "herdr pane $pane"; return 0; fi
  ! grep -q pane_not_found <<<"$err" || return 1
  echo "$err"
  echo "if the pane is gone, delete $1/run.pane and re-run"
  return 2
}
