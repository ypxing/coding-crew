#!/usr/bin/env bash
# Generate this worktree's crew compose override deterministically from the project's manifest files.
#
# Usage:
#   bash scripts/gen-override.sh --project-root /path/to/worktree --main-root /path/to/main
#     [--sandbox] [--dry-run] [--query <field>]
#
#   --sandbox        Add proxy env vars + CA bundle. Default: read IS_SANDBOX env var.
#   --dry-run        Print generated YAML to stdout instead of writing the file.
#   --query <field>  Print one detected fact and exit: services | ecosystem | container-src |
#                    manifest-dirs | platform | project-name | vendor-paths | state-path | owner-prefix
# Writes <project-root's git dir>/crew-compose.override.yml; the docker shim adds it as the last -f.
# Volumes are named wt_<proj>_<owner4>_<eco>_<dir>_<lock8>: <owner4> hashes host + MAIN_ROOT, <lock8>
# every manifest and lockfile, so equal lockfiles share already populated volumes.
# CREW_DOCKER_PLATFORM=host (default)|amd64|arm64|linux/...|off pins each service's platform:, so an
# amd64 pin cannot force qemu on arm64. CREW_GIT_MOUNT=on (default)|off mounts MAIN_ROOT's .git read-only
# at /git-common (with GIT_DIR for a linked worktree, whose .git names a host path no container has).
# GIT_CONFIG_COUNT/KEY_<n> are never passed: a count without its keys aborts every git command.
# Exit codes: 0 success, 1 argument or filesystem error, 2 no compose file, 3 no supported ecosystem

set -euo pipefail

PROJECT_ROOT=""
MAIN_ROOT=""
SANDBOX="${IS_SANDBOX:-0}"
DOCKER_PLATFORM="${CREW_DOCKER_PLATFORM:-host}"
GIT_MOUNT="${CREW_GIT_MOUNT:-on}"
DRY_RUN=0
QUERY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --main-root)    MAIN_ROOT="$2";    shift 2 ;;
    --sandbox)      SANDBOX=1;         shift   ;;
    --dry-run)      DRY_RUN=1;         shift   ;;
    --query)        QUERY="$2";        shift 2 ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" || -z "$MAIN_ROOT" ]]; then
  echo "Error: --project-root and --main-root are required." >&2
  echo "Usage: bash scripts/gen-override.sh --project-root <path> --main-root <path>" >&2
  exit 1
fi

case "$QUERY" in
  ""|services|ecosystem|container-src|manifest-dirs|platform|project-name|vendor-paths|state-path|owner-prefix) ;;
  *)
    echo "Error: --query must be one of: services, ecosystem, container-src, manifest-dirs, platform, project-name, vendor-paths, state-path, owner-prefix" >&2
    exit 1
    ;;
esac

case "$GIT_MOUNT" in
  on|off) ;;
  *)
    echo "Error: CREW_GIT_MOUNT must be on or off (got: $GIT_MOUNT)" >&2
    exit 1
    ;;
esac

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root does not exist: $PROJECT_ROOT" >&2
  exit 1
fi

if [[ ! -d "$MAIN_ROOT" ]]; then
  echo "Error: --main-root does not exist: $MAIN_ROOT" >&2
  exit 1
fi

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  else
    openssl dgst -sha256
  fi
}

PROJ_SLUG=$(basename "$MAIN_ROOT" | tr -cs 'a-zA-Z0-9' '_' | sed 's/_*$//')
OWNER4="$(printf '%s\n%s\n' "$(hostname 2>/dev/null || uname -n)" "$(cd "$MAIN_ROOT" && pwd -P)" | _sha256 | awk '{print substr($1, 1, 4)}')"
OWNER_PREFIX="wt_${PROJ_SLUG}_${OWNER4}_"

if [[ "$QUERY" == "owner-prefix" ]]; then
  echo "$OWNER_PREFIX"
  exit 0
fi

