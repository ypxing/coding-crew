#!/bin/bash
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
#   curl -fsSL .../bootstrap.sh | bash -s -- copilot
#   curl -fsSL .../bootstrap.sh | bash -s -- copilot --skills tdd,to-issues
#   curl -fsSL .../bootstrap.sh | bash -s -- --project
#   curl -fsSL .../bootstrap.sh | bash -s -- --update
set -euo pipefail

REPO="https://github.com/ypxing/coding-crew"
BRANCH="${BRANCH:-main}"
PLATFORM=all
SKILLS=""
PROJECT=""
UPDATE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT=1; shift ;;
    --skills=*) SKILLS="${1#--skills=}"; shift ;;
    --skills) SKILLS="${2:-}"; shift 2 ;;
    --update) UPDATE=1; shift ;;
    -*) echo "Unknown argument: $1" >&2; exit 1 ;;
    # Any other word is the platform; install.sh validates it against platforms.json.
    *) PLATFORM="$1"; shift ;;
  esac
done

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "Downloading coding-crew ($BRANCH)..."
curl -fsSL "$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar xz -C "$TMP_DIR" --strip-components=1

INSTALL="$TMP_DIR/install.sh"
chmod +x "$INSTALL"

# User level ($HOME) is install.sh's default; --project installs into the current repo.
LEVEL=()
[[ -z "$PROJECT" ]] || LEVEL=(--project)

if [[ -n "$UPDATE" ]]; then
  exec "$INSTALL" --update "${LEVEL[@]+"${LEVEL[@]}"}"
elif [[ -n "$SKILLS" ]]; then
  exec "$INSTALL" "$PLATFORM" --skills "$SKILLS" "${LEVEL[@]+"${LEVEL[@]}"}"
else
  exec "$INSTALL" "$PLATFORM" "${LEVEL[@]+"${LEVEL[@]}"}"
fi
