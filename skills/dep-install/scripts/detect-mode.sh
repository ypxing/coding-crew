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
#   2. $MAIN_ROOT/.coding-crew/dev-commands.json's "mode" field — this project's own committed
#      cache (see below), trusted indefinitely like install/env
#   3. Makefile install/deps/setup/... target: `make -n <target>` dry-run, expanded recipe
#      invokes docker compose/run/exec → docker; Makefile present but no match → host. The
#      dry-run (not a static text scan) is what lets this resolve indirection through Make's
#      own variables/ifeq — the same pattern host-install.sh and ensure-env.sh already use.

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

# The cache is this project's own committed answer — .coding-crew/dev-commands.json's "mode"
# field, written once by ensure-deps.sh's MAIN_ROOT call and trusted indefinitely, the same as
# its install/env fields, rather than re-derived every sprint. It is also what every later
# reader agrees on regardless of which install of dep-install it is running — this script's
# own worktree calls and a worker's independent up-front invocation alike: without a shared
# answer on disk, a worker resolving a completely different copy of dep-install (a different
# platform's skill copy, a stale global one) would silently re-derive its own — from git
# config (usually still empty at this point) or the Makefile heuristic below, which is a plain
# reimplementation that copy might get wrong or lack entirely. A cache hit skips both.
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
  if [ -n "$_main_root" ] && [ -f "$_main_root/.coding-crew/dev-commands.json" ]; then
    _cached_mode="$(grep -o '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' \
        "$_main_root/.coding-crew/dev-commands.json" 2>/dev/null \
      | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true)"
    case "$_cached_mode" in
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
  _mode="host"
  for _target in install deps setup depend bootstrap prepare up build dev; do
    if ( cd "$PROJECT_ROOT" && make -n "$_target" ) >/dev/null 2>&1; then
      _recipe="$(cd "$PROJECT_ROOT" && make -n "$_target" 2>/dev/null || true)"
      if printf '%s' "$_recipe" | grep -qE 'docker (compose|run|exec)'; then
        _mode="docker"
        break
      fi
    fi
  done
fi

[ "$_mode" = "docker" ] && echo "USE_DOCKER" || echo "USE_HOST"
