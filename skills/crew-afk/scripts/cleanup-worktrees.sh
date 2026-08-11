#!/usr/bin/env bash
set -uo pipefail

# cleanup-worktrees.sh — tear down sprint worktrees and their branch refs
#
# Usage:
#   cleanup-worktrees.sh [--main-root <path>] [--feature-slug <slug>]
#                        [--merged <branch>]... [--retain <branch>]...
#                        [--dry-run] [--force]
#
#   --merged  a branch this sprint merged; safe to delete (repeatable, or comma-separated)
#             — trusted, because cleanup runs after squash and a squashed merge
#             leaves no ancestry to check
#   --retain  a branch that must survive (partial / verification-failed / criteria-unmet)
#   --feature-slug  enables the sweep: any leftover sprint worktree for this
#                   feature is considered, not just the ones passed in
#   --dry-run report what would happen and change nothing
#   --force   delete a swept branch even when it has commits that are not in HEAD
#
# Why this exists
#   Cleanup used to be prose: "remove the worktree, then delete the ref". Every
#   platform spelled it out slightly differently, an orchestrator that ran out of
#   loop iterations simply never got there, and Claude's runtime-managed
#   worktrees (`.claude/worktrees/agent-*` on `worktree-agent-*` branches) were
#   not covered by any of the variants at all — so a repo accumulated dozens of
#   dead worktrees and branch refs across sprints. This makes teardown one
#   mechanical, idempotent, re-runnable step.
#
# Safety rules (a skip is never an error)
#   - A branch listed with --retain is never touched.
#   - A worktree with uncommitted changes is never removed.
#   - A *swept* branch (one nobody listed) whose tip is not contained in HEAD is
#     never deleted without --force — unmerged work is not thrown away. Branches
#     passed with --merged are exempt: squash rewrites the SHAs, so ancestry
#     would reject every genuinely merged branch.
#   - Order matters: the worktree goes first, because git refuses to delete a
#     ref that some worktree still has checked out.
#
# Exit code: 0 on success (including "nothing to do"); 1 on bad arguments or a
# git failure that left work behind.

MAIN_ROOT=""
FEATURE_SLUG="${FEATURE_SLUG:-}"
DRY_RUN=0
FORCE=0
MERGED=()
RETAIN=()

# Split a comma-separated value into SPLIT[] (bash 3.2-compatible: no namerefs).
SPLIT=()
split_csv() {
  SPLIT=()
  local IFS=',' p
  for p in $2; do
    [ -n "$p" ] && SPLIT+=("$p")
  done
}

while [ $# -gt 0 ]; do
  case "$1" in
    --main-root) MAIN_ROOT="${2:-}"; shift 2 ;;
    --feature-slug) FEATURE_SLUG="${2:-}"; shift 2 ;;
    --merged) split_csv _ "${2:-}"; MERGED+=(${SPLIT[@]+"${SPLIT[@]}"}); shift 2 ;;
    --retain) split_csv _ "${2:-}"; RETAIN+=(${SPLIT[@]+"${SPLIT[@]}"}); shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$MAIN_ROOT" ]; then
  # The main root, not the current worktree: --git-common-dir points at the
  # shared .git directory even when invoked from inside a linked worktree.
  COMMON_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || COMMON_DIR=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd) \
    || { echo "ERROR: not a git repository" >&2; exit 1; }
  [ -n "$COMMON_DIR" ] || { echo "ERROR: not a git repository" >&2; exit 1; }
  MAIN_ROOT=$(cd "$(dirname "$COMMON_DIR")" && pwd)
fi

if ! git -C "$MAIN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: not a git repository: $MAIN_ROOT" >&2
  exit 1
fi

is_explicit_merged() {
  local b="$1" m
  for m in ${MERGED[@]+"${MERGED[@]}"}; do
    [ "$b" = "$m" ] && return 0
  done
  return 1
}

is_retained() {
  local b="$1" r
  for r in ${RETAIN[@]+"${RETAIN[@]}"}; do
    [ "$b" = "$r" ] && return 0
  done
  return 1
}

# ─── inventory: branch -> worktree path for every linked worktree ─────────────

declare -a WT_PATHS=() WT_BRANCHES=()
CUR_PATH=""
while IFS= read -r line; do
  case "$line" in
    worktree\ *) CUR_PATH="${line#worktree }" ;;
    branch\ *)
      b="${line#branch }"; b="${b#refs/heads/}"
      # Skip the main worktree — never a cleanup candidate.
      if [ "$CUR_PATH" != "$MAIN_ROOT" ]; then
        WT_PATHS+=("$CUR_PATH"); WT_BRANCHES+=("$b")
      fi
      ;;
  esac
done < <(git -C "$MAIN_ROOT" worktree list --porcelain)

