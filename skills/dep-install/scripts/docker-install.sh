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
#     [--service <name>] [--timeout <sec, default 600>] [--lock-timeout <sec, default 30>]
#
# Exit codes:
#   0  install ran successfully ("Running: docker compose run --rm <service> ..." on stdout)
#   1  argument or filesystem error
#   2  nothing to do here: no compose file, no service, or no supported ecosystem
#   3  install command failed inside the container
#   4  could not acquire the install lock within --lock-timeout — another install (this
#      script or a worker's own dep-install invocation) is already in flight; the caller
#      should treat this the same as "docker, deferred" rather than block on it

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT=""
MAIN_ROOT=""
SERVICE=""
TIMEOUT=600
LOCK_TIMEOUT=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root)  PROJECT_ROOT="$2"; shift 2 ;;
    --main-root)     MAIN_ROOT="$2";    shift 2 ;;
    --service)       SERVICE="$2";      shift 2 ;;
    --timeout)       TIMEOUT="$2";      shift 2 ;;
    --lock-timeout)  LOCK_TIMEOUT="$2"; shift 2 ;;
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

# ─── 1. resolve what to run, before taking the lock ──────────────────────────
# All of this is read-only detection; only the install step below mutates shared state.

ECO_NAME="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query ecosystem 2>/dev/null || true)"
if [[ -z "$ECO_NAME" ]]; then
  echo "No compose file or no supported ecosystem at $PROJECT_ROOT" >&2
  exit 2
fi

if [[ -z "$SERVICE" ]]; then
  SERVICE="$(git -C "$PROJECT_ROOT" config --local agent.install-service 2>/dev/null || true)"
fi
if [[ -z "$SERVICE" ]]; then
  SERVICE="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query services 2>/dev/null | head -1)"
fi
if [[ -z "$SERVICE" ]]; then
  echo "No compose service found at $PROJECT_ROOT" >&2
  exit 2
fi

CONTAINER_SRC="$(bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query container-src 2>/dev/null)"
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
  elif [[ -f "$d/requirements.txt"  ]]; then echo "pip install -r requirements.txt --quiet"
  elif [[ -f "$d/pyproject.toml"    ]]; then echo "pip install --quiet ."
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

# ─── 2. the lock ──────────────────────────────────────────────────────────────
# Named volumes are shared across every worktree of this MAIN_ROOT by design (that is the
# whole point of caching deps once) — so the one thing that must never run twice at once is
# the install command itself. `mkdir` is the lock primitive because it is atomic on every
# filesystem this runs on and needs no extra binary (flock ships on Linux, not on macOS).
LOCK_DIR="$MAIN_ROOT/.scratch/.docker-install.lock"
mkdir -p "$MAIN_ROOT/.scratch" 2>/dev/null || true

_waited=0
until mkdir "$LOCK_DIR" 2>/dev/null; do
  _waited=$((_waited + 1))
  if [[ "$_waited" -ge "$LOCK_TIMEOUT" ]]; then
    echo "Could not acquire $LOCK_DIR within ${LOCK_TIMEOUT}s — another docker install is in flight" >&2
    exit 4
  fi
  sleep 1
done

# ─── 3. env + override, then install ─────────────────────────────────────────
if [[ -f "$ENSURE_ENV" ]]; then
  bash "$ENSURE_ENV" --project-root "$PROJECT_ROOT" >/dev/null 2>&1 || true
fi
bash "$GEN_OVERRIDE" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" >/dev/null

TIMEOUT_BIN=""
for _t in timeout gtimeout; do
  command -v "$_t" >/dev/null 2>&1 && { TIMEOUT_BIN="$_t"; break; }
done

COMPOSE_FILE=""
for _name in docker-compose.yml docker-compose.yaml compose.yml; do
  if [[ -f "$PROJECT_ROOT/$_name" ]]; then
    COMPOSE_FILE="$PROJECT_ROOT/$_name"
    break
  fi
done
if [[ -z "$COMPOSE_FILE" ]]; then
  echo "Error: no compose file found in $PROJECT_ROOT" >&2
  exit 2
fi

RUN_CMD=(docker compose
  -f "$COMPOSE_FILE"
  -f "$MAIN_ROOT/docker-compose.override.yml"
  run --rm "$SERVICE" sh -c "$CONTAINER_CMD")

OUT_FILE="$(mktemp)"
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true; rm -f "$OUT_FILE"' EXIT

echo "Running: docker compose run --rm $SERVICE sh -c '$CONTAINER_CMD'"
if [[ -n "$TIMEOUT_BIN" ]]; then
  "$TIMEOUT_BIN" "$TIMEOUT" "${RUN_CMD[@]}" >"$OUT_FILE" 2>&1
else
  "${RUN_CMD[@]}" >"$OUT_FILE" 2>&1
fi
RC=$?

if [[ "$RC" -ne 0 ]]; then
  echo "--- docker compose output (tail) ---" >&2
  tail -n 20 "$OUT_FILE" >&2
  echo "--- end ---" >&2
  exit 3
fi

cat "$OUT_FILE"
exit 0
