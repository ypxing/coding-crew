#!/usr/bin/env bash
set -uo pipefail

# sync-feature-branch.sh — merge origin/<default> into a resumed feature branch that lacks it, or
# work squash-merged there leaves a stale merge-base and the next PR re-lists its commits.
# Usage: sync-feature-branch.sh [--dry-run] <feature-branch>     (run in that branch's checkout)
# Anything missing (origin, fetch, branch) is a silent skip. Only registry versions and CHANGELOG
# appends auto-resolve; any other conflict aborts (old tip, clean tree), prints the files, exits 1.

DRY=0
if [ "${1:-}" = "--dry-run" ]; then DRY=1; shift; fi
BRANCH="${1:-}"
[ -n "$BRANCH" ] || { echo "usage: sync-feature-branch.sh [--dry-run] <feature-branch>" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" ${FEATURE_SLUG:+--feature-slug "$FEATURE_SLUG"} "$@" 2>/dev/null || true; return 0; }

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

# Never switches a checkout: the sprint's crew/<slug>/_feature worktree is the one on $BRANCH.
CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT" != "$BRANCH" ]; then
  echo "SYNC: run this in the checkout of $BRANCH (this one is on $CURRENT)" >&2
  exit 1
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
