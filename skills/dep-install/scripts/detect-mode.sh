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
#   1. git config --local agent.install-mode (docker|host)
#   2. Makefile install/deps/setup target invokes docker compose
#   3. docker-compose.yml / docker-compose.yaml / compose.yml exists

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

if [ -z "$_mode" ]; then
  _git_root=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null) || _git_root=""
  case "$PROJECT_ROOT/" in
    "$_git_root/"*) ;;
    *) _mode="host" ;;
  esac
fi

if [ -z "$_mode" ] && [ -f "$PROJECT_ROOT/Makefile" ]; then
  _uses_docker=$(awk '
    /^[a-zA-Z][a-zA-Z0-9_-]*[[:space:]]*:[^=]/ {
      in_target = ($0 ~ /^(install|deps|setup)[[:space:]]*:/)
    }
    in_target && /^\t/ && /docker[ -]compose|docker compose/ { print "yes"; exit }
  ' "$PROJECT_ROOT/Makefile")
  [ "$_uses_docker" = "yes" ] && _mode="docker"
fi

if [ -z "$_mode" ]; then
  { [ -f "$PROJECT_ROOT/docker-compose.yml" ] || \
    [ -f "$PROJECT_ROOT/docker-compose.yaml" ] || \
    [ -f "$PROJECT_ROOT/compose.yml" ]; } \
    && _mode="docker" || _mode="host"
fi

[ "$_mode" = "docker" ] && echo "USE_DOCKER" || echo "USE_HOST"
