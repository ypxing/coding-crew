#!/usr/bin/env bash
set -euo pipefail

# Commit changes with standardized format
# Usage: commit-changes.sh --message "msg" --files "file1 file2" [--coauthor "Name <email>"] [--prefix "[slug]"]

MESSAGE=""
FILES=()
COAUTHOR=""
PREFIX=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message)
      MESSAGE="$2"
      shift 2
      ;;
    --files)
      # Read files as space-separated string
      IFS=' ' read -ra FILES <<< "$2"
      shift 2
      ;;
    --coauthor)
      COAUTHOR="$2"
      shift 2
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: commit-changes.sh --message MSG --files 'file1 file2' [--coauthor 'Name <email>'] [--prefix '[slug]']" >&2
      exit 1
      ;;
  esac
done

if [ -z "$MESSAGE" ]; then
  echo "ERROR: --message is required" >&2
  exit 1
fi

if [ ${#FILES[@]} -eq 0 ]; then
  echo "ERROR: --files is required" >&2
  exit 1
fi

# Use PROJECT_ROOT if set, otherwise current directory
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

# Stage files (never use git add -A)
echo "Staging files:"
for file in "${FILES[@]}"; do
  echo "  - $file"
  git -C "$PROJECT_ROOT" add "$file"
done

# Build commit message
if [ -n "$PREFIX" ]; then
  FULL_MESSAGE="$PREFIX $MESSAGE"
else
  FULL_MESSAGE="$MESSAGE"
fi

# Add co-author if provided
if [ -n "$COAUTHOR" ]; then
  FULL_MESSAGE="${FULL_MESSAGE}

Co-authored-by: ${COAUTHOR}"
fi

# Commit
git -C "$PROJECT_ROOT" commit -m "$FULL_MESSAGE"

if [ $? -eq 0 ]; then
  echo "Committed successfully"
  git -C "$PROJECT_ROOT" log -1 --oneline
else
  echo "ERROR: Commit failed" >&2
  exit 1
fi
