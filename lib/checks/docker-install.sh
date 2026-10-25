#!/usr/bin/env bash
# Detect and run the right *docker* install command for PROJECT_ROOT — the docker-mode
# sibling of host-install.sh. It fails once and reports why; recovering is docker-install.md's job.
#
# Usage:
#   bash scripts/docker-install.sh --project-root <path> \
#     [--service <name>] [--timeout <sec, default 1800>] [--force] [--skip-env]
# The service and the install command come from the clone's dev commands file ("docker_service",
# "install"; commands-file.sh), and ensure-env.sh runs its "registry_auth"; with no
# docker_service, the compose file's first service. --skip-env does not run ensure-env.sh (no .env,
# registry_auth or *.tpl expansion), for a caller holding a registry token one of those could write
# into the checkout. Generates this checkout's override, then installs only when the root dependency
# volume (named by lockfile hash) lacks a .crew-stamp; --force deletes the stamp first. An install command that runs docker itself (e.g. `make deps` wrapping `docker compose
# run`) runs on the host, as run.sh runs such a check, its compose calls given the override by the shim.
# A failed install removes the override again, so the next run.sh call retries it. Once the override is
# written, prune-volumes.sh removes the repo's volumes no live checkout names any more.
# Exit codes: 0 installed (now or already), 1 argument or filesystem error, 2 nothing to install (no
# compose file, service or ecosystem), 3 install failed (no stamp written)
# Every failure ends with one line on stderr: `docker-install: failed — service <s>, step <step>, exit <n>`.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SELF_DIR/commands-file.sh"

PROJECT_ROOT=""
SERVICE=""
TIMEOUT=1800
FORCE=0
SKIP_ENV=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root|--service|--timeout)
      if [[ $# -lt 2 ]]; then echo "Error: $1 requires a value" >&2; exit 1; fi
      case "$1" in
        --project-root)      PROJECT_ROOT="$2" ;;
        --service)           SERVICE="$2" ;;
        --timeout)           TIMEOUT="$2" ;;
      esac
      shift 2
      ;;
    --force) FORCE=1; shift ;;
    --skip-env) SKIP_ENV=1; shift ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root is required" >&2
  exit 1
fi
if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root does not exist: $PROJECT_ROOT" >&2
  exit 1
fi

GEN_OVERRIDE="$SELF_DIR/gen-override.sh"
OVERRIDE="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
OVERRIDE="${OVERRIDE:+$OVERRIDE/crew-compose.override.yml}"
GENERATED=0

# _fail <exit> <step> <message> — the one way out on failure. Once this run has (re)generated the
# override it goes too: an override is what tells run.sh the install is done.
_fail() {
  echo "$3" >&2
  [[ "$GENERATED" -eq 0 ]] || rm -f "$OVERRIDE"
  echo "docker-install: failed — service ${SERVICE:-<none>}, step $2, exit $1" >&2
  exit "$1"
}

CACHE="$(commands_file "$PROJECT_ROOT")"

ECO_NAME="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --query ecosystem 2>/dev/null || true)"
[[ -n "$ECO_NAME" ]] || _fail 2 detect "No compose file or no supported ecosystem at $PROJECT_ROOT"

[[ -n "$SERVICE" ]] || SERVICE="$(commands_field "$CACHE" docker_service)"
[[ -n "$SERVICE" ]] || SERVICE="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --query services 2>/dev/null | head -1)"
[[ -n "$SERVICE" ]] || _fail 2 detect "No compose service found at $PROJECT_ROOT"

INSTALL_CMD="$(commands_field "$CACHE" install)"

CONTAINER_SRC="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --query container-src 2>/dev/null)"

HOST_CMD=""
if [[ -n "$INSTALL_CMD" ]]; then
  # The container has no docker to nest into.
  if bash "$SELF_DIR/detect-docker-nesting.sh" --dir "$PROJECT_ROOT" --cmd "$INSTALL_CMD"; then HOST_CMD="$INSTALL_CMD"; fi
  CONTAINER_CMD="cd $CONTAINER_SRC && $INSTALL_CMD"
