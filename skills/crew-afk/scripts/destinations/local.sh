# local — a detached git worktree under ~/.coding-crew/worktrees, and a detached headless run capped at 1h.
# Sourced by crew-afk.sh, which sets MAIN, WORKTREES and die.
prepare() { # <slug> <base-branch>
  local wt="$WORKTREES/$1"
  if ! git -C "$MAIN" worktree list --porcelain | grep -xF "worktree $wt" >/dev/null; then
    [ ! -e "$wt" ] || die "$wt exists but is not a worktree of $MAIN: move it away, then re-run"
    git -C "$MAIN" fetch -q origin || die "git fetch origin failed"
    # Detached: git refuses a branch checked out in another worktree, and solve-feature picks the branch.
    git -C "$MAIN" worktree add -q --detach "$wt" "origin/$2" >&2 || die "git worktree add $wt failed"
  fi
  echo "$wt"
}

launch() { # <slug> <worktree> <argv…>
  local wt="$2" timeout
  shift 2
  timeout=$(command -v timeout || command -v gtimeout) || die "timeout not found on PATH (macOS: brew install coreutils)"
  (cd "$wt" || exit 1
    nohup "$timeout" 1h "$@" >"$wt/.coding-crew/solve-feature/run.log" 2>&1 </dev/null &
    echo $! >"$wt/.coding-crew/solve-feature/run.pid")
}

live() { # <logs-dir> — see crew-afk.sh
  local pid
  pid=$(live_pid "$1") && echo "pid $pid"
}
