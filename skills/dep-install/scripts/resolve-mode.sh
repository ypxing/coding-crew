#!/usr/bin/env bash
# resolve-mode.sh — this project's install mode, and whether this session has to install.
#
# One verdict for every reader: solve-issue's Step 2 asks it once per issue, and run.sh asks it
# before every check a worker or verify-worktree.sh runs. Before this, solve-issue checked the
# override file then detect-mode.sh, dep-install re-read the cache, and verify-worktree.sh read
# only `agent.install-mode` — three questions that could answer differently about where the same
# `npm test` runs.
#
# Usage:
#   bash scripts/resolve-mode.sh --project-root <path> [--main-root <path>] [--deps <outcome>]
#                                [--no-heuristic]
#
# Prints KEY=VALUE lines, exit 0:
#   INSTALL_MODE=docker|host
#   DOCKER_SERVICE=<name>          recorded service (git config agent.install-service, then the
#                                  cache's "docker_service"); empty when none is — docker-install.sh
#                                  and run.sh then fall back to gen-override.sh's own choice
#   ACTION=none|install|on-failure
#
# Mode, first match wins:
#   1. git config --local agent.install-mode (docker|host) — the explicit, documented override
#   2. $MAIN_ROOT/.coding-crew/dev-commands.json's "install_mode" — the project's cached verdict
#   3. $MAIN_ROOT/docker-compose.override.yml exists — a docker install already ran here
#   4. detect-mode.sh's Makefile dry-run. --no-heuristic skips it and reads as host: run.sh's
#      per-command caller cannot afford a `make -n` sweep each time, and by the time any check
#      runs, a docker verdict that matters is already on disk as rung 1, 2 or 3.
#
# ACTION:
#   none        --deps is an outcome ensure-deps.sh reports when the deps are already in place
#               (present, installed, docker-present, docker-installed) — nothing to install
#   install     docker mode and no such outcome: invoke dep-install now. Docker mode has no
#               host-side fallback, so this is never deferred to "if a command fails"
#   on-failure  host mode: invoke dep-install only when a command fails for a missing dependency
#               (module-not-found, import error, test runner not found)

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

# _main_root_of <dir> — the main checkout from any linked worktree, in `pwd -P` form so the
# paths built from it compare equal to PROJECT_ROOT's (see verify-worktree.sh's own copy).
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

# _cached <key> — a string field of the commands cache, or nothing.
_cached() {
  [ -f "$CACHE" ] || return 0
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CACHE" 2>/dev/null \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true
}

MODE="$(git -C "$PROJECT_ROOT" config --local agent.install-mode 2>/dev/null || true)"
case "$MODE" in docker|host) : ;; *) MODE="$(_cached install_mode)" ;; esac
case "$MODE" in docker|host) : ;; *) MODE="" ;; esac
[ -n "$MODE" ] || { [ -f "$MAIN_ROOT/docker-compose.override.yml" ] && MODE=docker; }
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