# Resolved before the sparse-worktree fallback below can swap PROJECT_ROOT for MAIN_ROOT.
GIT_DIR_ABS="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
OVERRIDE_PATH=""
[[ -z "$GIT_DIR_ABS" ]] || OVERRIDE_PATH="$GIT_DIR_ABS/crew-compose.override.yml"
if [[ -z "$OVERRIDE_PATH" && -z "$QUERY" && "$DRY_RUN" -eq 0 ]]; then
  echo "Error: $PROJECT_ROOT is not a git checkout — the override is written to its git dir" >&2
  exit 1
fi

COMPOSE_FILE=""
for name in docker-compose.yml docker-compose.yaml compose.yml; do
  if [[ -f "$PROJECT_ROOT/$name" ]]; then
    COMPOSE_FILE="$PROJECT_ROOT/$name"
    break
  fi
done

if [[ -z "$COMPOSE_FILE" ]]; then
  echo "Error: no compose file found in $PROJECT_ROOT" >&2
  echo "Expected one of: docker-compose.yml, docker-compose.yaml, compose.yml" >&2
  exit 2
fi

SERVICES=()
in_services=0
while IFS= read -r line; do
  if [[ "$line" =~ ^services:[[:space:]]*$ ]]; then
    in_services=1
    continue
  fi
  if [[ $in_services -eq 1 ]] && [[ "$line" =~ ^[a-zA-Z] ]]; then
    in_services=0
    continue
  fi
  if [[ $in_services -eq 1 ]] && [[ "$line" =~ ^[[:space:]]{2}([a-zA-Z0-9_-]+):[[:space:]]*$ ]]; then
    SERVICES+=("${BASH_REMATCH[1]}")
  fi
done < "$COMPOSE_FILE"

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  echo "Error: no services found in $COMPOSE_FILE" >&2
  exit 1
fi

# CONTAINER_SRC: the container side of the project bind mount (`- .:/opt/app`).
CONTAINER_SRC=$(grep -E '^\s+-\s+(\.|"\."|\$\{PROJECT_ROOT\}|\$\{APP_ROOT\}):' "$COMPOSE_FILE" \
  | head -1 \
  | grep -oE ':(\/[^: ]+)' \
  | head -1 \
  | sed 's|^:||; s|/$||') || true

if [[ -z "$CONTAINER_SRC" ]]; then
  CONTAINER_SRC="/app"
fi

ECO_NAME=""
ECO_VENDOR=""
ECO_PREFIX=""
ECO_DEPTH=5
ECO_EXCLUDE=""
ECO_ENV_PASSTHROUGH=()

# Dot-directories hold build output and other checkouts, never manifests (manifest-fingerprint.sh skips
# them too); rebuilt per call because the sparse-worktree fallback may swap PROJECT_ROOT.
DOT_EXCLUDE=()
_set_dot_exclude() {
  DOT_EXCLUDE=(-not -path "$PROJECT_ROOT/.*/*" -not -path "$PROJECT_ROOT/*/.*/*")
}

