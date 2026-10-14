#!/usr/bin/env bash
# Detect whether to install dependencies via docker or on the host.
# Prints USE_DOCKER or USE_HOST to stdout.
#
# Usage:
#   bash scripts/detect-mode.sh [--project-root /path/to/worktree]
#
# Detection order: git config --local agent.install-mode (docker|host); dev-commands.json's
# "install_mode"; then a Makefile install/deps/setup/... target whose `make -n` recipe invokes
# docker compose/run/exec → docker, any other Makefile → host.

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
  _main_root_of() {
    local dir="$1" common
    common=$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    case "$common" in
      /*|[A-Za-z]:*) : ;;
      *) common="$(cd "$dir" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")" ;;
    esac
    dirname "$common"
  }
  _main_root="${MAIN_ROOT:-}"
  [ -n "$_main_root" ] || _main_root=$(_main_root_of "$PROJECT_ROOT") || _main_root=""
  if [ -n "$_main_root" ] && [ -f "$_main_root/.coding-crew/dev-commands.json" ]; then
    _cached_mode="$(grep -o '"install_mode"[[:space:]]*:[[:space:]]*"[^"]*"' \
        "$_main_root/.coding-crew/dev-commands.json" 2>/dev/null \
      | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true)"
    case "$_cached_mode" in
      docker) _mode="docker" ;;
      host) _mode="host" ;;
    esac
  fi
fi

if [ -z "$_mode" ]; then
  # Success of -C "$PROJECT_ROOT" already means containment; comparing path strings breaks on
  # symlinked dirs (macOS's /var) and Windows drive-letter paths.
  git -C "$PROJECT_ROOT" rev-parse --show-toplevel >/dev/null 2>&1 || _mode="host"
fi

if [ -z "$_mode" ] && [ -f "$PROJECT_ROOT/Makefile" ]; then
  _mode="host"
  # Some GNU Make builds (3.81, macOS's default) run a recipe containing "make" even under -n, so docker
  # and docker-compose are stubbed on PATH for this probe: no call can hang on a missing daemon.
  _stub_dir="$(mktemp -d)"
  _stub_log="$_stub_dir/invoked"
  for _cmd in docker docker-compose; do
    cat > "$_stub_dir/$_cmd" <<STUB
#!/bin/sh
printf '%s\n' "\$0 \$*" >> "$_stub_log"
STUB
    chmod +x "$_stub_dir/$_cmd"
  done
  for _target in install deps setup depend bootstrap prepare up build dev; do
    _recipe="$(cd "$PROJECT_ROOT" && PATH="$_stub_dir:$PATH" make -n "$_target" 2>/dev/null || true)"
    if grep -qE 'docker (compose|run|exec)' <<<"$_recipe" || [ -s "$_stub_log" ]; then
      _mode="docker"
      break
    fi
  done
  rm -rf "$_stub_dir"
fi

[ "$_mode" = "docker" ] && echo "USE_DOCKER" || echo "USE_HOST"
