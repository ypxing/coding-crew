#!/usr/bin/env bash
set -euo pipefail

# Branch safety check - ensures not on default branch
# Usage: branch-safety-check.sh [--allow-default]
# Exit code: 0 if safe, 1 if on default branch (unless --allow-default)

ALLOW_DEFAULT=false

if [[ "${1:-}" == "--allow-default" ]]; then
  ALLOW_DEFAULT=true
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')

# Fallback to "main" if origin/HEAD is not set
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH="main"
fi

if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  if [ "$ALLOW_DEFAULT" = false ]; then
    echo "ERROR: Cannot run on default branch ($DEFAULT_BRANCH). Switch to your PR branch first: git checkout <branch-name>" >&2
    exit 1
  else
    echo "Warning: Running on default branch ($DEFAULT_BRANCH)" >&2
  fi
fi

echo "Branch: $CURRENT_BRANCH"
exit 0
