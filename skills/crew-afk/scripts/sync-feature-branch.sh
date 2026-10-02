#!/usr/bin/env bash
set -uo pipefail

# sync-feature-branch.sh — bring origin/<default> into a resumed feature branch that lacks it.
#
# Usage: sync-feature-branch.sh [--dry-run] <feature-branch>     (run in the main checkout)
#
# A feature branch whose earlier work was squash-merged to origin/<default> has the same tree
# but not the squash commit in its history: version-bump checks measure from a stale merge-base
# and the next PR lists the merged commits again.
#
#   - fetches origin/<default> (origin/HEAD, else main); no `origin`, a failed fetch, a missing
#     origin/<default> or a missing branch is a silent skip (exit 0)
#   - origin/<default> already an ancestor of the branch: nothing to do, prints nothing
#   - otherwise `git merge --no-ff` into the branch. A conflict only in registry.json versions /
#     CHANGELOG.md appends is resolved by resolve-merge-conflicts.sh and committed; any other
#     conflict aborts the merge (branch at its old tip, clean tree), prints the files and exits 1
#   - never changes a registry.json version by itself and never pushes
#   - --dry-run prints whether a merge would happen and merges nothing
#
# Prints: SYNC: merged origin/<default> (<n> commit(s)) into <branch> at <sha>

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
BRANCH="${1:-}"
[ -n "$BRANCH" ] || { echo "usage: sync-feature-branch.sh [--dry-run] <feature-branch>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null; return 0; }

git remote get-url origin >/dev/null 2>&1 || exit 0
DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
[ -n "$DEFAULT" ] || DEFAULT=main
git fetch -q --no-tags origin "$DEFAULT" >/dev/null 2>&1 || exit 0
UPSTREAM="origin/$DEFAULT"
git rev-parse --verify --quiet "${UPSTREAM}^{commit}" >/dev/null || exit 0
git rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" >/dev/null || exit 0
git merge-base --is-ancestor "$UPSTREAM" "$BRANCH" && exit 0

COUNT=$(git rev-list --count "$BRANCH..$UPSTREAM" 2>/dev/null || echo 0)
if [ "$DRY" -eq 1 ]; then
  echo "SYNC: would merge $UPSTREAM ($COUNT commit(s)) into $BRANCH"
  exit 0
fi

CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT" != "$BRANCH" ]; then
  git checkout -q "$BRANCH" 2>&1 || { echo "SYNC: cannot switch to $BRANCH" >&2; exit 1; }
fi

MSG="Merge $UPSTREAM into $BRANCH"
OUT=$(git merge --no-ff --no-verify -m "$MSG" "$UPSTREAM" 2>&1)
if [ $? -ne 0 ]; then
  RESOLVED=""
  if RESOLVED=$(bash "$SCRIPT_DIR/resolve-merge-conflicts.sh" 2>/dev/null) \
     && git commit --no-verify -q -m "$MSG" >/dev/null 2>&1; then
    while IFS= read -r line; do [ -n "$line" ] && _trace SYNC "auto-resolved: $line"; done <<<"$RESOLVED"
  else
    FILES=$(git diff --name-only --diff-filter=U 2>/dev/null | paste -sd, - | sed 's/,/, /g')
    git merge --abort >/dev/null 2>&1 || true
    echo "SYNC: conflict merging $UPSTREAM into $BRANCH — ${FILES:-${OUT:-see git output}}" >&2
    _trace --level error SYNC "branch=$BRANCH success=false reason=conflict files=${FILES:-none}"
    exit 1
  fi
fi

SHA=$(git rev-parse --short HEAD)
echo "SYNC: merged $UPSTREAM ($COUNT commit(s)) into $BRANCH at $SHA"
_trace SYNC "merged $UPSTREAM ($COUNT commit(s)) into $BRANCH at $SHA"
exit 0