detect_ecosystem() {
  _set_dot_exclude
  if find "$PROJECT_ROOT" -maxdepth 5 -name 'package.json' \
      -not -path '*/node_modules/*' \
      "${DOT_EXCLUDE[@]}" -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="node"; ECO_VENDOR="node_modules"; ECO_PREFIX="nm"
    ECO_DEPTH=5; ECO_EXCLUDE="node_modules"
    # NPM_TOKEN by name only, so a project's .npmrc ${NPM_TOKEN} resolves from the invoking shell.
    ECO_ENV_PASSTHROUGH=("HTTPS_PROXY" "NODE_EXTRA_CA_CERTS" 'YARN_HTTPS_PROXY=${HTTPS_PROXY}' "NPM_TOKEN")
    return
  fi
  if find "$PROJECT_ROOT" -maxdepth 3 \( -name 'pyproject.toml' -o -name 'requirements.txt' \) \
      -not -path '*/.venv/*' -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="python"; ECO_VENDOR=".venv"; ECO_PREFIX="venv"
    ECO_DEPTH=3; ECO_EXCLUDE=".venv"
    ECO_ENV_PASSTHROUGH=("HTTPS_PROXY" "REQUESTS_CA_BUNDLE")
    return
  fi
  if find "$PROJECT_ROOT" -maxdepth 3 -name 'Gemfile' \
      -not -path '*/vendor/*' -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="ruby"; ECO_VENDOR="vendor/bundle"; ECO_PREFIX="bundle"
    ECO_DEPTH=3; ECO_EXCLUDE="vendor"
    ECO_ENV_PASSTHROUGH=("HTTPS_PROXY" "SSL_CERT_FILE")
    return
  fi
  if find "$PROJECT_ROOT" -maxdepth 3 -name 'Cargo.toml' \
      -not -path '*/target/*' -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="rust"; ECO_VENDOR="target"; ECO_PREFIX="target"
    ECO_DEPTH=3; ECO_EXCLUDE="target"
    ECO_ENV_PASSTHROUGH=("HTTPS_PROXY" "SSL_CERT_FILE")
    return
  fi
  if find "$PROJECT_ROOT" -maxdepth 3 -name 'composer.json' \
      -not -path '*/vendor/*' -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="php"; ECO_VENDOR="vendor"; ECO_PREFIX="vendor"
    ECO_DEPTH=3; ECO_EXCLUDE="vendor"
    ECO_ENV_PASSTHROUGH=("HTTPS_PROXY" "SSL_CERT_FILE")
    return
  fi
  if find "$PROJECT_ROOT" -maxdepth 3 -name 'go.mod' \
      -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="go"; ECO_VENDOR="vendor"; ECO_PREFIX="vendor"
    ECO_DEPTH=3; ECO_EXCLUDE="vendor"
    ECO_ENV_PASSTHROUGH=("HTTPS_PROXY" "SSL_CERT_FILE")
    return
  fi
}

detect_ecosystem

# An unrecognised arch emits no platform key: a wrong platform is worse than the project's own pin.
_host_platform() {
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64)  echo "linux/amd64" ;;
    arm64|aarch64) echo "linux/arm64" ;;
    *)             echo "" ;;
  esac
}

RESOLVED_PLATFORM=""
case "$DOCKER_PLATFORM" in
  off) ;;
  host) RESOLVED_PLATFORM="$(_host_platform)" ;;
  amd64) RESOLVED_PLATFORM="linux/amd64" ;;
  arm64) RESOLVED_PLATFORM="linux/arm64" ;;
  linux/*) RESOLVED_PLATFORM="$DOCKER_PLATFORM" ;;
  *)
    echo "Error: CREW_DOCKER_PLATFORM must be host, amd64, arm64, off, or linux/... (got: $DOCKER_PLATFORM)" >&2
    exit 1
    ;;
esac

GIT_COMMON_DIR_ABS=""
if [[ "$GIT_MOUNT" == "on" ]]; then
  GIT_COMMON_DIR_ABS="$(git -C "$MAIN_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$GIT_COMMON_DIR_ABS" && -d "$GIT_COMMON_DIR_ABS" ]] || GIT_COMMON_DIR_ABS=""
fi
GIT_ENV_LINES=()
if [[ -n "$GIT_COMMON_DIR_ABS" ]]; then
  case "$GIT_DIR_ABS" in
    "$GIT_COMMON_DIR_ABS"/worktrees/*)
      GIT_ENV_LINES=("GIT_COMMON_DIR=/git-common" "GIT_DIR=/git-common/${GIT_DIR_ABS#"$GIT_COMMON_DIR_ABS"/}")
      ;;
  esac
fi
# docker cannot create a mount point inside a read-only mount.
if [[ -n "$GIT_COMMON_DIR_ABS" && "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$GIT_COMMON_DIR_ABS/hooks" "$GIT_COMMON_DIR_ABS/info" 2>/dev/null || true
fi

# Worktrees may be sparse or freshly branched — fall back to MAIN_ROOT for detection and manifest scan.
if [[ -z "$ECO_NAME" ]] && [[ "$PROJECT_ROOT" != "$MAIN_ROOT" ]]; then
  PROJECT_ROOT="$MAIN_ROOT"
  detect_ecosystem
fi

if [[ -z "$ECO_NAME" ]]; then
  echo "Error: no supported ecosystem detected in $PROJECT_ROOT or $MAIN_ROOT" >&2
  echo "Expected one of: package.json, pyproject.toml, requirements.txt, Gemfile, Cargo.toml, go.mod, composer.json" >&2
  exit 3
fi

# The top-level `name:` must be what compose picks for the main checkout on its own, or the two
# create separate <name>_default networks: the file's literal `name:`, else MAIN_ROOT's basename
# normalised as compose does. Not PROJ_SLUG: that turns `-` into `_`.
PROJECT_NAME=$(sed -nE 's/^name:[[:space:]]*["'\'']?([^"'\''#[:space:]]+)["'\'']?[[:space:]]*(#.*)?$/\1/p' \
  "$COMPOSE_FILE" | head -1)
if [[ -z "$PROJECT_NAME" || "$PROJECT_NAME" == *'$'* ]]; then
  PROJECT_NAME=$(basename "$MAIN_ROOT" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-' | sed 's/^[_-]*//')
