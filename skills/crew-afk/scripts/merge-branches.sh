#!/usr/bin/env bash
set -uo pipefail

# merge-branches.sh — merge a list of branches onto a feature branch
#
# Usage: merge-branches.sh <feature-branch> <branch1> [branch2 ...]
#
# For each branch:
#   - Refuses any crew/<feature>/<issue> branch without a current verification
#     receipt (see receipts.sh). The check gate was prose-only before, so an
#     orchestrator that skipped or ignored it could merge failing code; now the
#     merge itself fails closed. Non-crew branches are not gated.
#   - If already merged (git log HEAD..<branch> is empty), reports success with no action.
#   - Otherwise performs a no-fast-forward merge.
#   - On conflict: aborts cleanly and reports failure; NEVER attempts resolution.
#   - A failed branch does not abort processing of remaining branches.
#
# Exit code: 0 if every branch succeeded, non-zero if any branch failed.

if [ $# -lt 2 ]; then
  echo "Usage: $0 <feature-branch> <branch1> [branch2 ...]" >&2
  exit 1
fi

FEATURE_BRANCH="$1"
shift
BRANCHES=("$@")

RECEIPTS_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/receipts.sh"

# Ensure we are on the feature branch
CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT" != "$FEATURE_BRANCH" ]; then
  git checkout "$FEATURE_BRANCH" 2>&1 || { echo "ERROR: cannot switch to $FEATURE_BRANCH" >&2; exit 1; }
fi

FAILED=0

for BRANCH in "${BRANCHES[@]}"; do
  # Resolve the ref first. Without this, `git log HEAD..<branch>` errors on an
  # unknown ref and (with stderr suppressed) leaves PENDING empty — which is
  # indistinguishable from "already merged", so a typo'd or deleted branch would
  # report success and be silently skipped.
  if ! git rev-parse --verify --quiet "${BRANCH}^{commit}" >/dev/null; then
    echo "MERGE: $BRANCH failed (no such branch)" >&2
    FAILED=1
    continue
  fi

  # Gate before touching the working tree. A branch that was never verified (or
  # was verified at an earlier commit) is skipped, not merged — and skipping it
  # is a failure, so the sprint cannot report it as merged.
  if [ -f "$RECEIPTS_SCRIPT" ]; then
    if ! bash "$RECEIPTS_SCRIPT" check verify --branch "$BRANCH"; then
      echo "MERGE: $BRANCH failed (unverified — see receipt error above)" >&2
      FAILED=1
      continue
    fi
  fi

  # Check if already merged: git log HEAD..<branch> is empty when already merged
  PENDING=$(git log "HEAD..${BRANCH}" --oneline 2>/dev/null)
  if [ -z "$PENDING" ]; then
    echo "MERGE: $BRANCH already-merged success"
    continue
  fi

  # Attempt merge
  if git merge --no-ff "$BRANCH" -m "Merge branch '$BRANCH'" 2>&1; then
    echo "MERGE: $BRANCH success"
  else
    # Abort the failed merge to leave a clean state
    git merge --abort 2>/dev/null || true
    echo "MERGE: $BRANCH failed (conflict — aborted cleanly)" >&2
    FAILED=1
    # Continue to next branch
  fi
done

exit $FAILED
