#!/bin/bash
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
#   curl -fsSL .../bootstrap.sh | bash -s -- copilot
#   curl -fsSL .../bootstrap.sh | bash -s -- pi
#   curl -fsSL .../bootstrap.sh | bash -s -- codex
#   curl -fsSL .../bootstrap.sh | bash -s -- copilot --skills tdd,caveman
#   curl -fsSL .../bootstrap.sh | bash -s -- --project
#   curl -fsSL .../bootstrap.sh | bash -s -- --version v1.0.0
#   curl -fsSL .../bootstrap.sh | bash -s -- --version latest
#   curl -fsSL .../bootstrap.sh | bash -s -- --from-lockfile
#   curl -fsSL .../bootstrap.sh | bash -s -- --from-lockfile path/to/crew.lock
#   curl -fsSL .../bootstrap.sh | bash -s -- --update
set -euo pipefail

REPO="https://github.com/ypxing/coding-crew"
BRANCH="${BRANCH:-main}"
VERSION="${VERSION:-}"
PLATFORM="${PLATFORM:-all}"
SKILLS="${SKILLS:-}"
PROJECT="${PROJECT:-}"
UPDATE="${UPDATE:-}"
LOCKFILE_MODE="${LOCKFILE_MODE:-}"
LOCKFILE="${LOCKFILE:-}"

# Positional args override env vars
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT=1; shift ;;
    --version=*) VERSION="${1#--version=}"; shift ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    --skills=*) SKILLS="${1#--skills=}"; shift ;;
    --skills) SKILLS="${2:-}"; shift 2 ;;
    --update) UPDATE=1; shift ;;
    --from-lockfile=*) LOCKFILE_MODE=1; LOCKFILE="${1#--from-lockfile=}"; shift ;;
    --from-lockfile)
      LOCKFILE_MODE=1; shift
      if [[ $# -gt 0 && "$1" != --* && "$1" != all && "$1" != claude && "$1" != copilot && "$1" != pi && "$1" != codex ]]; then
        LOCKFILE="$1"; shift
      fi
      ;;
    all|claude|copilot|pi|codex) PLATFORM="$1"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -n "$LOCKFILE_MODE" ]]; then
  LOCKFILE="${LOCKFILE:-crew.lock}"
  if [[ ! -f "$LOCKFILE" ]]; then
    echo "Error: lockfile not found: $LOCKFILE" >&2
    exit 1
  fi
fi

# Default to user-level ($HOME); --project installs into the current git repo instead
if [[ -z "$PROJECT" ]]; then
  export TARGET_REPO="$HOME"
fi

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# "latest" is an alias for the newest published release: resolve it to a concrete
# tag here so the tarball URL, the console output, and crew.lock all agree.
if [[ "$VERSION" == "latest" ]]; then
  echo "Resolving latest release..."
  final_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$REPO/releases/latest") || {
    echo "Error: failed to resolve latest release from $REPO/releases/latest" >&2
    exit 1
  }
  VERSION=$(printf '%s' "$final_url" | sed -E 's|.*/releases/tag/([^/]+)$|\1|')
  if [[ -z "$VERSION" || "$VERSION" == "$final_url" ]]; then
    echo "Error: no published releases found at $REPO" >&2
    exit 1
  fi
  echo "Latest release: $VERSION"
fi

if [[ -n "$VERSION" ]]; then
  echo "Downloading coding-crew ($VERSION)..."
  curl -fsSL "$REPO/archive/refs/tags/$VERSION.tar.gz" \
    | tar xz -C "$TMP_DIR" --strip-components=1
else
  echo "Downloading coding-crew ($BRANCH)..."
  curl -fsSL "$REPO/archive/refs/heads/$BRANCH.tar.gz" \
    | tar xz -C "$TMP_DIR" --strip-components=1
fi

INSTALL="$TMP_DIR/install.sh"
chmod +x "$INSTALL"

# A tarball extract has no .git dir, so install.sh can't derive the registry URL
# itself when writing crew.lock — pass it through explicitly whenever pinning.
PIN_ARGS=()
if [[ -n "$VERSION" ]]; then
  PIN_ARGS=(--version "$VERSION" --registry "$REPO")
fi

if [[ -n "$UPDATE" ]]; then
  exec "$INSTALL" --update
elif [[ -n "$LOCKFILE_MODE" ]]; then
  exec "$INSTALL" --from-lockfile "$LOCKFILE"
elif [[ -n "$SKILLS" ]]; then
  exec "$INSTALL" "$PLATFORM" --skills "$SKILLS" "${PIN_ARGS[@]+"${PIN_ARGS[@]}"}"
else
  exec "$INSTALL" "$PLATFORM" "${PIN_ARGS[@]+"${PIN_ARGS[@]}"}"
fi
