#!/usr/bin/env bash
# main-root.sh — sourced: main_root [dir] prints the checkout holding .scratch/ and .coding-crew/
# from any worktree, by main.mjs's gitRoot() rule: the shared git dir's parent when it is `.git`,
# else its `core.worktree` (a submodule), else (a bare repo) the current worktree's top level.
# Printed via `pwd -P`, so it compares with callers' own (Windows' `C:/…` vs git-bash's `/c/…`).

main_root() {
  local dir="${1:-.}" common wt top
  common=$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*|[A-Za-z]:*) : ;;
    *) common="$dir/$common" ;;
  esac
  if [ "$(basename "$common")" = .git ]; then
    (cd "$dir" && cd "$(dirname "$common")" && pwd -P)
  elif wt=$(git --git-dir="$common" config --get core.worktree 2>/dev/null) && [ -n "$wt" ]; then
    (cd "$dir" && cd "$common" && cd "$wt" && pwd -P)
  else
    top=$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null) && [ -n "$top" ] || return 1
    (cd "$top" && pwd -P)
  fi
}
