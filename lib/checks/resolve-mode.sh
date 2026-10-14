#!/usr/bin/env bash
# resolve-mode.sh — this project's install mode, and whether this session has to install.
#
# Usage:
#   bash scripts/resolve-mode.sh --project-root <path> [--main-root <path>] [--deps <outcome>]
#                                [--no-heuristic]
#
# Prints INSTALL_MODE=docker|host, DOCKER_SERVICE=<name> (git config agent.install-service, then the
# cache's "docker_service"; may be empty) and ACTION=none|install|on-failure, exit 0.
# Mode, first match wins: git config --local agent.install-mode, dev-commands.json's "install_mode",
# then detect-mode.sh's Makefile dry-run (--no-heuristic: host instead, for per-command callers that
# cannot afford a `make -n` sweep). A repo's docker-compose.override.yml is never a signal.
# ACTION: none when --deps reports the deps in place (present, installed, docker-present,
# docker-installed); else install in docker mode (no host fallback), on-failure in host mode.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT="${PROJECT_ROOT:-}"
MAIN_ROOT_ARG=""
DEPS=""
HEURISTIC=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root|--main-root|--deps)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 1; fi
      case "$1" in
        --project-root) PROJECT_ROOT="$2" ;;
        --main-root) MAIN_ROOT_ARG="$2" ;;
        --deps) DEPS="$2" ;;
      esac
      shift 2
      ;;
    --no-heuristic) HEURISTIC=0; shift ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$(pwd)"
if [ ! -d "$PROJECT_ROOT" ]; then echo "Error: directory does not exist: $PROJECT_ROOT" >&2; exit 1; fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"

# _main_root_of <dir> — in `pwd -P` form, so paths built from it compare equal to PROJECT_ROOT's.
_main_root_of() {
  local dir="$1" common
  common=$(cd "$dir" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*|[A-Za-z]:*) : ;;
    *) common="$dir/$common" ;;
  esac
  common="$(cd "$dir" && cd "$(dirname "$common")" && pwd -P)/$(basename "$common")"
  dirname "$common"
}

MAIN_ROOT="${MAIN_ROOT_ARG:-${MAIN_ROOT:-}}"
[ -n "$MAIN_ROOT" ] || MAIN_ROOT="$(_main_root_of "$PROJECT_ROOT" 2>/dev/null || true)"
[ -n "$MAIN_ROOT" ] || MAIN_ROOT="$PROJECT_ROOT"
CACHE="$MAIN_ROOT/.coding-crew/dev-commands.json"

_cached() {
  [ -f "$CACHE" ] || return 0
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CACHE" 2>/dev/null \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true
}

MODE="$(git -C "$PROJECT_ROOT" config --local agent.install-mode 2>/dev/null || true)"
case "$MODE" in docker|host) : ;; *) MODE="$(_cached install_mode)" ;; esac
case "$MODE" in docker|host) : ;; *) MODE="" ;; esac
if [ -z "$MODE" ] && [ "$HEURISTIC" -eq 1 ] && [ -f "$SELF_DIR/detect-mode.sh" ]; then
  [ "$(MAIN_ROOT="$MAIN_ROOT" bash "$SELF_DIR/detect-mode.sh" --project-root "$PROJECT_ROOT" 2>/dev/null)" = USE_DOCKER ] && MODE=docker
fi
[ -n "$MODE" ] || MODE=host

SERVICE=""
if [ "$MODE" = docker ]; then
  SERVICE="$(git -C "$PROJECT_ROOT" config --local agent.install-service 2>/dev/null || true)"
  [ -n "$SERVICE" ] || SERVICE="$(_cached docker_service)"
fi

DEPS="${DEPS#DEPS: }"
case "${DEPS%% *}" in
  present|installed|docker-present|docker-installed) ACTION=none ;;
  *) if [ "$MODE" = docker ]; then ACTION=install; else ACTION=on-failure; fi ;;
esac

echo "INSTALL_MODE=$MODE"
echo "DOCKER_SERVICE=$SERVICE"
echo "ACTION=$ACTION"
