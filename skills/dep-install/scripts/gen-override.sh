#!/usr/bin/env bash
# Generate this worktree's crew compose override deterministically from the project's manifest files.
#
# Usage:
#   bash scripts/gen-override.sh --project-root /path/to/worktree --main-root /path/to/main
#
# Options:
#   --project-root   Absolute path to the worktree (where manifest files live)
#   --main-root      Absolute path to the main checkout (the project name and volume names key off it)
#   --sandbox        Add proxy env vars + CA bundle. Default: read IS_SANDBOX env var.
#   --dry-run        Print generated YAML to stdout instead of writing the file.
#   --query <field>  Print one detected fact and exit, instead of writing the override.
#                    <field> is one of: services | ecosystem | container-src | manifest-dirs |
#                    platform | project-name | vendor-paths | owner-prefix
#                    Lets a caller that needs to *run* an install (not just generate the
#                    override) reuse this script's own detection instead of re-parsing the
#                    compose file and manifests a second time. `vendor-paths` is the container
#                    path of each named dep volume, one per line — where an install must have
#                    written for the checks to see it. `owner-prefix` is `wt_<proj>_<owner4>_`,
#                    the prefix every dependency volume of this MAIN_ROOT on this host starts
#                    with (it needs no compose file).
#
# Where it is written: <PROJECT_ROOT's git dir>/crew-compose.override.yml, i.e.
#   $(git -C <project-root> rev-parse --path-format=absolute --git-dir)/crew-compose.override.yml
# A linked worktree's lands in .git/worktrees/<name>/ and goes away with the worktree; the main
# checkout's lands in .git/. Nothing named docker-compose.override.yml is written or linked into
# the repo, so a project's own committed one is never touched. The shim (shim/docker) adds this
# file as the last `-f` of every `docker compose` call on PATH; nothing else needs to name it.
#
# Dependency volume names: every one gets an explicit top-level `name:`
#   wt_<proj>_<owner4>_<eco>_<dir>_<lock8>
# <owner4> is a hash of this host's name and MAIN_ROOT's realpath, so another clone or sandbox
# never matches (or removes) this one's volumes. <lock8> is a hash over every manifest and lockfile
# manifest-fingerprint.sh finds under the project, since one install writes every volume: a
# worktree, sprint or sandbox with the same lockfiles names the same, already populated volumes,
# and a different lockfile names fresh ones. Being explicit, `name:` is not prefixed by compose's
# project name, so -p / COMPOSE_PROJECT_NAME no longer rename a volume.
#
# Project name: the generated file carries a top-level `name:`. Compose resolves the project name
# from the last `-f` file's `name:` key when neither `-p` nor COMPOSE_PROJECT_NAME is set, and the
# shim makes this file the last one. Without that key compose falls back to the basename of the
# *first* `-f` file's directory — the worktree's own compose file — so the same volume name
# (wt_<slug>_...) would end up siloed per worktree, e.g. "component-with-mock_wt_myproj_nm_root"
# instead of a single shared "wt_myproj_nm_root".
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
# Git metadata mount: a *linked* worktree's `.git` is a file (`gitdir: /abs/host/path/...`)
# pointing at MAIN_ROOT's `.git/worktrees/<name>`, which in turn needs MAIN_ROOT's `.git`
# (objects, refs, hooks) via its own `commondir` pointer. A container never has that absolute
# host path, so any git command run inside one — most commonly a package manager's postinstall
# hook (lefthook/husky/simple-git-hooks running `git rev-parse --git-path hooks`) — fails with
# `fatal: not a git repository: <path>`, which then fails the whole install step it was
# incidental to. Fixed by mounting MAIN_ROOT's real `.git` dir read-only at a fixed container
# path (`/git-common`), so git never needs to resolve the unmountable absolute host path at all.
# The two subdirectories a hook installer writes to get a writable named volume each on top of
# that read-only mount: `hooks/` (the hook scripts themselves) and `info/` (lefthook's
# config-checksum file). Hooks never need to *run* inside the container, only install without
# erroring, so an empty per-project volume is all either needs — and the host's real
# `.git/hooks` is never touched. Both dirs are created on the host first when missing: docker
# cannot create a mount point inside a read-only mount.
#
# The file is per worktree, so for a *linked* worktree it also carries that worktree's own
# `environment:` values, pointing git in the container at its subdirectory under the mount:
#   GIT_COMMON_DIR=/git-common
#   GIT_DIR=/git-common/worktrees/<name>
# A plain (non-worktree) checkout gets neither: its `.git` is already a real, writable directory
# reachable through the project's normal bind mount, and pointing GIT_DIR there would only take
# away write access that already worked.
# Never GIT_CONFIG_COUNT/GIT_CONFIG_KEY_<n>/GIT_CONFIG_VALUE_<n>: that is a numbered list, and a
# bare passthrough can only name a fixed set of its indices. A host shell with GIT_CONFIG_COUNT=2
# (credential wrappers, IDE terminals and CI runners set these) would hand the container a count
# with no matching KEY_1, and every git command in it aborts with "missing config key". The host's
# git config points at host helpers and paths anyway, so none of it belongs in a container.
#   CREW_GIT_MOUNT=on   (default) mount, and bake the worktree's GIT_* values
#   CREW_GIT_MOUNT=off  never mount, no GIT_* entries
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
  ""|services|ecosystem|container-src|manifest-dirs|platform|project-name|vendor-paths|owner-prefix) ;;
  *)
    echo "Error: --query must be one of: services, ecosystem, container-src, manifest-dirs, platform, project-name, vendor-paths, owner-prefix" >&2
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

