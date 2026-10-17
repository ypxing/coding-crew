#!/usr/bin/env bash
set -euo pipefail

# Branch safety check - ensures not on default branch
# Usage: branch-safety-check.sh
# Exit code: 0 if safe, 1 if on default branch, 2 on any argument

if [ $# -gt 0 ]; then
  echo "Error: unknown argument: $1" >&2
  exit 2
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
DEFAULT_BRANCH="${DEFAULT_BRANCH#origin/}"

if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH="main"
fi

if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  echo "ERROR: Cannot run on default branch ($DEFAULT_BRANCH). Switch to your PR branch first: git checkout <branch-name>" >&2
  exit 1
fi

echo "Branch: $CURRENT_BRANCH"
exit 0
