#!/usr/bin/env bash
set -uo pipefail

# sync-pr-with-main.sh — merge origin/main into a PR branch.
# Usage: scripts/sync-pr-with-main.sh <branch>
# A CHANGELOG.md append conflict is resolved (both kept, the branch's entries first); any other
# conflict leaves the merge in progress and exits 1. Never pushes.

REMOTE=origin
MAIN="$REMOTE/main"
die() { echo "sync-pr-with-main: $*" >&2; exit 1; }

BRANCH="${1:-}"
[ -n "$BRANCH" ] || die "usage: $0 <branch>"
git rev-parse --show-toplevel >/dev/null 2>&1 || die "not inside a git repository"
command -v node >/dev/null 2>&1 || die "node is required"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TOP=$(git rev-parse --show-toplevel)
cd "$TOP" || exit 1

git fetch "$REMOTE" || die "git fetch $REMOTE failed"
git rev-parse --verify -q "$MAIN^{commit}" >/dev/null || die "$MAIN not found after fetch"
git checkout "$BRANCH" || die "cannot check out $BRANCH"

git merge-base HEAD "$MAIN" >/dev/null || die "no merge-base between $BRANCH and $MAIN"

if ! git merge --no-ff --no-commit "$MAIN"; then
  CONFLICTS=$(git diff --name-only --diff-filter=U)
  if [ -z "$CONFLICTS" ] || ! bash "$SCRIPT_DIR/resolve-merge-conflicts.sh"; then
    echo "sync-pr-with-main: merge of $MAIN into $BRANCH has conflicts that need a human:" >&2
    if [ -n "$CONFLICTS" ]; then printf '  %s\n' $CONFLICTS >&2; else echo "  (merge failed without conflicts; see git output above)" >&2; fi
    echo "The merge is left in progress; resolve, commit, or 'git merge --abort'." >&2
    exit 1
  fi
fi

if ! git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  echo "$BRANCH already contains $MAIN; nothing to do."
  exit 0
fi

git commit -q -m "Merge $MAIN into $BRANCH" || die "commit failed; merge left in progress"
echo "Merged $MAIN into $BRANCH at $(git rev-parse --short HEAD). Not pushed."
