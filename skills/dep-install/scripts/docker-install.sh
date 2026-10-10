#!/usr/bin/env bash
# Detect and run the right *docker* install command for PROJECT_ROOT — the docker-mode
# sibling of host-install.sh. No judgement of its own: env setup, override generation, and
# the ecosystem-to-command table are all deterministic, so this is safe for a mechanism
# (ensure-deps.sh) to call, the same way host-install.sh already is on the host path.
#
# What stays out of this script, on purpose:
#   - Reading the Makefile for a credential-generation target (ensure-env.sh's
#     --credential-target) — that needs a model reading prose, so this always calls
#     ensure-env.sh without one. A project whose install genuinely needs it still gets
#     the full dep-install skill guide, on demand, the same as an install command this
#     script gets wrong for any other reason.
#   - Recovering from a failure by trying a different entrypoint, a different service, or
#     asking for credentials — docker-install.md's "Install failures" section is judgement;
#     this script fails once and reports why.
#
# Usage:
#   bash scripts/docker-install.sh --project-root <path> --main-root <path> \
#     [--service <name>] [--install-cmd <cmd>] [--credential-target <command>] \
#     [--timeout <sec, default 1800>] [--force]
#
# Install-if-missing. The dependency volumes this worktree's override names carry the lockfile
# hash (gen-override.sh), so a stamp in them proves they hold what these lockfiles describe. In one
# `docker compose run --rm <service> sh -c …` this script:
#   1. exits "present" when <root vendor path>/.crew-stamp exists — no install command runs;
#   2. otherwise takes <state path>/.crew-lock (mkdir, its start epoch written inside). The lock lives
#      in the override's state volume, not a dependency volume: an install that empties the vendor
#      directory (`npm ci`) must not delete the lock that guards it. Waiting is bounded by
#      --timeout: a lock older than --timeout is removed and taken over;
#   3. re-checks the stamp, installs, writes the stamp, and removes the lock on every exit path
#      it can (a SIGKILL leaves the lock; step 2's stale rule recovers it).
# The volume is shared, so nobody reinstalls into a volume another run is reading: whoever finds the stamp
# present is done, and a failed install writes no stamp.
#
# --force deletes the stamp first (under the lock), then installs: dep-install's own retry rule
# uses it on a module-not-found error, when a present stamp would otherwise make the retry a no-op.
#
# --install-cmd is a documented project override (e.g. dev-commands.json's discovered
# "install" field, forwarded by ensure-deps.sh) — it takes priority over the per-manifest
# lockfile table below, the same way host-install.sh's own Makefile check already takes
# priority over its signal-file fallback on the host path. One that runs docker itself
# (detect-docker-nesting.sh) runs on the host instead of inside the service: nesting it would
# need a docker CLI the container does not have. Its own `docker compose` call runs the install
# in a container and gets this worktree's crew override from the docker shim on PATH, whatever
# `-f`/`COMPOSE_FILE`/`-p` it uses. The lock is taken before it and released after it, each in a
# container run of its own. A `docker run`/`docker exec` call loads no compose file, so it
# is refused up front when detect-compose-bypass.sh sees one (exit 5), and the volumes are probed
# from the service afterwards (exit 5 again when every one is still empty, and no stamp is written).
#
# --credential-target is the same kind of forwarded override for dev-commands.json's
# "credential_target" field — a full command (e.g. "make _registry"), passed straight through
# to ensure-env.sh, unexamined (ensure-env.sh is the one that runs it through
# detect-docker-nesting.sh before eval'ing it), the same way dep-install's own docker-install.md
# tells a model to pass whatever it found scanning the Makefile by hand. Omitted (the default)
# when no cache entry exists: ensure-env.sh's own template-expansion fallback still applies.
#
# Output: "Running: docker compose run --rm <service> sh -c '<install>'" before the run, and, when
# the stamp was already there, a "Present: …" line after it.
#
# Exit codes:
#   0  the volumes hold the install: it ran successfully, or the stamp was already present
#   1  argument or filesystem error
#   2  nothing to do here: no compose file, no service, or no supported ecosystem
#   3  install command failed inside the container (no stamp written, lock removed)
#   5  --install-cmd runs docker in a way that would not reach the shared volumes the checks
#      read (`docker run`/`docker exec`) — refused before running, or still empty after it ran
#      (reasons on stderr)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT=""
MAIN_ROOT=""
SERVICE=""
INSTALL_CMD_OVERRIDE=""
CREDENTIAL_TARGET=""
TIMEOUT=1800
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)  PROJECT_ROOT="$2"; shift 2 ;;
    --main-root)     MAIN_ROOT="$2";    shift 2 ;;
    --service)       SERVICE="$2";      shift 2 ;;
    --install-cmd)   INSTALL_CMD_OVERRIDE="$2"; shift 2 ;;
    --credential-target) CREDENTIAL_TARGET="$2"; shift 2 ;;
    --timeout)       TIMEOUT="$2";      shift 2 ;;
    --force)         FORCE=1;           shift   ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" || -z "$MAIN_ROOT" ]]; then
  echo "Error: --project-root and --main-root are required" >&2
  exit 1
