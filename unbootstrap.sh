#!/bin/bash
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
#   SKILLS=tdd,caveman bash <(curl -fsSL ...)
#   PROJECT=1 bash <(curl -fsSL ...)             # uninstall from current project instead of $HOME
set -euo pipefail

REPO="https://github.com/ypxing/coding-crew"
BRANCH="${BRANCH:-main}"
SKILLS="${SKILLS:-}"
AGENT="${AGENT:-}"
USER_FLAG="--user"
[[ -n "${PROJECT:-}" ]] && USER_FLAG=""

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "Downloading ai-agents ($BRANCH)..."
curl -fsSL "$REPO/archive/refs/heads/$BRANCH.tar.gz" \
  | tar xz -C "$TMP_DIR" --strip-components=1

UNINSTALL="$TMP_DIR/uninstall.sh"
chmod +x "$UNINSTALL"

if [[ -n "$SKILLS" ]]; then
  exec "$UNINSTALL" $USER_FLAG --skills "$SKILLS"
elif [[ -n "$AGENT" ]]; then
  exec "$UNINSTALL" $USER_FLAG --agent "$AGENT"
else
  exec "$UNINSTALL" $USER_FLAG
fi