else
  mapfile -t MANIFEST_DIRS < <(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --query manifest-dirs 2>/dev/null)
  [[ ${#MANIFEST_DIRS[@]} -gt 0 ]] || _fail 2 detect "No manifest directories detected at $PROJECT_ROOT"

  STEPS=()
  for dir in "${MANIFEST_DIRS[@]}"; do
    cmd="$(bash "$SELF_DIR/install-cmd.sh" "$dir" "$ECO_NAME")"
    [[ -n "$cmd" ]] || continue
    rel="${dir#"$PROJECT_ROOT"}"
    rel="${rel#/}"
    if [[ -z "$rel" ]]; then
      STEPS+=("cd $CONTAINER_SRC && $cmd")
    else
      STEPS+=("cd $CONTAINER_SRC/$rel && $cmd")
    fi
  done
  [[ ${#STEPS[@]} -gt 0 ]] || _fail 2 detect "No install command matched any manifest directory at $PROJECT_ROOT"

  # IFS joins with its first character only, so join by hand.
  CONTAINER_CMD="${STEPS[0]}"
  for step in "${STEPS[@]:1}"; do CONTAINER_CMD+=" && $step"; done
fi

[[ "$SKIP_ENV" -eq 1 ]] || bash "$SELF_DIR/ensure-env.sh" --project-root "$PROJECT_ROOT" >/dev/null 2>&1 || true

[[ -n "$OVERRIDE" ]] || _fail 1 "generate override" "$PROJECT_ROOT is not a git checkout — the override is written to its git dir"
GENERATED=1
GEN_OUT="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" 2>&1)" \
  || _fail 1 "generate override" "gen-override.sh failed: $GEN_OUT"
bash "$SELF_DIR/prune-volumes.sh" --project-root "$PROJECT_ROOT"

# The stamp lives in the first (root) dependency volume: only an install that ran fills it.
STAMP_DIR="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --query vendor-paths 2>/dev/null | head -1)"
[[ -n "$STAMP_DIR" ]] || _fail 2 detect "No dependency volume to install into at $PROJECT_ROOT"

TIMEOUT_BIN=""
for _t in timeout gtimeout; do
  command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }
done

# The shim adds this checkout's override as the last -f of every compose call, ours or a host-run install's.
export PATH="$SELF_DIR/shim:$PATH"
export CREW_COMPOSE_OVERRIDE="$OVERRIDE"

# An empty command only looks for the stamp (deleting it under --force) and writes none.
CONTAINER_SCRIPT='
v=$1; force=$2; cmd=$3; stamp="$v/.crew-stamp"
if [ "$force" != 1 ] && [ -f "$stamp" ]; then echo "crew-stamp: present"; exit 0; fi
mkdir -p "$v" && rm -f "$stamp" || exit 1
[ -n "$cmd" ] || exit 0
( eval "$cmd" ) || exit $?
date -u +%Y-%m-%dT%H:%M:%SZ > "$stamp"
'

OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

# _run <cmd…> — in PROJECT_ROOT under the timeout, tee'd, so a foreground caller sees install output live.
_run() {
  ( cd "$PROJECT_ROOT" && ${TIMEOUT_BIN:+"$TIMEOUT_BIN" "$TIMEOUT"} "$@" ) 2>&1 | tee -a "$OUT_FILE"
  return "${PIPESTATUS[0]}"
}
_container() { _run docker compose run --rm "$SERVICE" sh -c "$CONTAINER_SCRIPT" _ "$STAMP_DIR" "$@"; }

WHERE="inside service $SERVICE"
if [[ -z "$HOST_CMD" ]]; then
  echo "Running: docker compose run --rm $SERVICE sh -c '$CONTAINER_CMD'"
  _container "$FORCE" "$CONTAINER_CMD"; RC=$?
else
  _container "$FORCE" ""; RC=$?
  if [[ "$RC" -eq 0 ]] && ! grep -qx 'crew-stamp: present' "$OUT_FILE"; then
    echo "Running on the host, as it runs docker itself: $HOST_CMD"
    _run bash -c "$HOST_CMD"; RC=$?
    # Written only now, so a failed host install leaves no stamp.
    if [[ "$RC" -ne 0 ]]; then WHERE="on the host ('$HOST_CMD', which runs docker itself)"
    else _container 1 ":"; RC=$?
    fi
  fi
fi
if [[ "$RC" -ne 0 ]]; then
  {
    echo "--- install output (tail) ---"
    tail -n 20 "$OUT_FILE"
    echo "--- end ---"
  } >&2
  _fail 3 install "The install failed $WHERE (exit $RC); no stamp was written."
fi
if grep -qx 'crew-stamp: present' "$OUT_FILE"; then
  echo "Present: $STAMP_DIR/.crew-stamp found — the dependency volumes are already installed"
fi
exit 0