fi
if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="proj_$(echo "$PROJ_SLUG" | tr 'A-Z' 'a-z')"
fi

MANIFEST_DIRS=()
_set_dot_exclude
if [[ "$ECO_NAME" == "python" ]]; then
  mapfile -t MANIFEST_DIRS < <(
    find "$PROJECT_ROOT" -maxdepth "$ECO_DEPTH" \
      \( -name 'pyproject.toml' -o -name 'requirements.txt' \) \
      -not -path "*/${ECO_EXCLUDE}/*" \
      "${DOT_EXCLUDE[@]}" \
      -exec dirname {} \; | sort -u
  )
elif [[ "$ECO_NAME" == "node" ]]; then
  mapfile -t MANIFEST_DIRS < <(
    find "$PROJECT_ROOT" -maxdepth "$ECO_DEPTH" \
      -name 'package.json' \
      -not -path '*/node_modules/*' \
      "${DOT_EXCLUDE[@]}" \
      -exec dirname {} \; | sort -u
  )
else
  mapfile -t MANIFEST_DIRS < <(
    find "$PROJECT_ROOT" -maxdepth "$ECO_DEPTH" \
      -name "$(case $ECO_NAME in ruby) echo 'Gemfile';; rust) echo 'Cargo.toml';; php) echo 'composer.json';; go) echo 'go.mod';; esac)" \
      -not -path "*/${ECO_EXCLUDE}/*" \
      "${DOT_EXCLUDE[@]}" \
      -exec dirname {} \; | sort -u
  )
fi

LOCK8="$(bash "$(dirname "${BASH_SOURCE[0]}")/manifest-fingerprint.sh" compute --project-root "$PROJECT_ROOT" | cut -c1-8)"

VOL_NAMES=()
VOL_PATHS=()
for dir in "${MANIFEST_DIRS[@]}"; do
  rel="${dir#"$PROJECT_ROOT"}"
  rel="${rel#/}"
  if [[ -z "$rel" ]]; then
    suffix="root"
    container_path="${CONTAINER_SRC}/${ECO_VENDOR}"
  else
    suffix=$(echo "$rel" | tr '/.-' '___')
    container_path="${CONTAINER_SRC}/${rel}/${ECO_VENDOR}"
  fi
  VOL_NAMES+=("${OWNER_PREFIX}${ECO_PREFIX}_${suffix}_${LOCK8}")
  VOL_PATHS+=("$container_path")
done

# Outside every vendor dir: an install that empties one (`npm ci`) must not delete its lock.
STATE_VOL="${OWNER_PREFIX}state_${LOCK8}"
STATE_PATH="/crew-state"

