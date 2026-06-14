#!/bin/bash
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/OWNER/REPO/main/bootstrap.sh | bash
#   SKILLS=tdd,caveman bash <(curl -fsSL ...)
#   PLATFORM=claude SKILLS=afk-sprint bash <(curl -fsSL ...)
#   PROJECT=1 bash <(curl -fsSL ...)             # install into current project instead of $HOME
set -euo pipefail

REPO="https://github.com/OWNER/REPO"
BRANCH="${BRANCH:-main}"
PLATFORM="${PLATFORM:-all}"
SKILLS="${SKILLS:-}"
USER_FLAG="--user"
[[ -n "${PROJECT:-}" ]] && USER_FLAG=""

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
