#!/usr/bin/env bash
# Generate docker-compose.override.yml deterministically from the project's manifest files.
#
# Usage:
#   bash scripts/gen-override.sh --project-root /path/to/worktree --main-root /path/to/main
#
# Options:
#   --project-root   Absolute path to the worktree (where manifest files live)
#   --main-root      Absolute path to the main checkout (where override file is written)
#   --sandbox        Add proxy env vars + CA bundle. Default: read IS_SANDBOX env var.
#   --dry-run        Print generated YAML to stdout instead of writing the file.
#
# Exit codes:
#   0  success
#   1  argument or filesystem error
#   2  no compose file found at project-root
#   3  no supported ecosystem detected

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------

PROJECT_ROOT=""
MAIN_ROOT=""
SANDBOX="${IS_SANDBOX:-0}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-root) PROJECT_ROOT="$2"; shift 2 ;;
    --main-root)    MAIN_ROOT="$2";    shift 2 ;;
    --sandbox)      SANDBOX=1;         shift   ;;
    --dry-run)      DRY_RUN=1;         shift   ;;
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

if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Error: --project-root does not exist: $PROJECT_ROOT" >&2
  exit 1
fi

if [[ ! -d "$MAIN_ROOT" ]]; then
  echo "Error: --main-root does not exist: $MAIN_ROOT" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Locate compose file
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Parse compose file: service names and CONTAINER_SRC
# ---------------------------------------------------------------------------

# Service names: 2-space-indented keys directly under "services:"
SERVICES=()
in_services=0
while IFS= read -r line; do
  if [[ "$line" =~ ^services:[[:space:]]*$ ]]; then
    in_services=1
    continue
  fi
  # A new top-level key ends the services block
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

# CONTAINER_SRC: container-side path of the project bind-mount (e.g. /opt/app)
# Matches volume entries like:  - .:/opt/app  or  - ${PROJECT_ROOT}:/opt/app
CONTAINER_SRC=$(grep -E '^\s+-\s+(\.|"\."|\$\{PROJECT_ROOT\}|\$\{APP_ROOT\}):' "$COMPOSE_FILE" \
  | head -1 \
  | grep -oE ':(\/[^: ]+)' \
  | head -1 \
  | sed 's|^:||; s|/$||')

if [[ -z "$CONTAINER_SRC" ]]; then
  CONTAINER_SRC="/app"
fi

# ---------------------------------------------------------------------------
# Detect ecosystem (first match wins)
# ---------------------------------------------------------------------------

ECO_NAME=""
ECO_VENDOR=""
ECO_PREFIX=""
ECO_DEPTH=5
ECO_EXCLUDE=""
ECO_PROXY_VARS=()

detect_ecosystem() {
  if find "$PROJECT_ROOT" -maxdepth 5 -name 'package.json' \
      -not -path '*/node_modules/*' \
      -not -path '*/\.*/*' -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="node"; ECO_VENDOR="node_modules"; ECO_PREFIX="nm"
    ECO_DEPTH=5; ECO_EXCLUDE="node_modules"
    ECO_PROXY_VARS=("HTTPS_PROXY" "NODE_EXTRA_CA_CERTS" 'YARN_HTTPS_PROXY=${HTTPS_PROXY}')
    return
  fi
  if find "$PROJECT_ROOT" -maxdepth 3 \( -name 'pyproject.toml' -o -name 'requirements.txt' \) \
      -not -path '*/.venv/*' -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="python"; ECO_VENDOR=".venv"; ECO_PREFIX="venv"
    ECO_DEPTH=3; ECO_EXCLUDE=".venv"
    ECO_PROXY_VARS=("HTTPS_PROXY" "REQUESTS_CA_BUNDLE")
    return
  fi
  if find "$PROJECT_ROOT" -maxdepth 3 -name 'Gemfile' \
      -not -path '*/vendor/*' -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="ruby"; ECO_VENDOR="vendor/bundle"; ECO_PREFIX="bundle"
    ECO_DEPTH=3; ECO_EXCLUDE="vendor"
    ECO_PROXY_VARS=("HTTPS_PROXY" "SSL_CERT_FILE")
    return
  fi
  if find "$PROJECT_ROOT" -maxdepth 3 -name 'Cargo.toml' \
      -not -path '*/target/*' -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="rust"; ECO_VENDOR="target"; ECO_PREFIX="target"
    ECO_DEPTH=3; ECO_EXCLUDE="target"
    ECO_PROXY_VARS=("HTTPS_PROXY" "SSL_CERT_FILE")
    return
  fi
  if find "$PROJECT_ROOT" -maxdepth 3 -name 'composer.json' \
      -not -path '*/vendor/*' -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="php"; ECO_VENDOR="vendor"; ECO_PREFIX="vendor"
    ECO_DEPTH=3; ECO_EXCLUDE="vendor"
    ECO_PROXY_VARS=("HTTPS_PROXY" "SSL_CERT_FILE")
    return
  fi
  if find "$PROJECT_ROOT" -maxdepth 3 -name 'go.mod' \
      -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="go"; ECO_VENDOR="vendor"; ECO_PREFIX="vendor"
    ECO_DEPTH=3; ECO_EXCLUDE="vendor"
    ECO_PROXY_VARS=("HTTPS_PROXY" "SSL_CERT_FILE")
    return
  fi
}