worktree_for() {
  local b="$1" i
  for i in "${!WT_BRANCHES[@]}"; do
    if [ "${WT_BRANCHES[$i]}" = "$b" ]; then echo "${WT_PATHS[$i]}"; return 0; fi
  done
  return 1
}

# ─── candidate set: explicit --merged plus swept leftovers ────────────────────

CANDIDATES=()
seen_candidate() {
  local b="$1" c
  for c in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
    [ "$c" = "$b" ] && return 0
  done
  return 1
}
add_candidate() { seen_candidate "$1" || CANDIDATES+=("$1"); }

for b in ${MERGED[@]+"${MERGED[@]}"}; do add_candidate "$b"; done

# Sweep: leftover worktrees from this sprint that nobody passed in. Two shapes
# are recognised — the orchestrator-managed `crew/<feature-slug>/<issue>`
# branches, and the runtime-managed worktrees Claude creates for
# `isolation: worktree` agents (`worktree-agent-*`, checked out under
# `.claude/worktrees/`). The latter are the ones that leaked historically: no
# variant ever named them, so nothing removed them.
for i in "${!WT_BRANCHES[@]}"; do
  b="${WT_BRANCHES[$i]}"
  p="${WT_PATHS[$i]}"
  if [ -n "$FEATURE_SLUG" ] && [[ "$b" == crew/"$FEATURE_SLUG"/* ]]; then
    add_candidate "$b"
  elif [[ "$b" == worktree-agent-* ]] || [[ "$p" == */.claude/worktrees/* ]]; then
    add_candidate "$b"
  fi
done

# ─── teardown ────────────────────────────────────────────────────────────────

REMOVED=0
KEPT=0
FAILED=0

for b in ${CANDIDATES[@]+"${CANDIDATES[@]}"}; do
  if is_retained "$b"; then
    echo "CLEANUP: kept $b (retained)"
    KEPT=$((KEPT + 1))
    continue
  fi

  wt="$(worktree_for "$b" || true)"

  if ! git -C "$MAIN_ROOT" rev-parse --verify --quiet "${b}^{commit}" >/dev/null; then
    if [ -n "$wt" ]; then
      echo "CLEANUP: kept $b (worktree $wt has no resolvable branch tip)"
      KEPT=$((KEPT + 1))
    else
      echo "CLEANUP: skipped $b (no such branch)"
    fi
    continue
  fi

  # Never discard uncommitted work.
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
      echo "CLEANUP: kept $b (uncommitted changes in $wt)"
      KEPT=$((KEPT + 1))
      continue
    fi
  fi

  # Never discard commits that are not in HEAD — but only for *swept* branches,
  # whose provenance is unknown. An explicitly listed --merged branch is the
  # orchestrator's own certified list, and ancestry is not checkable for it:
  # cleanup runs after squash, which soft-resets the feature branch and rewrites
  # the merge into a single new commit, so no merged branch tip is ever an
  # ancestor of HEAD by then. Requiring ancestry here would keep every merged
  # branch forever, which is the leak this script exists to stop.
  if [ "$FORCE" -eq 0 ] && ! is_explicit_merged "$b" \
     && ! git -C "$MAIN_ROOT" merge-base --is-ancestor "$b" HEAD 2>/dev/null; then
    echo "CLEANUP: kept $b (commits not in HEAD — merge status unknown, resolve by hand)"
    KEPT=$((KEPT + 1))
    continue
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "CLEANUP: would remove $b${wt:+ (worktree $wt)}"
    REMOVED=$((REMOVED + 1))
    continue
  fi

  # Worktree first: a checked-out ref cannot be deleted.
  if [ -n "$wt" ]; then
    if ! git -C "$MAIN_ROOT" worktree remove --force "$wt" 2>/dev/null; then
      rm -rf "$wt"
      git -C "$MAIN_ROOT" worktree prune
    fi
  fi

  if git -C "$MAIN_ROOT" branch -D -- "$b" >/dev/null 2>&1; then
    echo "CLEANUP: removed $b${wt:+ (worktree $wt)}"
    REMOVED=$((REMOVED + 1))
  else
    echo "CLEANUP: failed to delete branch $b" >&2
    FAILED=$((FAILED + 1))
  fi
done

# Safe unconditionally: prune only clears metadata for worktrees whose directory
# is already gone. It never removes a live, checked-out worktree.
[ "$DRY_RUN" -eq 1 ] || git -C "$MAIN_ROOT" worktree prune

_TRACE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/trace.sh"
[ -f "$_TRACE_SCRIPT" ] && bash "$_TRACE_SCRIPT" CLEANUP "removed=$REMOVED kept=$KEPT failed=$FAILED" 2>/dev/null
echo "CLEANUP: removed=$REMOVED kept=$KEPT failed=$FAILED"

[ "$FAILED" -eq 0 ] || exit 1
exit 0
