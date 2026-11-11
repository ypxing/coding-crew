#!/usr/bin/env bash
# run.sh — run one project command where this checkout's checks run.
#
# Usage:
#   bash scripts/run.sh --project-root <path> [--full-output] -- <command>
#
# The mode is the clone's dev commands file's "install_mode" (resolve-mode.sh): host,
# or docker, where <command> runs as `docker compose run --rm <service> sh -c 'cd <src> && <command>'`
# through the docker shim, which adds this checkout's override (its dependency volumes). With no
# override yet, docker-install.sh generates it and installs first; a failed install stops here with
# the service, the step and its log, and <command> never runs. A command that runs docker itself runs
# on the host, its own compose calls given the override by the shim.
# Exit code is the command's own, or 1 when the docker install or setup failed.
#
# The command's stdout and stderr go, combined, to a log under <git-dir>/crew-run/ (the newest 20 kept),
# printed unchanged when at most 100 lines. Longer, it prints the first 20 lines, `… <n> lines omitted; full
# output: <log>`, the omitted middle's failure-marker lines (not ok, FAIL, ✖, Error, AssertionError, each with
# 2 lines either side, at most 40) under `… <k> failure-marker lines kept of <n> omitted`, then the last 60.
# --full-output (or no git checkout) passes the output straight through instead.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT="${PROJECT_ROOT:-}"
CMD=""
FULL_OUTPUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)
      if [ $# -lt 2 ]; then echo "Error: $1 requires a value" >&2; exit 2; fi
      PROJECT_ROOT="$2"
      shift 2
      ;;
    --full-output) FULL_OUTPUT=1; shift ;;
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

# _capped <log> — the log as the header says: whole up to 100 lines, else head, kept failure markers, tail.
_capped() {
  awk -v logpath="$1" '{ line[NR] = $0 }
    END {
      if (NR <= 100) { for (i = 1; i <= NR; i++) print line[i]; exit }
      first = 21; last = NR - 60; omitted = last - first + 1
      for (i = 1; i <= 20; i++) print line[i]
      print "… " omitted " lines omitted; full output: " logpath
      # node --test reports a failure only inline in its TAP, so the tail alone can miss it.
      for (i = first; i <= last; i++)
        if (line[i] ~ /not ok|FAIL|✖|Error|AssertionError/)
          for (j = i - 2; j <= i + 2; j++) if (j >= first && j <= last) keep[j] = 1
      k = 0
      for (i = first; i <= last && k < 40; i++) if (i in keep) kept[++k] = line[i]
      if (k) { print "… " k " failure-marker lines kept of " omitted " omitted"; for (i = 1; i <= k; i++) print kept[i] }
      for (i = last + 1; i <= NR; i++) print line[i]
    }' "$1"
}

# _exec <argv>… — runs the command and exits with its code; its output passes through, or is capped.
_exec() {
  local dir log rc
  dir="$_gitdir/crew-run"
  if [ "$FULL_OUTPUT" = 1 ] || [ -z "$_gitdir" ] || ! mkdir -p "$dir" || ! log="$(mktemp "$dir/run.XXXXXX")"; then
    exec "$@"
  fi
  "$@" 2>&1 | cat >"$log"
  rc=${PIPESTATUS[0]}
  _capped "$log"
  # shellcheck disable=SC2012
  ls -1t "$dir" | tail -n +21 | while IFS= read -r old; do rm -f "$dir/$old"; done
  exit "$rc"
}

_host() {
  if [ -f "$OVERRIDE" ]; then export CREW_COMPOSE_OVERRIDE="$OVERRIDE"; fi
  _exec bash -c 'cd "$1" && eval "$2"' _ "$PROJECT_ROOT" "$CMD"
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

# shellcheck source=/dev/null
. "$SELF_DIR/compose-file.sh"
COMPOSE_FILE="$PROJECT_ROOT/$(compose_file "$PROJECT_ROOT")" || _stop "no compose file in $PROJECT_ROOT"

gen=(bash "$SELF_DIR/gen-override.sh" --project-root "$PROJECT_ROOT")
[ -n "$SERVICE" ] || SERVICE="$("${gen[@]}" --query services 2>/dev/null | head -1)"
[ -n "$SERVICE" ] || _stop "no compose service in $COMPOSE_FILE"
CONTAINER_SRC="$("${gen[@]}" --service "$SERVICE" --query container-src)" \
  || _stop "no container-side source dir for service $SERVICE"

export CREW_COMPOSE_OVERRIDE="$OVERRIDE"
cd "$PROJECT_ROOT" && _exec docker compose run --rm "$SERVICE" sh -c "cd \"$CONTAINER_SRC\" && $CMD"