detect_ecosystem

if [[ -z "$ECO_NAME" ]]; then
  echo "Error: no supported ecosystem detected in $PROJECT_ROOT" >&2
  echo "Expected one of: package.json, pyproject.toml, requirements.txt, Gemfile, Cargo.toml, go.mod, composer.json" >&2
  exit 3
fi

# ---------------------------------------------------------------------------
# Find manifest directories and build volume list
# ---------------------------------------------------------------------------

PROJ_SLUG=$(basename "$MAIN_ROOT" | tr -cs 'a-zA-Z0-9' '_' | sed 's/_*$//')

MANIFEST_DIRS=()
if [[ "$ECO_NAME" == "python" ]]; then
  mapfile -t MANIFEST_DIRS < <(
    find "$PROJECT_ROOT" -maxdepth "$ECO_DEPTH" \
      \( -name 'pyproject.toml' -o -name 'requirements.txt' \) \
      -not -path "*/${ECO_EXCLUDE}/*" \
      -exec dirname {} \; | sort -u
  )
elif [[ "$ECO_NAME" == "node" ]]; then
  mapfile -t MANIFEST_DIRS < <(
    find "$PROJECT_ROOT" -maxdepth "$ECO_DEPTH" \
      -name 'package.json' \
      -not -path '*/node_modules/*' \
      -not -path '*/.*/*' \
      -exec dirname {} \; | sort -u
  )
else
  mapfile -t MANIFEST_DIRS < <(
    find "$PROJECT_ROOT" -maxdepth "$ECO_DEPTH" \
      -name "$(case $ECO_NAME in ruby) echo 'Gemfile';; rust) echo 'Cargo.toml';; php) echo 'composer.json';; go) echo 'go.mod';; esac)" \
      -not -path "*/${ECO_EXCLUDE}/*" \
      -exec dirname {} \; | sort -u
  )
fi

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
  VOL_NAMES+=("wt_${PROJ_SLUG}_${ECO_PREFIX}_${suffix}")
  VOL_PATHS+=("$container_path")
done

# ---------------------------------------------------------------------------
# Generate YAML
# ---------------------------------------------------------------------------

generate_yaml() {
  echo "services:"
  for svc in "${SERVICES[@]}"; do
    echo "  ${svc}:"
    if [[ "$SANDBOX" == "1" ]]; then
      echo "    environment:"
      for var in "${ECO_PROXY_VARS[@]}"; do
        echo "      - ${var}"
      done
    fi
    echo "    volumes:"
    for i in "${!VOL_NAMES[@]}"; do
      echo "      - ${VOL_NAMES[$i]}:${VOL_PATHS[$i]}"
    done
    if [[ "$SANDBOX" == "1" ]]; then
      echo "      - /etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro"
    fi
  done
  echo "volumes:"
  for vol in "${VOL_NAMES[@]}"; do
    echo "  ${vol}:"
  done
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ "$DRY_RUN" -eq 1 ]]; then
  generate_yaml
else
  generate_yaml > "$MAIN_ROOT/docker-compose.override.yml"
  echo "Written: $MAIN_ROOT/docker-compose.override.yml"
  echo "  ecosystem: $ECO_NAME"
  echo "  services:  $(IFS=', '; echo "${SERVICES[*]}")"
  echo "  sandbox:   $([[ "$SANDBOX" == "1" ]] && echo true || echo false)"
fi
