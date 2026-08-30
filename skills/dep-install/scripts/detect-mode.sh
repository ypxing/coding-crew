#!/usr/bin/env bash
# Detect whether to install dependencies via docker or on the host.
# Prints USE_DOCKER or USE_HOST to stdout.
#
# Usage:
#   bash scripts/detect-mode.sh [--project-root /path/to/worktree]
#
# Options:
#   --project-root   Path to the worktree. Default: $PROJECT_ROOT or current directory.
#
# Detection order:
#   1. git config --local agent.install-mode (docker|host) — an explicit, documented override
#   2. $MAIN_ROOT/.scratch/install-mode — this sprint's own cached verdict (see below)
#   3. Makefile install/deps/setup/depend target invokes docker compose/run/exec → docker; present but no match → host

set -euo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

_mode=$(git -C "$PROJECT_ROOT" config --local agent.install-mode 2>/dev/null || true)

# The cache file is this sprint's own answer, written once by ensure-deps.sh's MAIN_ROOT
# call (before any worktree exists, so there is nothing to race with) and read by every
# later call — this script's own worktree calls and a worker's independent up-front
# invocation alike. That second reader is why this matters: it may resolve a completely
# different install of dep-install than the one ensure-deps.sh used (a different platform's
# skill copy, a stale global one), and without a shared answer on disk it would silently
# re-derive its own — from git config (usually still empty at this point) or the Makefile
# heuristic below, which is a plain reimplementation the worker's copy might get wrong or
# lack entirely. A cache hit skips both.
if [ -z "$_mode" ]; then
  _main_root_of() {
    local dir="$1" common
    common=$(cd "$dir" && git rev-parse --git-common-dir 2>/dev/null) || return 1
    case "$common" in
      /*) : ;;
      *) common="$(cd "$dir" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")" ;;
    esac
    dirname "$common"
  }
  _main_root="${MAIN_ROOT:-}"
  [ -n "$_main_root" ] || _main_root=$(_main_root_of "$PROJECT_ROOT") || _main_root=""
  if [ -n "$_main_root" ] && [ -f "$_main_root/.scratch/install-mode" ]; then
    case "$(cat "$_main_root/.scratch/install-mode" 2>/dev/null || true)" in
      docker) _mode="docker" ;;
      host) _mode="host" ;;
    esac
  fi
fi

if [ -z "$_mode" ]; then
  _git_root=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null) || _git_root=""
  case "$PROJECT_ROOT/" in
    "$_git_root/"*) ;;
    *) _mode="host" ;;
  esac
fi

if [ -z "$_mode" ] && [ -f "$PROJECT_ROOT/Makefile" ]; then
  _uses_docker=$(awk '
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[:?+]?=/ {
      if (tolower($0) ~ /docker[ -]compose|docker run|docker exec/) {
        split($0, a, /[[:space:]]*[:?+]?=/)
        gsub(/[[:space:]]/, "", a[1])
        docker_vars[a[1]] = 1
      }
    }
    /^[a-zA-Z][a-zA-Z0-9_-]*[[:space:]]*:[^=]/ {
      in_target = ($0 ~ /^(install|deps|setup|depend|bootstrap|prepare|up|build|dev)[[:space:]]*:/)
    }
    in_target && /^\t/ {
      if (tolower($0) ~ /docker[ -]compose|docker run|docker exec/) { print "yes"; exit }
      for (v in docker_vars) {
        if ($0 ~ "\\$\\(" v "\\)") { print "yes"; exit }
      }
    }
  ' "$PROJECT_ROOT/Makefile")
  [ "$_uses_docker" = "yes" ] && _mode="docker" || _mode="host"
fi

[ "$_mode" = "docker" ] && echo "USE_DOCKER" || echo "USE_HOST"
