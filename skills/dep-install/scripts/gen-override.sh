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
#   --query <field>  Print one detected fact and exit, instead of writing the override.
#                    <field> is one of: services | ecosystem | container-src | manifest-dirs | platform | project-name
#                    Lets a caller that needs to *run* an install (not just generate the
#                    override) reuse this script's own detection instead of re-parsing the
#                    compose file and manifests a second time.
#
# Project name: every `docker compose` invocation in this repo passes this generated
# override as its *last* `-f` (see docker-install.md, verify-worktree.sh, docker-install.sh),
# and compose resolves the project name from the last `-f` file's top-level `name:` key when
# neither `-p` nor COMPOSE_PROJECT_NAME is set. Without that key, compose falls back to the
# basename of the *first* `-f` file's directory — the worktree's own compose file — so the
# same volume name (wt_<slug>_...) still ends up siloed per worktree, e.g.
# "component-with-mock_wt_myproj_nm_root" instead of a single shared "wt_myproj_nm_root".
# Emitting `name:` here, keyed off MAIN_ROOT (not the worktree), is what actually makes the
# named volumes shared across every worktree — the volume name prefix alone does not.
#
# Worktree symlink: when PROJECT_ROOT differs from MAIN_ROOT, the file written at MAIN_ROOT
# is also symlinked to PROJECT_ROOT/docker-compose.override.yml. Every mechanical caller
# still passes the file's absolute MAIN_ROOT path via an explicit second `-f` regardless of
# this symlink — that stays the correct, cwd-independent way to invoke it. The symlink exists
# only so a bare `docker compose run` typed with no `-f` at all still picks the override up
# via compose's own same-directory discovery convention, instead of silently running without
# it.
#
# Platform: the project's own compose file (or the image it builds/pulls) may pin
# `platform: linux/amd64`. On an arm64 host that forces every `docker compose run` — install
# and every later verify check alike — under qemu emulation, which is where "requested
# image's platform does not match the detected host platform" warnings and the slow/flaky
# runs behind them come from. Default: read CREW_DOCKER_PLATFORM env var (default "host"),
# and emit a `platform:` key per service in the generated override so the override's later
# `-f` wins the compose merge and the project's own pin is never reached.
#   CREW_DOCKER_PLATFORM=host        (default) match the detected host architecture
#   CREW_DOCKER_PLATFORM=amd64|arm64 force that architecture regardless of host
#   CREW_DOCKER_PLATFORM=linux/...   passed through verbatim (e.g. linux/arm64/v8)
#   CREW_DOCKER_PLATFORM=off         emit no platform key — the project's own pin wins,
#                                    for images that genuinely are single-arch and a host
#                                    that has emulation deliberately set up for them
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
DOCKER_PLATFORM="${CREW_DOCKER_PLATFORM:-host}"
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
  ""|services|ecosystem|container-src|manifest-dirs|platform|project-name) ;;
  *)
    echo "Error: --query must be one of: services, ecosystem, container-src, manifest-dirs, platform, project-name" >&2
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
  | sed 's|^:||; s|/$||') || true

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
      -not -path "$PROJECT_ROOT/*/\.*/*" -print -quit 2>/dev/null | grep -q .; then
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

# ---------------------------------------------------------------------------
# Resolve the platform key (see CREW_DOCKER_PLATFORM in the header comment)
# ---------------------------------------------------------------------------

# _host_platform — best-effort `uname -m` -> compose platform string. Unrecognized
# output means "skip the override" (empty), never a guess: emitting the wrong
# platform is worse than leaving the project's own pin in place.
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

# ---------------------------------------------------------------------------
# Find manifest directories and build volume list
# ---------------------------------------------------------------------------

PROJ_SLUG=$(basename "$MAIN_ROOT" | tr -cs 'a-zA-Z0-9' '_' | sed 's/_*$//')

# PROJECT_NAME — the compose top-level `name:` value (see the "Project name" header comment
# above). Compose project names allow only lowercase letters, digits, dashes and underscores,
# and must start with a lowercase letter or digit — stricter than PROJ_SLUG's own volume-name
# rules, so this is derived separately rather than reusing PROJ_SLUG as-is.
PROJECT_NAME=$(echo "$PROJ_SLUG" | tr 'A-Z' 'a-z')
if [[ ! "$PROJECT_NAME" =~ ^[a-z0-9] ]]; then
  PROJECT_NAME="proj_${PROJECT_NAME}"
