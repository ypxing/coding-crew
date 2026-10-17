#!/usr/bin/env bash
# Generate this worktree's crew compose override deterministically from the project's manifest files.
#
# Usage:
#   bash scripts/gen-override.sh --project-root /path/to/checkout [--query <field>]
#
#   --query <field>  Print one detected fact and exit: services | ecosystem | container-src |
#                    manifest-dirs | project-name | vendor-paths
# Writes <project-root's git dir>/crew-compose.override.yml; the docker shim adds it as the last -f.
# Everything derives from this one checkout, so two worktrees never share a compose project, network
# or volume. Volumes are named wt_<proj>_<owner4>_<eco>_<dir>_<lock8>: <owner4> hashes host + this
# checkout's path, <lock8> every manifest and lockfile, so a changed lockfile names fresh volumes.
# The repo's shared .git is mounted read-only at /git-common (with GIT_DIR for a linked worktree, whose
# .git names a host path no container has).
# Exit codes: 0 success, 1 argument or filesystem error, 2 no compose file, 3 no supported ecosystem

set -euo pipefail

PROJECT_ROOT=""
QUERY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --query)        QUERY="$2";        shift 2 ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root is required." >&2
  echo "Usage: bash scripts/gen-override.sh --project-root <path>" >&2
  exit 1
fi

case "$QUERY" in
  ""|services|ecosystem|container-src|manifest-dirs|project-name|vendor-paths) ;;
  *)
    echo "Error: --query must be one of: services, ecosystem, container-src, manifest-dirs, project-name, vendor-paths" >&2
    exit 1
    ;;
esac

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root does not exist: $PROJECT_ROOT" >&2
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

PROJ_SLUG=$(basename "$PROJECT_ROOT" | tr -cs 'a-zA-Z0-9' '_' | sed 's/_*$//')
_owner4() { # host + this checkout's path, hashed
  printf '%s\n%s\n' "$(hostname 2>/dev/null || uname -n)" "$(cd "$PROJECT_ROOT" && pwd -P)" | _sha256 | awk '{print substr($1, 1, 4)}'
}

GIT_DIR_ABS="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
OVERRIDE_PATH=""
[[ -z "$GIT_DIR_ABS" ]] || OVERRIDE_PATH="$GIT_DIR_ABS/crew-compose.override.yml"
if [[ -z "$OVERRIDE_PATH" && -z "$QUERY" ]]; then
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

# A proxied agent sandbox's CA bundle; a service container must trust it to reach the registry.
CREW_CA_FILE="${CREW_CA_FILE:-/etc/ssl/certs/ca-certificates.crt}"

# Dot-directories hold build output and other checkouts, never manifests (manifest-fingerprint.sh skips them too).
DOT_EXCLUDE=(-not -path "$PROJECT_ROOT/.*/*" -not -path "$PROJECT_ROOT/*/.*/*")

detect_ecosystem() {
  if find "$PROJECT_ROOT" -maxdepth 5 -name 'package.json' \
      -not -path '*/node_modules/*' \
      "${DOT_EXCLUDE[@]}" -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="node"; ECO_VENDOR="node_modules"; ECO_PREFIX="nm"
    ECO_DEPTH=5; ECO_EXCLUDE="node_modules"
    # NPM_TOKEN by name only, so a project's .npmrc ${NPM_TOKEN} resolves from the invoking shell.
    ECO_ENV_PASSTHROUGH=("HTTPS_PROXY" "NODE_EXTRA_CA_CERTS" 'YARN_HTTPS_PROXY=${HTTPS_PROXY:-}' "NPM_TOKEN")
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

# Only what the generating shell sets: the override is the last -f, so an entry for an unset name would
# blank the value the project's own compose file gives it. An entry that reads another variable
# (YARN_HTTPS_PROXY=${HTTPS_PROXY:-}) follows that one.
ENV_PASSTHROUGH=()
for entry in "${ECO_ENV_PASSTHROUGH[@]+"${ECO_ENV_PASSTHROUGH[@]}"}"; do
  src="${entry#*'${'}"; src="${src%%[:\}]*}"
  [[ -z "${!src+set}" ]] || ENV_PASSTHROUGH+=("$entry")
done

GIT_COMMON_DIR_ABS="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
[[ -n "$GIT_COMMON_DIR_ABS" && -d "$GIT_COMMON_DIR_ABS" ]] || GIT_COMMON_DIR_ABS=""
GIT_ENV_LINES=()
if [[ -n "$GIT_COMMON_DIR_ABS" ]]; then
  case "$GIT_DIR_ABS" in
    "$GIT_COMMON_DIR_ABS"/worktrees/*)
      GIT_ENV_LINES=("GIT_COMMON_DIR=/git-common" "GIT_DIR=/git-common/${GIT_DIR_ABS#"$GIT_COMMON_DIR_ABS"/}")
      ;;
  esac
fi
# docker cannot create a mount point inside a read-only mount.
if [[ -n "$GIT_COMMON_DIR_ABS" ]]; then
  mkdir -p "$GIT_COMMON_DIR_ABS/hooks" "$GIT_COMMON_DIR_ABS/info" 2>/dev/null || true
fi

if [[ -z "$ECO_NAME" ]]; then
  echo "Error: no supported ecosystem detected in $PROJECT_ROOT" >&2
  echo "Expected one of: package.json, pyproject.toml, requirements.txt, Gemfile, Cargo.toml, go.mod, composer.json" >&2
  exit 3
fi

# The name compose picks on its own: the file's literal `name:`, else the checkout's basename
# normalised as compose does (not PROJ_SLUG: that turns `-` into `_`). The main checkout keeps it, so
# a person's own `docker compose up` there and crew's runs share one project; a linked worktree adds
# <owner4>, so each is a compose project of its own.
PROJECT_NAME=$(sed -nE 's/^name:[[:space:]]*["'\'']?([^"'\''#[:space:]]+)["'\'']?[[:space:]]*(#.*)?$/\1/p' \
  "$COMPOSE_FILE" | head -1)
if [[ -z "$PROJECT_NAME" || "$PROJECT_NAME" == *'$'* ]]; then
  PROJECT_NAME=$(basename "$PROJECT_ROOT" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-' | sed 's/^[_-]*//')
fi
if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="proj_$(echo "$PROJ_SLUG" | tr 'A-Z' 'a-z')"
fi
_common="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [[ -n "$GIT_DIR_ABS" && -n "$_common" && "$GIT_DIR_ABS" != "$_common" ]]; then
  PROJECT_NAME="${PROJECT_NAME}-$(_owner4)"
fi

MANIFEST_DIRS=()
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

VOL_SUFFIXES=()
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
  VOL_SUFFIXES+=("$suffix")
  VOL_PATHS+=("$container_path")
done

# The override's platform key wins over a project's own pin, so an arm64 host runs native images
# instead of flaky qemu emulation. An unrecognised arch emits no key: a wrong platform is worse.
case "$(uname -m 2>/dev/null)" in
  x86_64|amd64)  HOST_PLATFORM="linux/amd64" ;;
  arm64|aarch64) HOST_PLATFORM="linux/arm64" ;;
  *)             HOST_PLATFORM="" ;;