# <proj>: MAIN_ROOT's basename; <owner4>: this host + MAIN_ROOT's realpath.
PROJ_SLUG=$(basename "$MAIN_ROOT" | tr -cs 'a-zA-Z0-9' '_' | sed 's/_*$//')
OWNER4="$(printf '%s\n%s\n' "$(hostname 2>/dev/null || uname -n)" "$(cd "$MAIN_ROOT" && pwd -P)" | _sha256 | awk '{print substr($1, 1, 4)}')"
OWNER_PREFIX="wt_${PROJ_SLUG}_${OWNER4}_"

if [[ "$QUERY" == "owner-prefix" ]]; then
  echo "$OWNER_PREFIX"
  exit 0
fi

# This worktree's override path and git-env entries, resolved from PROJECT_ROOT before the
# sparse-worktree fallback below can swap PROJECT_ROOT for MAIN_ROOT.
GIT_DIR_ABS="$(git -C "$PROJECT_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
OVERRIDE_PATH=""
[[ -z "$GIT_DIR_ABS" ]] || OVERRIDE_PATH="$GIT_DIR_ABS/crew-compose.override.yml"
if [[ -z "$OVERRIDE_PATH" && -z "$QUERY" && "$DRY_RUN" -eq 0 ]]; then
  echo "Error: $PROJECT_ROOT is not a git checkout — the override is written to its git dir" >&2
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
ECO_ENV_PASSTHROUGH=()

detect_ecosystem() {
  if find "$PROJECT_ROOT" -maxdepth 5 -name 'package.json' \
      -not -path '*/node_modules/*' \
      -not -path "$PROJECT_ROOT/*/\.*/*" -print -quit 2>/dev/null | grep -q .; then
    ECO_NAME="node"; ECO_VENDOR="node_modules"; ECO_PREFIX="nm"
    ECO_DEPTH=5; ECO_EXCLUDE="node_modules"
    # NPM_TOKEN: bare name only, never a value — see "the env vars ... are never *valued*
    # in the file" above. Lets a project's .npmrc reference ${NPM_TOKEN} for private-registry
    # auth during `npm install`, resolved from whatever process invokes `docker compose run`.
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

# ---------------------------------------------------------------------------
# Resolve the git-common mount (see CREW_GIT_MOUNT in the header comment), and, for a linked
# worktree, the GIT_* values pointing a container at this worktree's own git dir under it.
# ---------------------------------------------------------------------------

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
# Mount points for the writable overlays — see "Git metadata mount".
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

# ---------------------------------------------------------------------------
# Find manifest directories and build volume list
# ---------------------------------------------------------------------------

# PROJECT_NAME — the compose top-level `name:` value (see the "Project name" header comment
# above). It must be the name compose itself picks for the main checkout without our override,
# or the project's own `docker compose up` and ours create two `<name>_default` networks whose
# services cannot reach each other. So: the project's own top-level `name:` when it has a
# literal one, else MAIN_ROOT's basename normalised as compose does — lowercased, characters
# outside [a-z0-9_-] dropped, leading `_`/`-` trimmed. Not PROJ_SLUG: that turns `-` into `_`.
PROJECT_NAME=$(sed -nE 's/^name:[[:space:]]*["'\'']?([^"'\''#[:space:]]+)["'\'']?[[:space:]]*(#.*)?$/\1/p' \
  "$COMPOSE_FILE" | head -1)
if [[ -z "$PROJECT_NAME" || "$PROJECT_NAME" == *'$'* ]]; then
  PROJECT_NAME=$(basename "$MAIN_ROOT" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-' | sed 's/^[_-]*//')
fi
if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="proj_$(echo "$PROJ_SLUG" | tr 'A-Z' 'a-z')"
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

# The lock hash: one over every manifest and lockfile under the (possibly fallen-back) project root.
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
    vendor-paths)  printf '%s\n' "${VOL_PATHS[@]}" ;;
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
  for vol in "${VOL_NAMES[@]}"; do
    echo "  ${vol}:"
    echo "    name: ${vol}"
  done
  if [[ -n "$GIT_COMMON_DIR_ABS" ]]; then
    echo "  wt_${PROJ_SLUG}_git_hooks:"
    echo "  wt_${PROJ_SLUG}_git_info:"
  fi
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

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
