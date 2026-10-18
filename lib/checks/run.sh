#!/usr/bin/env bash
# run.sh — run one project command where this checkout's checks run.
#
# Usage:
#   bash scripts/run.sh --project-root <path> -- <command>
#
# The mode is the clone's dev commands file's "install_mode" (resolve-mode.sh): host,
# or docker, where <command> runs as `docker compose run --rm <service> sh -c 'cd <src> && <command>'`
# through the docker shim, which adds this checkout's override (its dependency volumes). With no
# override yet, docker-install.sh generates it and installs first; a failed install stops here with
# the service, the step and its log, and <command> never runs. A command that runs docker itself runs
# on the host, its own compose calls given the override by the shim.
# Exit code is the command's own, or 1 when the docker install or setup failed.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT="${PROJECT_ROOT:-}"
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --) shift; CMD="$*"; break ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1 (the command goes after --)" >&2; exit 2 ;;
  esac
done

if [ -z "$CMD" ]; then
  echo "Error: no command given (usage: run.sh --project-root <path> -- <command>)" >&2
  exit 2
fi

[ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$(pwd)"
if [ ! -d "$PROJECT_ROOT" ]; then echo "Error: directory does not exist: $PROJECT_ROOT" >&2; exit 2; fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"

# Where gen-override.sh writes it; empty when PROJECT_ROOT is not a git checkout.
OVERRIDE=""
_gitdir="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
[ -z "$_gitdir" ] || OVERRIDE="$_gitdir/crew-compose.override.yml"

# Every compose call from here on, ours or a recipe's, goes through the shim.
export PATH="$SELF_DIR/shim:$PATH"

_host() {
  if [ -f "$OVERRIDE" ]; then export CREW_COMPOSE_OVERRIDE="$OVERRIDE"; fi
  bash -c 'cd "$1" && eval "$2"' _ "$PROJECT_ROOT" "$CMD"
}

_stop() {
  echo "run.sh: docker mode: $1 — '$CMD' did not run, and does not run on the host instead." >&2
  exit 1
}

verdict="$(bash "$SELF_DIR/resolve-mode.sh" --project-root "$PROJECT_ROOT")"
# A here-string, not a pipe: grep -q exits at its first match, and under pipefail the writer's
# SIGPIPE would read as "not docker" and run a docker-mode check on the host.
if ! grep -qx 'INSTALL_MODE=docker' <<< "$verdict"; then _host; exit $?; fi
SERVICE="$(sed -n 's/^DOCKER_SERVICE=//p' <<< "$verdict")"

[ -n "$OVERRIDE" ] || _stop "$PROJECT_ROOT is not a git checkout, so it has no compose override"

if [ ! -f "$OVERRIDE" ]; then
  log="$_gitdir/crew-docker-install.log"
  echo "run.sh: docker mode, no override yet — installing dependencies first (log: $log)" >&2
  if ! bash "$SELF_DIR/docker-install.sh" --project-root "$PROJECT_ROOT" \
      </dev/null >"$log" 2>&1; then
    summary="$(sed -n 's/^docker-install: failed — //p' "$log" | tail -1)"
    tail -n 20 "$log" >&2
    _stop "the dependency install failed — ${summary:-service ${SERVICE:-<unknown>}, step install}; log: $log"
  fi
fi

if bash "$SELF_DIR/detect-docker-nesting.sh" --dir "$PROJECT_ROOT" --cmd "$CMD"; then _host; exit $?; fi

COMPOSE_FILE=""
for name in docker-compose.yml docker-compose.yaml compose.yml; do
  if [ -f "$PROJECT_ROOT/$name" ]; then COMPOSE_FILE="$PROJECT_ROOT/$name"; break; fi
done
[ -n "$COMPOSE_FILE" ] || _stop "no compose file in $PROJECT_ROOT"

gen=(bash "$SELF_DIR/gen-override.sh" --project-root "$PROJECT_ROOT")
[ -n "$SERVICE" ] || SERVICE="$("${gen[@]}" --query services 2>/dev/null | head -1)"
[ -n "$SERVICE" ] || _stop "no compose service in $COMPOSE_FILE"
CONTAINER_SRC="$("${gen[@]}" --query container-src 2>/dev/null)"
[ -n "$CONTAINER_SRC" ] || _stop "no container-side source dir for service $SERVICE"

export CREW_COMPOSE_OVERRIDE="$OVERRIDE"
cd "$PROJECT_ROOT" && exec docker compose run --rm "$SERVICE" sh -c "cd \"$CONTAINER_SRC\" && $CMD"
