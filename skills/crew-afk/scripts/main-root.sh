#!/usr/bin/env bash
# main-root.sh — which checkout holds a sprint's .scratch/ and .coding-crew/, from any of the
# repo's worktrees. Sourced, not run:
#
#   . "$SCRIPT_DIR/main-root.sh"
#   MAIN_ROOT="${MAIN_ROOT:-$(main_root)}"
#
# The same rule as main.mjs's gitRoot(), so a hand run, a gate and the orchestrator agree. From the
# shared git dir (`--git-common-dir`, the same from every worktree):
#   - named `.git`: its parent, the main checkout;
#   - else with `core.worktree` set (a submodule's `.git/modules/<name>`): that checkout;
#   - else (a bare repo): no main checkout exists, so the current worktree's top level.
# Printed through `pwd -P`, so callers can compare it with their own `pwd -P` paths (on Windows
# git's `C:/…` and git-bash's `/c/…` name the same directory differently).

# main_root [dir] — prints the root for the repo `dir` (default: cwd) is in; non-zero outside one.
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