if [[ -n "$QUERY" ]]; then
  case "$QUERY" in
    services)      printf '%s\n' "${SERVICES[@]}" ;;
    ecosystem)     echo "$ECO_NAME" ;;
    container-src) echo "$CONTAINER_SRC" ;;
    manifest-dirs) printf '%s\n' "${MANIFEST_DIRS[@]}" ;;
    platform)      echo "$RESOLVED_PLATFORM" ;;
    project-name)  echo "$PROJECT_NAME" ;;
    vendor-paths)  printf '%s\n' "${VOL_PATHS[@]}" ;;
    state-path)    echo "$STATE_PATH" ;;
  esac
  exit 0
fi

generate_yaml() {
  echo "name: ${PROJECT_NAME}"
  echo "services:"
  for svc in "${SERVICES[@]}"; do
    echo "  ${svc}:"
    if [[ -n "$RESOLVED_PLATFORM" ]]; then
      echo "    platform: ${RESOLVED_PLATFORM}"
    fi
    if [[ ${#ECO_ENV_PASSTHROUGH[@]} -gt 0 || ${#GIT_ENV_LINES[@]} -gt 0 ]]; then
      echo "    environment:"
      for var in "${ECO_ENV_PASSTHROUGH[@]}"; do
        echo "      - ${var}"
      done
      for var in "${GIT_ENV_LINES[@]+"${GIT_ENV_LINES[@]}"}"; do
        echo "      - ${var}"
      done
    fi
    echo "    volumes:"
    for i in "${!VOL_NAMES[@]}"; do
      echo "      - ${VOL_NAMES[$i]}:${VOL_PATHS[$i]}"
    done
    echo "      - ${STATE_VOL}:${STATE_PATH}"
    if [[ -n "$GIT_COMMON_DIR_ABS" ]]; then
      echo "      - ${GIT_COMMON_DIR_ABS}:/git-common:ro"
      echo "      - wt_${PROJ_SLUG}_git_hooks:/git-common/hooks"
      echo "      - wt_${PROJ_SLUG}_git_info:/git-common/info"
    fi
    if [[ "$SANDBOX" == "1" ]]; then
      echo "      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro"
    fi
  done
  echo "volumes:"
  for vol in "${VOL_NAMES[@]}" "$STATE_VOL"; do
    echo "  ${vol}:"
    echo "    name: ${vol}"
  done
  if [[ -n "$GIT_COMMON_DIR_ABS" ]]; then
    echo "  wt_${PROJ_SLUG}_git_hooks:"
    echo "  wt_${PROJ_SLUG}_git_info:"
  fi
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  generate_yaml
else
  # Written beside the final name and renamed in: a compose call reading it never sees half a file.
  generate_yaml > "$OVERRIDE_PATH.tmp.$$"
  mv -f "$OVERRIDE_PATH.tmp.$$" "$OVERRIDE_PATH"
  echo "Written: $OVERRIDE_PATH"
  echo "  project:   $PROJECT_NAME (pins the compose project name so volumes are shared across worktrees)"
  echo "  ecosystem: $ECO_NAME"
  echo "  services:  $(IFS=', '; echo "${SERVICES[*]}")"
  echo "  sandbox:   $([[ "$SANDBOX" == "1" ]] && echo true || echo false)"
  echo "  platform:  ${RESOLVED_PLATFORM:-unset, project pin unchanged}"
  if [[ -n "$GIT_COMMON_DIR_ABS" ]]; then
    echo "  git:       MAIN_ROOT's .git mounted read-only at /git-common (hooks/ and info/ writable via wt_${PROJ_SLUG}_git_hooks and wt_${PROJ_SLUG}_git_info)${GIT_ENV_LINES[0]:+; GIT_DIR=${GIT_ENV_LINES[1]#GIT_DIR=}}"
  elif [[ "$GIT_MOUNT" == "off" ]]; then
    echo "  git:       not mounted (CREW_GIT_MOUNT=off)"
  else
    echo "  git:       not mounted (no git checkout detected at MAIN_ROOT)"
  fi
fi