esac

if [[ -n "$QUERY" ]]; then
  case "$QUERY" in
    services)      printf '%s\n' "${SERVICES[@]}" ;;
    ecosystem)     echo "$ECO_NAME" ;;
    container-src) echo "$CONTAINER_SRC" ;;
    manifest-dirs) printf '%s\n' "${MANIFEST_DIRS[@]}" ;;
    project-name)  echo "$PROJECT_NAME" ;;
    vendor-paths)  printf '%s\n' "${VOL_PATHS[@]}" ;;
  esac
  exit 0
fi

# After the query exit: hashing every lockfile is only needed for the volume names.
OWNER_PREFIX="wt_${PROJ_SLUG}_$(_owner4)_"
LOCK8="$(bash "$(dirname "${BASH_SOURCE[0]}")/manifest-fingerprint.sh" --project-root "$PROJECT_ROOT" | cut -c1-8)"
VOL_NAMES=()
for suffix in "${VOL_SUFFIXES[@]}"; do
  VOL_NAMES+=("${OWNER_PREFIX}${ECO_PREFIX}_${suffix}_${LOCK8}")
done

generate_yaml() {
  echo "name: ${PROJECT_NAME}"
  echo "services:"
  for svc in "${SERVICES[@]}"; do
    echo "  ${svc}:"
    [[ -z "$HOST_PLATFORM" ]] || echo "    platform: ${HOST_PLATFORM}"
    if [[ ${#ENV_PASSTHROUGH[@]} -gt 0 || ${#GIT_ENV_LINES[@]} -gt 0 ]]; then
      echo "    environment:"
      for var in "${ENV_PASSTHROUGH[@]+"${ENV_PASSTHROUGH[@]}"}"; do
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
    if [[ -n "$GIT_COMMON_DIR_ABS" ]]; then
      echo "      - ${GIT_COMMON_DIR_ABS}:/git-common:ro"
      echo "      - wt_${PROJ_SLUG}_git_hooks:/git-common/hooks"
      echo "      - wt_${PROJ_SLUG}_git_info:/git-common/info"
    fi
    [[ ! -f "$CREW_CA_FILE" ]] || echo "      - ${CREW_CA_FILE}:/etc/ssl/certs/ca-certificates.crt:ro"
  done
  echo "volumes:"
  for vol in "${VOL_NAMES[@]}"; do
    echo "  ${vol}:"
    echo "    name: ${vol}"
  done
  if [[ -n "$GIT_COMMON_DIR_ABS" ]]; then
    echo "  wt_${PROJ_SLUG}_git_hooks:"
    echo "  wt_${PROJ_SLUG}_git_info:"
  fi
}

# Written beside the final name and renamed in: a compose call reading it never sees half a file.
generate_yaml > "$OVERRIDE_PATH.tmp.$$"
mv -f "$OVERRIDE_PATH.tmp.$$" "$OVERRIDE_PATH"
echo "Written: $OVERRIDE_PATH"
echo "  project:   $PROJECT_NAME (this checkout's own compose project)"
echo "  ecosystem: $ECO_NAME"
echo "  services:  $(IFS=', '; echo "${SERVICES[*]}")"
echo "  platform:  ${HOST_PLATFORM:-unset, project pin unchanged}"
if [[ -n "$GIT_COMMON_DIR_ABS" ]]; then
  echo "  git:       the shared .git mounted read-only at /git-common (hooks/ and info/ writable via wt_${PROJ_SLUG}_git_hooks and wt_${PROJ_SLUG}_git_info)${GIT_ENV_LINES[0]:+; GIT_DIR=${GIT_ENV_LINES[1]#GIT_DIR=}}"
else
  echo "  git:       not mounted (no git checkout detected at $PROJECT_ROOT)"
fi
[[ ! -f "$CREW_CA_FILE" ]] || echo "  proxy/CA:  passed through"
