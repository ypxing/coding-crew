#!/usr/bin/env bash
# run.sh — run one project command where this project's checks actually run.
#
# Docker mode mounts a named volume over the dependency directory (node_modules, .venv, …), so
# its contents never exist on the host: a check has to run inside `docker compose run`, with
# this worktree's crew override loaded, or it fails on deps that are really there. The override
# is added by the `docker` shim (shim/docker) on PATH, not built here: this is the one place that
# runs a project command, and it only has to say `docker compose run --rm <service> …`.
#
# Usage:
#   bash scripts/run.sh --project-root <path> [--main-root <path>] -- <command>
#   bash scripts/run.sh --project-root <path> [--main-root <path>] --describe [-- <command>]
#   bash scripts/run.sh ... --via docker|host -- <command>
#
# <command> is one shell string (`npm test`, `make lint`), run from PROJECT_ROOT on the host or
# from the service's container-side source dir in docker. Exit code is the command's own.
#
# Where it runs:
#   host    resolve-mode.sh says host, or docker mode but <command> already invokes docker itself
#           (detect-docker-nesting.sh): its own `docker compose` calls are not nested in another
#           container, and they get the override because the shim is first on PATH and
#           CREW_COMPOSE_OVERRIDE is set
#   docker  resolve-mode.sh says docker: `docker compose run --rm <service> sh -c 'cd <src> && <command>'`
#           through the shim
# `--via nested` (an older --describe's verdict for the second case) runs as host.
#
# Docker mode that cannot be resolved (no compose file, no override yet, no service) runs on the
# host with one `run.sh: …` warning on stderr: a gate must never stall on docker introspection,
# and a worker sees the warning next to the missing-module error dep-install's retry rule fixes.
#
# --describe prints the verdict as KEY=VALUE lines instead of running anything: RUN=docker|host,
# then for docker SERVICE, CONTAINER_SRC, COMPOSE_FILE, OVERRIDE; FALLBACK=<reason> when docker
# fell back to host; and VIA=docker|host when a command was given.
#
# --via runs a command where an earlier --describe said it goes, without deciding again —
# verify-worktree.sh prints where each check runs before running it. `--via host` never
# resolves anything, which is also how that gate's CREW_VERIFY_DOCKER=off switch is honoured.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT="${PROJECT_ROOT:-}"
MAIN_ROOT_ARG=""
DESCRIBE=0
VIA=""
CMD=""
HAVE_CMD=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root|--main-root|--via)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      case "$1" in
        --project-root) PROJECT_ROOT="$2" ;;
        --main-root) MAIN_ROOT_ARG="$2" ;;
        --via) VIA="$2" ;;
      esac
      shift 2
      ;;
    --describe) DESCRIBE=1; shift ;;
    --) shift; CMD="$*"; HAVE_CMD=1; break ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1 (the command goes after --)" >&2; exit 2 ;;
  esac
done

case "$VIA" in ""|docker|host) : ;; nested) VIA=host ;; *) echo "Error: --via must be docker or host" >&2; exit 2 ;; esac
if [ "$DESCRIBE" -eq 0 ] && { [ "$HAVE_CMD" -eq 0 ] || [ -z "$CMD" ]; }; then
  echo "Error: no command given (usage: run.sh --project-root <path> -- <command>)" >&2
  exit 2
fi

[ -n "$PROJECT_ROOT" ] || PROJECT_ROOT="$(pwd)"
if [ ! -d "$PROJECT_ROOT" ]; then echo "Error: directory does not exist: $PROJECT_ROOT" >&2; exit 2; fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd -P)"

# This worktree's crew override: <its git dir>/crew-compose.override.yml, where gen-override.sh
# writes it. Empty when PROJECT_ROOT is not a git checkout.
OVERRIDE=""
_gitdir="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
[ -z "$_gitdir" ] || OVERRIDE="$_gitdir/crew-compose.override.yml"

# Every compose call below this point, ours or a recipe's, goes through the shim. Set only here,
# not for the whole script: --describe and resolution never call docker.
_shim_env() {
  export PATH="$SELF_DIR/shim:$PATH"
  if [ -f "$OVERRIDE" ]; then export CREW_COMPOSE_OVERRIDE="$OVERRIDE"; fi
}