fi

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
      -not -path "$PROJECT_ROOT/.claude/worktrees/*" \
      -not -path "$PROJECT_ROOT/*/.*/*" \
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
# --query short-circuit: print one detected fact, skip the override entirely
# ---------------------------------------------------------------------------

if [[ -n "$QUERY" ]]; then
  case "$QUERY" in
    services)      printf '%s\n' "${SERVICES[@]}" ;;
    ecosystem)     echo "$ECO_NAME" ;;
    container-src) echo "$CONTAINER_SRC" ;;
    manifest-dirs) printf '%s\n' "${MANIFEST_DIRS[@]}" ;;
    platform)      echo "$RESOLVED_PLATFORM" ;;
    project-name)  echo "$PROJECT_NAME" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------------------
# Generate YAML
# ---------------------------------------------------------------------------

generate_yaml() {
  echo "name: ${PROJECT_NAME}"
  echo "services:"
  for svc in "${SERVICES[@]}"; do
    echo "  ${svc}:"
    if [[ -n "$RESOLVED_PLATFORM" ]]; then
      echo "    platform: ${RESOLVED_PLATFORM}"
    fi
    if [[ ${#ECO_PROXY_VARS[@]} -gt 0 ]]; then
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
  echo "  project:   $PROJECT_NAME (pins the compose project name so volumes are shared across worktrees)"
  echo "  ecosystem: $ECO_NAME"
  echo "  services:  $(IFS=', '; echo "${SERVICES[*]}")"
  echo "  sandbox:   $([[ "$SANDBOX" == "1" ]] && echo true || echo false)"
  echo "  platform:  ${RESOLVED_PLATFORM:-unset, project pin unchanged}"

  # A worktree (PROJECT_ROOT distinct from MAIN_ROOT) also gets its own symlink to this
  # single generated file. Every mechanical caller (docker-install.sh, verify-worktree.sh)
  # and docker-install.md's own instructions already pass this file's absolute MAIN_ROOT
  # path via an explicit second `-f` on every command, which is correct regardless of cwd
  # and stays that way — this symlink does not replace it. It is a safety net for the one
  # case that contract can't cover: a bare `docker compose run` a worker types without any
  # `-f` at all silently drops the override (proxy vars, platform pin, named volumes)
  # instead of failing loudly. Compose's own same-directory `docker-compose.override.yml`
  # discovery convention only fires when the file actually sits next to `docker-compose.yml`
  # in PROJECT_ROOT, so it needs a real (or symlinked) presence there, not just resolvability
  # via some other path. `-ef` compares resolved identity, not string equality, so the one
  # MAIN_ROOT-only call (PROJECT_ROOT == MAIN_ROOT, before any worktree exists) is a no-op
  # here rather than linking the file to itself. Mirrors ensure-env.sh's own `.env` link,
  # including its dangling-symlink hazard: `-e` follows symlinks and reports false for a
  # stale one too (e.g. a worktree reused after this script last ran against a different
  # MAIN_ROOT), so that case is cleared and relinked rather than left broken. A live
  # entry — a real file, or a symlink that still resolves — is left alone: a project that
  # commits its own docker-compose.override.yml at PROJECT_ROOT keeps it untouched, the same
  # "leave a live entry" rule applyWorktreeInclude uses for `.worktreeinclude`.
  if [[ ! "$PROJECT_ROOT" -ef "$MAIN_ROOT" ]]; then
    override_link="$PROJECT_ROOT/docker-compose.override.yml"
    if [[ -L "$override_link" && ! -e "$override_link" ]]; then
      rm -f "$override_link"
    fi
    if [[ ! -e "$override_link" ]]; then
      ln -s "$MAIN_ROOT/docker-compose.override.yml" "$override_link"
      echo "Linked: $override_link -> $MAIN_ROOT/docker-compose.override.yml"
    fi
  fi
fi
