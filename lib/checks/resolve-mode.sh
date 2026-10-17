#!/usr/bin/env bash
# resolve-mode.sh — this checkout's install mode, as its dev commands file records it.
#
# Usage:
#   bash scripts/resolve-mode.sh --project-root <path>
#
# Prints INSTALL_MODE=docker|host and DOCKER_SERVICE=<name> (may be empty), exit 0. The mode is
# "install_mode" of the dev commands file commands-file.sh names; absent or any other value is host.
# Deciding it is discover-mode.sh's job (a model's answer, persisted by write-commands-cache.sh), never this script's.

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
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/commands-file.sh"
CACHE=$(commands_file "$PROJECT_ROOT")

MODE="$(commands_field "$CACHE" install_mode)"
SERVICE=""
if [ "$MODE" = docker ]; then
  SERVICE="$(commands_field "$CACHE" docker_service)"
else
  MODE=host
fi

echo "INSTALL_MODE=$MODE"
echo "DOCKER_SERVICE=$SERVICE"
