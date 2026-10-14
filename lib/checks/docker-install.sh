#!/usr/bin/env bash
# Detect and run the right *docker* install command for PROJECT_ROOT — the docker-mode
# sibling of host-install.sh. It fails once and reports why; recovering is docker-install.md's job.
#
# Usage:
#   bash scripts/docker-install.sh --project-root <path> \
#     [--service <name>] [--install-cmd <cmd>] [--credential-target <command>] \
#     [--timeout <sec, default 1800>] [--force]
# The service, the install command and the credential target default to the checkout's
# .coding-crew/dev-commands.json ("docker_service", "install", "credential_target"); with no
# docker_service, the compose file's first service. Generates this checkout's override, then installs
# only when the root dependency volume (named by lockfile hash) lacks a .crew-stamp; --force deletes
# the stamp first. A failed install removes the override again, so the next run.sh call retries it.
# Exit codes: 0 installed (now or already), 1 argument or filesystem error, 2 nothing to install (no
# compose file, service or ecosystem), 3 install failed (no stamp written), 5 the install command runs
# docker itself, which a container has none of
# Every failure ends with one line on stderr: `docker-install: failed — service <s>, step <step>, exit <n>`.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT=""
SERVICE=""
INSTALL_CMD=""
CREDENTIAL_TARGET=""
TIMEOUT=1800
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root|--service|--install-cmd|--credential-target|--timeout)
      if [[ $# -lt 2 ]]; then echo "Error: $1 requires a value" >&2; exit 1; fi
      case "$1" in
        --project-root)      PROJECT_ROOT="$2" ;;
        --service)           SERVICE="$2" ;;
        --install-cmd)       INSTALL_CMD="$2" ;;
        --credential-target) CREDENTIAL_TARGET="$2" ;;
        --timeout)           TIMEOUT="$2" ;;
      esac
      shift 2
      ;;
    --force) FORCE=1; shift ;;
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

_cached() {
  local cache="$PROJECT_ROOT/.coding-crew/dev-commands.json"
  [[ -f "$cache" ]] || return 0
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$cache" 2>/dev/null \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true
}

ECO_NAME="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --query ecosystem 2>/dev/null || true)"
[[ -n "$ECO_NAME" ]] || _fail 2 detect "No compose file or no supported ecosystem at $PROJECT_ROOT"

[[ -n "$SERVICE" ]] || SERVICE="$(_cached docker_service)"
[[ -n "$SERVICE" ]] || SERVICE="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --query services 2>/dev/null | head -1)"
[[ -n "$SERVICE" ]] || _fail 2 detect "No compose service found at $PROJECT_ROOT"

[[ -n "$INSTALL_CMD" ]] || INSTALL_CMD="$(_cached install)"
[[ -n "$CREDENTIAL_TARGET" ]] || CREDENTIAL_TARGET="$(_cached credential_target)"

CONTAINER_SRC="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --query container-src 2>/dev/null)"

if [[ -n "$INSTALL_CMD" ]]; then
  if bash "$SELF_DIR/detect-docker-nesting.sh" --dir "$PROJECT_ROOT" --cmd "$INSTALL_CMD"; then
    _fail 5 "install command" "Install command '$INSTALL_CMD' runs docker itself, and the service's container has no docker to run it with. Name a container-side install command (e.g. 'pnpm install') as \"install\" in .coding-crew/dev-commands.json."
  fi
  CONTAINER_CMD="cd $CONTAINER_SRC && $INSTALL_CMD"
else
  mapfile -t MANIFEST_DIRS < <(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --query manifest-dirs 2>/dev/null)
  [[ ${#MANIFEST_DIRS[@]} -gt 0 ]] || _fail 2 detect "No manifest directories detected at $PROJECT_ROOT"

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
  [[ ${#STEPS[@]} -gt 0 ]] || _fail 2 detect "No install command matched any manifest directory at $PROJECT_ROOT"

  CONTAINER_CMD="$(IFS=' && '; echo "${STEPS[*]}")"
fi

ENV_ARGS=(--project-root "$PROJECT_ROOT")
[[ -n "$CREDENTIAL_TARGET" ]] && ENV_ARGS+=(--credential-target "$CREDENTIAL_TARGET")
bash "$SELF_DIR/ensure-env.sh" "${ENV_ARGS[@]}" >/dev/null 2>&1 || true

[[ -n "$OVERRIDE" ]] || _fail 1 "generate override" "$PROJECT_ROOT is not a git checkout — the override is written to its git dir"
GENERATED=1
GEN_OUT="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" 2>&1)" \
  || _fail 1 "generate override" "gen-override.sh failed: $GEN_OUT"

# The stamp lives in the first (root) dependency volume: only an install that ran fills it.
STAMP_DIR="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --query vendor-paths 2>/dev/null | head -1)"
[[ -n "$STAMP_DIR" ]] || _fail 2 detect "No dependency volume to install into at $PROJECT_ROOT"

TIMEOUT_BIN=""
for _t in timeout gtimeout; do
  command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }
done

# The shim adds this checkout's override as the last -f of the compose call.
export PATH="$SELF_DIR/shim:$PATH"
export CREW_COMPOSE_OVERRIDE="$OVERRIDE"

CONTAINER_SCRIPT='
v=$1; force=$2; cmd=$3; stamp="$v/.crew-stamp"
if [ "$force" != 1 ] && [ -f "$stamp" ]; then echo "crew-stamp: present"; exit 0; fi
mkdir -p "$v" && rm -f "$stamp" || exit 1
( eval "$cmd" ) || exit $?
date -u +%Y-%m-%dT%H:%M:%SZ > "$stamp"
'

OUT_FILE="$(mktemp)"
trap 'rm -f "$OUT_FILE"' EXIT

echo "Running: docker compose run --rm $SERVICE sh -c '$CONTAINER_CMD'"
# tee'd, so a foreground caller sees install output live.
( cd "$PROJECT_ROOT" && ${TIMEOUT_BIN:+"$TIMEOUT_BIN" "$TIMEOUT"} \
    docker compose run --rm "$SERVICE" sh -c "$CONTAINER_SCRIPT" _ "$STAMP_DIR" "$FORCE" "$CONTAINER_CMD" ) 2>&1 \
  | tee "$OUT_FILE"
RC=${PIPESTATUS[0]}
if [[ "$RC" -ne 0 ]]; then
  {
    echo "--- docker compose output (tail) ---"
    tail -n 20 "$OUT_FILE"
    echo "--- end ---"
  } >&2
  _fail 3 install "The install failed inside service $SERVICE (exit $RC); no stamp was written."
fi
if grep -qx 'crew-stamp: present' "$OUT_FILE"; then
  echo "Present: $STAMP_DIR/.crew-stamp found — the dependency volumes are already installed"
fi
exit 0
