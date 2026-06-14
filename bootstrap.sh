#!/bin/bash
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
#   curl -fsSL .../bootstrap.sh | bash -s -- copilot
#   curl -fsSL .../bootstrap.sh | bash -s -- copilot --skills tdd,caveman
#   curl -fsSL .../bootstrap.sh | bash -s -- --project
set -euo pipefail

REPO="https://github.com/ypxing/coding-crew"
BRANCH="${BRANCH:-main}"
PLATFORM="${PLATFORM:-all}"
SKILLS="${SKILLS:-}"
PROJECT="${PROJECT:-}"

# Positional args override env vars
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT=1; shift ;;
    --skills=*) SKILLS="${1#--skills=}"; shift ;;
    --skills) SKILLS="${2:-}"; shift 2 ;;
    all|claude|copilot) PLATFORM="$1"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

USER_FLAG="--user"
[[ -n "$PROJECT" ]] && USER_FLAG=""

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "Downloading ai-agents ($BRANCH)..."
curl -fsSL "$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar xz -C "$TMP_DIR" --strip-components=1

INSTALL="$TMP_DIR/install.sh"
chmod +x "$INSTALL"

if [[ -n "$SKILLS" ]]; then
  exec "$INSTALL" $USER_FLAG "$PLATFORM" --skills "$SKILLS"
else
  exec "$INSTALL" $USER_FLAG "$PLATFORM"
fi
