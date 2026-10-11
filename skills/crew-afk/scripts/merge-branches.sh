#!/usr/bin/env bash
set -uo pipefail

# merge-branches.sh — merge branches (--no-ff) into the feature branch; exit non-zero if any failed.
# Usage: merge-branches.sh <feature-branch> <branch1> [branch2 ...]
# A crew branch without a current verification receipt is refused: the merge fails closed. Only
# registry `version` bumps and CHANGELOG appends are auto-resolved (resolve-merge-conflicts.sh); any
# other conflict aborts cleanly. Uncommitted changes git would overwrite report `main-tree-dirty`,
# which no change to the branch can fix. One failed branch does not stop the rest.

if [ $# -lt 2 ]; then
  echo "Usage: $0 <feature-branch> <branch1> [branch2 ...]" >&2
  exit 1
fi

FEATURE_BRANCH="$1"
shift
BRANCHES=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPTS_SCRIPT="$SCRIPT_DIR/receipts.sh"
RESOLVE_SCRIPT="$SCRIPT_DIR/resolve-merge-conflicts.sh"

# Traced by the step itself, so a skipped merge can never be traced as if it ran.
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" ${FEATURE_SLUG:+--feature-slug "$FEATURE_SLUG"} "$@" 2>/dev/null || true; return 0; }

# Runs in the checkout of the feature branch (the sprint's crew/<slug>/_feature worktree); it
# never switches one, so the main checkout stays on the user's branch.
CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT" != "$FEATURE_BRANCH" ]; then
  echo "ERROR: run this in the checkout of $FEATURE_BRANCH (this one is on $CURRENT)" >&2
  exit 1
fi

# _do_merge <branch> <message> — on the host with --no-verify: the message is a generated template,
# so hooks have nothing to lint, and skipping them drops any need for the project's hook tooling.
_do_merge() {
  local branch="$1" message="$2"
  git merge --no-ff --no-verify "$branch" -m "$message" 2>&1
}

FAILED=0

for BRANCH in "${BRANCHES[@]}"; do
  # Resolve the ref first: an unknown ref leaves PENDING empty, which reads as "already merged".
  if ! git rev-parse --verify --quiet "${BRANCH}^{commit}" >/dev/null; then
    echo "MERGE: $BRANCH failed (no such branch)" >&2
    _trace --level error MERGE "branch=$BRANCH success=false reason=no-such-branch"
    FAILED=1
    continue
  fi

  # Gate before touching the tree; a skipped branch is a failure, never reported as merged.
  if [ -f "$RECEIPTS_SCRIPT" ]; then
    if ! bash "$RECEIPTS_SCRIPT" check verify --branch "$BRANCH"; then
      echo "MERGE: $BRANCH failed (unverified — see receipt error above)" >&2
      _trace --level error MERGE "branch=$BRANCH success=false reason=unverified"
      FAILED=1
      continue
    fi
  fi

  PENDING=$(git log "HEAD..${BRANCH}" --oneline 2>/dev/null)
  if [ -z "$PENDING" ]; then
    echo "MERGE: $BRANCH already-merged success"
    _trace MERGE "branch=$BRANCH success=true reason=already-merged"
    continue
  fi

  MERGE_OUT=$(_do_merge "$BRANCH" "Merge branch '$BRANCH'")
  MERGE_RC=$?
  [ -n "$MERGE_OUT" ] && printf '%s\n' "$MERGE_OUT"
  if [ "$MERGE_RC" -eq 0 ]; then
    echo "MERGE: $BRANCH success"
    _trace MERGE "branch=$BRANCH success=true"
  elif grep -qE 'would be overwritten by (merge|checkout)' <<<"$MERGE_OUT"; then
    # git refused before touching anything, so there is no merge to abort; its indented lines name the files.
    DIRTY=$(printf '%s\n' "$MERGE_OUT" | sed -n 's/^[[:space:]]\{1,\}//p' | paste -sd, - | sed 's/,/, /g')
    echo "MERGE: $BRANCH failed (main-tree-dirty — uncommitted changes in $(pwd) would be overwritten: ${DIRTY:-see git output above})" >&2
    _trace --level error MERGE "branch=$BRANCH success=false reason=main-tree-dirty"
    FAILED=1
  elif [ -f "$RESOLVE_SCRIPT" ] && RESOLVED=$(bash "$RESOLVE_SCRIPT") \
       && git commit --no-verify -q -m "Merge branch '$BRANCH'" >/dev/null 2>&1; then
    # Only version-bump / changelog-append conflicts: resolved mechanically, merge committed.
    printf '%s\n' "$RESOLVED"
    echo "MERGE: $BRANCH success (auto-resolved)"
    _trace MERGE "branch=$BRANCH success=true auto-resolved=true"
    while IFS= read -r line; do [ -n "$line" ] && _trace MERGE "branch=$BRANCH auto-resolved: $line"; done <<<"$RESOLVED"
  else
    git merge --abort 2>/dev/null || true
    echo "MERGE: $BRANCH failed (conflict — aborted cleanly)" >&2
    _trace --level error MERGE "branch=$BRANCH success=false reason=conflict"
    FAILED=1
  fi
done

exit $FAILED