_host() {
  _shim_env
  bash -c 'cd "$1" && eval "$2"' _ "$PROJECT_ROOT" "$CMD"
}

# The shortcut that needs no resolution at all.
if [ "$VIA" = host ] && [ "$DESCRIBE" -eq 0 ]; then _host; exit $?; fi

# _main_root_of <dir> — same as resolve-mode.sh's: `pwd -P` form, so the override path built
# here compares equal to the compose path built from PROJECT_ROOT.
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

RUN=host
FALLBACK=""
SERVICE=""
CONTAINER_SRC=""
COMPOSE_FILE=""

# _resolve_docker — fills the docker globals, or sets FALLBACK to the first missing piece.
_resolve_docker() {
  local verdict name
  verdict="$(bash "$SELF_DIR/resolve-mode.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --no-heuristic 2>/dev/null)"
  # No pipe into grep -q: it exits at its first match, and under pipefail the writer's
  # SIGPIPE would read as "not docker" and run a docker-mode check on the host.
  grep -qx 'INSTALL_MODE=docker' <<< "$verdict" || return 0

  [ -f "$OVERRIDE" ] || { FALLBACK="no ${OVERRIDE:-crew compose override} yet — dep-install has not generated it"; return 0; }
  for name in docker-compose.yml docker-compose.yaml compose.yml; do
    if [ -f "$PROJECT_ROOT/$name" ]; then COMPOSE_FILE="$PROJECT_ROOT/$name"; break; fi
  done
  [ -n "$COMPOSE_FILE" ] || { FALLBACK="no compose file in $PROJECT_ROOT"; return 0; }

  local gen=(bash "$SELF_DIR/gen-override.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT")
  SERVICE="$(printf '%s\n' "$verdict" | sed -n 's/^DOCKER_SERVICE=//p')"
  [ -n "$SERVICE" ] || SERVICE="$("${gen[@]}" --query services 2>/dev/null | head -1)"
  [ -n "$SERVICE" ] || { FALLBACK="no compose service detected"; return 0; }
  CONTAINER_SRC="$("${gen[@]}" --query container-src 2>/dev/null)"
  [ -n "$CONTAINER_SRC" ] || { FALLBACK="no container-side source dir for service $SERVICE"; return 0; }

  RUN=docker
}

if [ "$VIA" != host ]; then _resolve_docker; fi

if [ -z "$VIA" ] && [ -n "$CMD" ]; then
  VIA=host
  if [ "$RUN" = docker ]; then
    if bash "$SELF_DIR/detect-docker-nesting.sh" --dir "$PROJECT_ROOT" --cmd "$CMD"; then VIA=host; else VIA=docker; fi
  fi
fi
# A --via docker from an earlier describe that no longer resolves can only run on the host.
[ "$RUN" = docker ] || VIA=host

if [ "$DESCRIBE" -eq 1 ]; then
  echo "RUN=$RUN"
  if [ "$RUN" = docker ]; then
    echo "SERVICE=$SERVICE"
    echo "CONTAINER_SRC=$CONTAINER_SRC"
    echo "COMPOSE_FILE=$COMPOSE_FILE"
    echo "OVERRIDE=$OVERRIDE"
  fi
  [ -z "$FALLBACK" ] || echo "FALLBACK=$FALLBACK"
  [ -z "$CMD" ] || echo "VIA=$VIA"
  exit 0
fi

[ -z "$FALLBACK" ] || echo "run.sh: docker mode, but $FALLBACK — running on the host" >&2

# MAIN_ROOT is passed to compose for a compose file that interpolates ${MAIN_ROOT}. Compose runs
# from PROJECT_ROOT so the shim finds its compose file the way compose itself would.
case "$VIA" in
  docker)
    _shim_env
    ( cd "$PROJECT_ROOT" && MAIN_ROOT="$MAIN_ROOT" exec docker compose run --rm "$SERVICE" sh -c "cd \"$CONTAINER_SRC\" && $CMD" )
    ;;
  *) _host ;;
esac
