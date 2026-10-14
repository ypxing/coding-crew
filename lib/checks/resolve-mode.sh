#!/usr/bin/env bash
# resolve-mode.sh — this checkout's install mode, as its committed dev-commands.json records it.
#
# Usage:
#   bash scripts/resolve-mode.sh --project-root <path>
#
# Prints INSTALL_MODE=docker|host and DOCKER_SERVICE=<name> (may be empty), exit 0. The mode is
# <project-root>/.coding-crew/dev-commands.json's "install_mode"; absent or any other value is host.
# Deciding it is dep-install's setup step (detect-mode.sh, confirmed by a person), never this script's.

set -uo pipefail

PROJECT_ROOT="${PROJECT_ROOT:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$(pwd)"
if [ ! -d "$PROJECT_ROOT" ]; then echo "Error: directory does not exist: $PROJECT_ROOT" >&2; exit 2; fi
CACHE="$PROJECT_ROOT/.coding-crew/dev-commands.json"

_cached() {
  [ -f "$CACHE" ] || return 0
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$CACHE" 2>/dev/null \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true
}

MODE="$(_cached install_mode)"
SERVICE=""
if [ "$MODE" = docker ]; then
  SERVICE="$(_cached docker_service)"
else
  MODE=host
fi

echo "INSTALL_MODE=$MODE"
echo "DOCKER_SERVICE=$SERVICE"