fi
if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root does not exist: $PROJECT_ROOT" >&2
  exit 1
fi
if [[ ! -d "$MAIN_ROOT" ]]; then
  echo "Error: --main-root does not exist: $MAIN_ROOT" >&2
  exit 1
fi

GEN_OVERRIDE="$SELF_DIR/gen-override.sh"
ENSURE_ENV="$SELF_DIR/ensure-env.sh"
if [[ ! -f "$GEN_OVERRIDE" ]]; then
  echo "Error: gen-override.sh not found next to $0" >&2
  exit 1
fi

# ─── 1. resolve what to run ──────────────────────────────────────────────────
# All of this is read-only detection; only the install step below mutates shared state.

ECO_NAME="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query ecosystem 2>/dev/null || true)"
if [[ -z "$ECO_NAME" ]]; then
  echo "No compose file or no supported ecosystem at $PROJECT_ROOT" >&2
  exit 2
fi

if [[ -z "$SERVICE" ]]; then
  SERVICE="$(git -C "$PROJECT_ROOT" config --local agent.install-service 2>/dev/null || true)"
fi
if [[ -z "$SERVICE" ]] && [[ -f "$MAIN_ROOT/.coding-crew/dev-commands.json" ]]; then
  SERVICE="$(grep -o '"docker_service"[[:space:]]*:[[:space:]]*"[^"]*"' "$MAIN_ROOT/.coding-crew/dev-commands.json" 2>/dev/null \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true)"
fi
if [[ -z "$SERVICE" ]]; then
  SERVICE="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query services 2>/dev/null | head -1)"
fi
if [[ -z "$SERVICE" ]]; then
  echo "No compose service found at $PROJECT_ROOT" >&2
  exit 2
fi

CONTAINER_SRC="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query container-src 2>/dev/null)"

HOST_CMD=""
if [[ -n "$INSTALL_CMD_OVERRIDE" ]] &&
   bash "$SELF_DIR/detect-docker-nesting.sh" --dir "$PROJECT_ROOT" --cmd "$INSTALL_CMD_OVERRIDE"; then
  if BYPASS="$(bash "$SELF_DIR/detect-compose-bypass.sh" --dir "$PROJECT_ROOT" --cmd "$INSTALL_CMD_OVERRIDE")"; then
    {
      echo "Install command '$INSTALL_CMD_OVERRIDE' runs docker itself, but not through docker compose — which loads the crew override that mounts the shared dependency volumes the checks run against — so it would install where they never look:"
      printf '  %s\n' "$BYPASS"
      echo "Make its docker call a 'docker compose run', or name a container-side install command (e.g. 'pnpm install') as \"install\" in .coding-crew/dev-commands.json."
    } >&2
    exit 5
  fi
  # Run on the host, where its own docker call resolves — see --install-cmd above.
  HOST_CMD="$INSTALL_CMD_OVERRIDE"
elif [[ -n "$INSTALL_CMD_OVERRIDE" ]]; then
  # The documented override runs once, at the container-side project root — it is a
  # project's own answer to "how do I install", not a per-manifest-dir heuristic, so the
  # lockfile table and its manifest-dirs requirement below are skipped entirely.
  CONTAINER_CMD="cd $CONTAINER_SRC && $INSTALL_CMD_OVERRIDE"
else
  mapfile -t MANIFEST_DIRS < <(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query manifest-dirs 2>/dev/null)
  if [[ ${#MANIFEST_DIRS[@]} -eq 0 ]]; then
    echo "No manifest directories detected at $PROJECT_ROOT" >&2
    exit 2
  fi

  # _install_cmd_for_dir <dir> — the same per-directory signal-file priority
  # host-install.sh's own table uses, so a project installs the same way in both modes.
  _install_cmd_for_dir() {
    local d="$1"
    if   [[ -f "$d/uv.lock"           ]]; then echo "uv sync --frozen"
    elif [[ -f "$d/bun.lockb"         ]]; then echo "bun install --frozen-lockfile"
    elif [[ -f "$d/pnpm-lock.yaml"    ]]; then echo "pnpm install --frozen-lockfile"
    elif [[ -f "$d/package-lock.json" ]]; then echo "npm ci"
    elif [[ -f "$d/yarn.lock"         ]]; then echo "yarn install --frozen-lockfile"
    elif [[ -f "$d/poetry.lock"       ]]; then echo "poetry install --no-root"
    elif [[ -f "$d/requirements.txt" || -f "$d/pyproject.toml" ]]; then bash "$SELF_DIR/python-install-cmd.sh" "$d"
    elif [[ -f "$d/Gemfile.lock"      ]]; then echo "bundle install"
    elif [[ -f "$d/Cargo.toml"        ]]; then echo "cargo fetch"
    elif [[ -f "$d/composer.json"     ]]; then echo "composer install --no-interaction"
    elif [[ -f "$d/go.sum" || -f "$d/go.mod" ]]; then echo "go mod download"
    fi
  }

  STEPS=()
  for dir in "${MANIFEST_DIRS[@]}"; do
    cmd="$(_install_cmd_for_dir "$dir")"
    [[ -n "$cmd" ]] || continue
    rel="${dir#"$PROJECT_ROOT"}"
    rel="${rel#/}"
    if [[ -z "$rel" ]]; then
      STEPS+=("cd $CONTAINER_SRC && $cmd")
    else
      STEPS+=("cd $CONTAINER_SRC/$rel && $cmd")
    fi
  done

  if [[ ${#STEPS[@]} -eq 0 ]]; then
    echo "No install command matched any manifest directory at $PROJECT_ROOT" >&2
    exit 2
  fi

  CONTAINER_CMD="$(IFS=' && '; echo "${STEPS[*]}")"
fi

# ─── 2. env + override ───────────────────────────────────────────────────────
# The override names the volumes by this worktree's lockfile hash, so it is written before the
# stamp is looked for: a changed lockfile means different volumes, and their own stamp.
if [[ -f "$ENSURE_ENV" ]]; then
  ENV_ARGS=(--project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT")
  [[ -n "$CREDENTIAL_TARGET" ]] && ENV_ARGS+=(--credential-target "$CREDENTIAL_TARGET")
  bash "$ENSURE_ENV" "${ENV_ARGS[@]}" >/dev/null 2>&1 || true
fi
bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" >/dev/null

# The stamp lives in the first dependency volume (the root one when there is one): a volume is only
# ever filled by an install that ran, so its stamp is the proof one did. The lock lives in the state
# volume (STATE_PATH below).
STAMP_DIR="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query vendor-paths 2>/dev/null | head -1)"
if [[ -z "$STAMP_DIR" ]]; then
  echo "No dependency volume to install into at $PROJECT_ROOT" >&2
  exit 2
fi

STATE_PATH="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query state-path 2>/dev/null | head -1)"
if [[ -z "$STATE_PATH" ]]; then
  echo "No state volume to lock in at $PROJECT_ROOT" >&2
  exit 2
fi

TIMEOUT_BIN=""
for _t in timeout gtimeout; do
  command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }
done

_has_compose=0
for _name in docker-compose.yml docker-compose.yaml compose.yml; do
  [[ -f "$PROJECT_ROOT/$_name" ]] && { _has_compose=1; break; }
done
if [[ "$_has_compose" -eq 0 ]]; then
  echo "Error: no compose file found in $PROJECT_ROOT" >&2
  exit 2
fi

# Every compose call below — ours, and a host-run install command's own — goes through the docker
# shim, which adds this worktree's crew override (written just above) as the last -f.
export PATH="$SELF_DIR/shim:$PATH"
OVERRIDE="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)/crew-compose.override.yml"
export CREW_COMPOSE_OVERRIDE="$OVERRIDE"

# Compose runs from PROJECT_ROOT, where the shim finds the compose file.
COMPOSE_RUN=(bash -c 'cd "$1" && shift && exec "$@"' _ "$PROJECT_ROOT" docker compose run --rm)

# The container-side half: one POSIX sh script, told what to do by its first argument.
#   run          present → done; else take the lock, re-check, install, stamp, unlock
#   lock         present → done; else take the lock and leave it held (a host-run install follows)
#   unlock-ok    write the stamp, then release the lock
#   unlock-fail  release the lock
# `mkdir` is the lock primitive: atomic everywhere this runs and it needs no extra binary. The
# start epoch inside it is what makes a lock left by a SIGKILLed holder recoverable.
# Arguments: <mode> <stamp dir> <timeout> <force 0|1> <install command> <state dir>
CONTAINER_SCRIPT='
mode=$1; v=$2; t=$3; force=$4; cmd=$5; s=$6
stamp="$v/.crew-stamp"; lock="$s/.crew-lock"; keep=0
unlock() { rm -f "$1/started"; rmdir "$1" 2>/dev/null; }
mkdir -p "$v" "$s" || exit 1
case "$mode" in
  unlock-ok) date -u +%Y-%m-%dT%H:%M:%SZ > "$stamp"; unlock "$lock"; exit 0 ;;
  unlock-fail) unlock "$lock"; exit 0 ;;
esac
present() { echo "crew-stamp: present"; exit 0; }
if [ "$force" != 1 ] && [ -f "$stamp" ]; then present; fi
waited=0
while ! mkdir "$lock" 2>/dev/null; do
  if [ "$force" != 1 ] && [ -f "$stamp" ]; then present; fi
  if [ ! -d "$lock" ]; then
    # no holder: the holder may have just released it (try once more), else the path is unusable
    if mkdir "$lock" 2>/dev/null; then break; fi
    if [ ! -d "$lock" ]; then
      echo "crew-lock: cannot create the install lock at $lock and no other holder has it (is $s writable by this user?)" >&2
      exit 1
    fi
  fi
  started=$(cat "$lock/started" 2>/dev/null)
  case "$started" in ""|*[!0-9]*) started="" ;; esac
  if [ -n "$started" ]; then age=$(( $(date +%s) - started )); else age=$waited; fi
  if [ "$age" -gt "$t" ]; then
    echo "crew-lock: taking over a lock older than ${t}s" >&2
    if mv "$lock" "$lock.stale.$$" 2>/dev/null; then unlock "$lock.stale.$$"; continue; fi
  fi
  sleep 1
  waited=$((waited + 1))
done
trap '"'"'if [ "$keep" = 0 ]; then unlock "$lock"; fi'"'"' EXIT
trap "exit 143" HUP INT TERM
date +%s > "$lock/started"
if [ "$force" != 1 ] && [ -f "$stamp" ]; then present; fi
rm -f "$stamp"
if [ "$mode" = lock ]; then keep=1; exit 0; fi
( eval "$cmd" ) || exit $?
date -u +%Y-%m-%dT%H:%M:%SZ > "$stamp"
'

# _container <mode> [install command] — sets CONTAINER_ARGV to one container run of CONTAINER_SCRIPT.
# The lock and unlock runs skip the service's entrypoint and its dependencies: they only touch
# the volume.
CONTAINER_ARGV=()
_container() {
  local mode="$1" cmd="${2:-}"
  case "$mode" in
    run) CONTAINER_ARGV=("${COMPOSE_RUN[@]}" "$SERVICE" sh -c "$CONTAINER_SCRIPT" _ run "$STAMP_DIR" "$TIMEOUT" "$FORCE" "$cmd" "$STATE_PATH") ;;
    *)   CONTAINER_ARGV=("${COMPOSE_RUN[@]}" --no-deps --entrypoint sh "$SERVICE" -c "$CONTAINER_SCRIPT" _ "$mode" "$STAMP_DIR" "$TIMEOUT" "$FORCE" "$cmd" "$STATE_PATH") ;;
  esac
}

# The state volume is a fresh named volume Docker mounts root-owned (no image ships the path), so
# a service running as a non-root user could not create the lock in it. One root run opens it up
# (sticky and world-writable, like /tmp) before any lock is taken; best-effort — if it fails the
# lock's own error names the path.
${TIMEOUT_BIN:+"$TIMEOUT_BIN" 120} "${COMPOSE_RUN[@]}" --no-deps --user=0 --entrypoint sh "$SERVICE" \
  -c 'mkdir -p "$1" && chmod 1777 "$1"' _ "$STATE_PATH" >/dev/null 2>&1 || true

OUT_FILE="$(mktemp)"
LOCK_HELD=0
_cleanup() {
  # A host-run install holds the lock across container runs: release it on every exit path.
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    LOCK_HELD=0
    _container unlock-fail
    "${CONTAINER_ARGV[@]}" >/dev/null 2>&1 || true
  fi
  rm -f "$OUT_FILE"
}
trap _cleanup EXIT

_present() {
  echo "Present: $STAMP_DIR/.crew-stamp found — the dependency volumes are already installed"
  exit 0
}

# _stream <cap seconds> <command...> — run it with its output streamed live (via tee, not just captured: a
# caller in the foreground otherwise sees nothing for however long an install takes) and kept in
# $OUT_FILE for the tail-on-failure diagnostic. PIPESTATUS[0] (not plain $?) reads the command's
# own exit code through the pipe to tee.
_stream() {
  local cap="$1" rc
  shift
  if [[ -n "$TIMEOUT_BIN" ]]; then
    "$TIMEOUT_BIN" "$cap" "$@" 2>&1 | tee "$OUT_FILE"
    rc=${PIPESTATUS[0]}
  else
    "$@" 2>&1 | tee "$OUT_FILE"
    rc=${PIPESTATUS[0]}
  fi
  return "$rc"
}

_fail_tail() {
  echo "--- docker compose output (tail) ---" >&2
  tail -n 20 "$OUT_FILE" >&2
  echo "--- end ---" >&2
}

# A container run may wait up to --timeout for another holder's lock (after which it takes the
# lock over) and then install for up to --timeout, so its wall-clock cap is both.
RUN_CAP=$((2 * TIMEOUT + 10))

# ─── 3. install ──────────────────────────────────────────────────────────────
if [[ -z "$HOST_CMD" ]]; then
  echo "Running: docker compose run --rm $SERVICE sh -c '$CONTAINER_CMD'"
  _container run "$CONTAINER_CMD"
  _stream "$RUN_CAP" "${CONTAINER_ARGV[@]}"
  RC=$?
  if [[ "$RC" -ne 0 ]]; then
    _fail_tail
    exit 3
  fi
  if grep -qx 'crew-stamp: present' "$OUT_FILE"; then _present; fi
  exit 0
fi

# A host-run install: the lock is taken before it and released after it, in container runs of
# their own, since the command itself reaches the volumes through its own docker calls.
_container lock
_stream "$RUN_CAP" "${CONTAINER_ARGV[@]}"
RC=$?
if [[ "$RC" -ne 0 ]]; then
  _fail_tail
  exit 3
fi
if grep -qx 'crew-stamp: present' "$OUT_FILE"; then _present; fi
LOCK_HELD=1

echo "Running: $HOST_CMD (on the host — it runs docker itself)"
_stream "$TIMEOUT" bash -c 'cd "$1" && eval "$2"' _ "$PROJECT_ROOT" "$HOST_CMD"
RC=$?
if [[ "$RC" -ne 0 ]]; then
  _fail_tail
  exit 3
fi

# ─── 4. a host-run install: prove it reached the volumes ─────────────────────
# detect-compose-bypass.sh only sees what `make -n` can expand. Whatever it missed, this looks
# where the checks will: from the service, through the override, at each dep volume's path.
# One non-empty volume is enough — a workspace's sub-packages may legitimately have none. The
# lock and stamp files in the root volume do not count as an install.
mapfile -t VENDOR_PATHS < <(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query vendor-paths 2>/dev/null)
if ((${#VENDOR_PATHS[@]})); then
  # Exit 7 is the probe's own "all empty", so a compose or daemon failure is not read as one.
  "${COMPOSE_RUN[@]}" --no-deps --entrypoint sh "$SERVICE" \
    -c 'for d in "$@"; do [ -n "$(ls -A "$d" 2>/dev/null | grep -v "^[.]crew-")" ] && exit 0; done; exit 7' _ "${VENDOR_PATHS[@]}" \
    >"$OUT_FILE" 2>&1
  PROBE_RC=$?
  if [[ "$PROBE_RC" -ne 0 ]]; then
    {
      if [[ "$PROBE_RC" -eq 7 ]]; then
        echo "Install command '$HOST_CMD' succeeded, but the dependency volumes the checks run against are still empty, seen from service $SERVICE:"
        printf '  %s\n' "${VENDOR_PATHS[@]}"
        echo "Its docker call installed somewhere else. Make it a 'docker compose run', or name a container-side install command (e.g. 'pnpm install') as \"install\" in .coding-crew/dev-commands.json."
      else
        echo "Install command '$HOST_CMD' succeeded, but checking that it reached the dependency volumes failed (exit $PROBE_RC):"
        tail -n 20 "$OUT_FILE"
      fi
    } >&2
    exit 5
  fi
fi

_container unlock-ok
if ! "${CONTAINER_ARGV[@]}" >"$OUT_FILE" 2>&1; then
  _fail_tail
  exit 3 # the stamp was not written; the exit trap tries releasing the lock once more
fi
LOCK_HELD=0
exit 0
