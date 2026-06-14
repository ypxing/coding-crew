#!/bin/bash
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
#   curl -fsSL .../unbootstrap.sh | bash -s -- --skills tdd,caveman
#   curl -fsSL .../unbootstrap.sh | bash -s -- --agent coder
#   curl -fsSL .../unbootstrap.sh | bash -s -- --project
set -euo pipefail

REPO="https://github.com/ypxing/coding-crew"
BRANCH="${BRANCH:-main}"
SKILLS="${SKILLS:-}"
AGENT="${AGENT:-}"
PROJECT="${PROJECT:-}"

# Positional args override env vars
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT=1; shift ;;
    --skills=*) SKILLS="${1#--skills=}"; shift ;;
    --skills) SKILLS="${2:-}"; shift 2 ;;
    --agent=*) AGENT="${1#--agent=}"; shift ;;
    --agent) AGENT="${2:-}"; shift 2 ;;
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

UNINSTALL="$TMP_DIR/uninstall.sh"
chmod +x "$UNINSTALL"

if [[ -n "$SKILLS" ]]; then
  exec "$UNINSTALL" $USER_FLAG --skills "$SKILLS"
elif [[ -n "$AGENT" ]]; then
  exec "$UNINSTALL" $USER_FLAG --agent "$AGENT"
else
  exec "$UNINSTALL" $USER_FLAG
fi
