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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECEIPTS_SCRIPT="$SCRIPT_DIR/receipts.sh"

# Each script traces its own step, so a merge that happened is always in the trace and
# a merge that was skipped can never be traced as if it had run.
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null; return 0; }

# Ensure we are on the feature branch
CURRENT=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT" != "$FEATURE_BRANCH" ]; then
  git checkout "$FEATURE_BRANCH" 2>&1 || { echo "ERROR: cannot switch to $FEATURE_BRANCH" >&2; exit 1; }
fi

# ─── docker-mode merge ─────────────────────────────────────────────────────────
#
# This script always runs at MAIN_ROOT (never a linked worktree — pipeline.mjs's
# mergeAndClose checks out the feature branch there before calling this), so the same
# `agent.install-mode` flag ensure-deps.sh writes for the sprint's worker worktrees
# (skills/crew-afk/scripts/ensure-deps.sh's docker path) is already visible here too:
# `--local` git config lives in the one `.git/config` every worktree of this repo shares,
# with no `extensions.worktreeConfig` in play, so a worktree call's write and this
# MAIN_ROOT read are the same file. When a project's dev tooling only exists inside its
# docker service (pnpm, etc.), a plain host `git merge --no-ff` below is exactly the
# ensure-deps.sh/verify-worktree.sh problem verify-worktree.sh's own docker path was
# built to fix, just one step later: the merge commit fires a commit-msg hook
# (lefthook -> commitlint -> pnpm) that has nothing to run against on the host, and gets
# recorded as an ordinary merge conflict even though nothing actually conflicted.
#
# CREW_MERGE_DOCKER=off is the rollback lever, matching CREW_VERIFY_DOCKER's convention —
# every signal below must resolve or this silently falls back to the existing host path.
MERGE_MAIN_ROOT="${MAIN_ROOT:-$(pwd -P)}"
DOCKER_MODE=0
DOCKER_SERVICE=""
DOCKER_CONTAINER_SRC=""
DOCKER_COMPOSE_FILE=""
DOCKER_OVERRIDE_FILE=""

# _find_dep_scripts <main-root> — the same candidate order ensure-deps.sh/verify-worktree.sh
# use, so this script finds dep-install the same way regardless of which platform installed it.
_find_dep_scripts() {
  local main_root="$1"
  if [ -n "${CREW_DEP_INSTALL_SCRIPTS:-}" ]; then
    [ -f "$CREW_DEP_INSTALL_SCRIPTS/gen-override.sh" ] && printf '%s' "$CREW_DEP_INSTALL_SCRIPTS"
    return 0
  fi
  local candidate
  for candidate in \
    "$main_root/.coding-crew/dep-install/scripts" \
    "$main_root/.claude/skills/dep-install/scripts" \
    "$main_root/.pi/skills/dep-install/scripts" \
    "$main_root/.agents/skills/dep-install/scripts" \
    "$main_root/.github/skills/dep-install/scripts" \
    "$main_root/skills/dep-install/scripts"; do
    if [ -f "$candidate/gen-override.sh" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
}

# _detect_docker_mode — populates the DOCKER_* globals when the merge commit below must run
# through `docker compose run` instead of directly on the host. MAIN_ROOT is never a linked
# worktree, so --project-root and --main-root are the same path here — unlike
# verify-worktree.sh's per-worktree call, there is no GIT_DIR/hooksPath redirect to resolve.
_detect_docker_mode() {
  local mode
  mode=$(git -C "$MERGE_MAIN_ROOT" config --local agent.install-mode 2>/dev/null || true)
  [ "$mode" = "docker" ] || return 1

  local override_file="$MERGE_MAIN_ROOT/docker-compose.override.yml"
  [ -f "$override_file" ] || return 1

  local compose_file="" name
  for name in docker-compose.yml docker-compose.yaml compose.yml; do
    if [ -f "$MERGE_MAIN_ROOT/$name" ]; then compose_file="$MERGE_MAIN_ROOT/$name"; break; fi
  done
  [ -n "$compose_file" ] || return 1

  local scripts_dir
  scripts_dir="$(_find_dep_scripts "$MERGE_MAIN_ROOT")"
  [ -n "$scripts_dir" ] || return 1

  local service
  service=$(git -C "$MERGE_MAIN_ROOT" config --local agent.install-service 2>/dev/null || true)
  if [ -z "$service" ] && [ -f "$MERGE_MAIN_ROOT/.coding-crew/dev-commands.json" ]; then
    service=$(grep -o '"docker_service"[[:space:]]*:[[:space:]]*"[^"]*"' "$MERGE_MAIN_ROOT/.coding-crew/dev-commands.json" 2>/dev/null \
      | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"$/\1/' || true)
  fi
  if [ -z "$service" ]; then
    service=$(bash "$scripts_dir/gen-override.sh" --project-root "$MERGE_MAIN_ROOT" --main-root "$MERGE_MAIN_ROOT" --query services 2>/dev/null | head -1)
  fi
  [ -n "$service" ] || return 1

  local container_src
  container_src=$(bash "$scripts_dir/gen-override.sh" --project-root "$MERGE_MAIN_ROOT" --main-root "$MERGE_MAIN_ROOT" --query container-src 2>/dev/null)
  [ -n "$container_src" ] || return 1

  DOCKER_MODE=1
  DOCKER_SERVICE="$service"
  DOCKER_CONTAINER_SRC="$container_src"
  DOCKER_COMPOSE_FILE="$compose_file"
  DOCKER_OVERRIDE_FILE="$override_file"
}

if [ "${CREW_MERGE_DOCKER:-on}" != "off" ]; then
  _detect_docker_mode || true
fi

# Git identity for the merge commit itself. A container never mounts ~/.gitconfig (only
# MAIN_ROOT's repo directory), so a host identity set only at the global level would
# otherwise be invisible inside it and the commit would fail with "Please tell me who you
# are" instead of the hook problem this exists to route around. `git config user.name`
# (no --local) resolves local-then-global-then-system exactly like the plain `git commit`
# a host-mode merge already relies on, so this is the same identity either way — just
# carried across the container boundary explicitly instead of assumed.
if [ "$DOCKER_MODE" -eq 1 ]; then
  MERGE_GIT_AUTHOR_NAME="$(git -C "$MERGE_MAIN_ROOT" config user.name 2>/dev/null || true)"
  MERGE_GIT_AUTHOR_EMAIL="$(git -C "$MERGE_MAIN_ROOT" config user.email 2>/dev/null || true)"
  echo "MERGE: via docker compose run --rm $DOCKER_SERVICE (container-src: $DOCKER_CONTAINER_SRC)"
fi

# _do_merge <branch> <message> — runs the merge commit on the host, or inside the docker
# service when DOCKER_MODE says the project's own tooling (and any commit hook that shells
# out to it) only exists there. Prints the command's combined output; returns its exit code.
_do_merge() {
  local branch="$1" message="$2"
  if [ "$DOCKER_MODE" -eq 1 ]; then
    local full_cmd="cd \"$DOCKER_CONTAINER_SRC\" && git merge --no-ff \"\$MERGE_BRANCH\" -m \"\$MERGE_MSG\""
    docker compose -f "$DOCKER_COMPOSE_FILE" -f "$DOCKER_OVERRIDE_FILE" run --rm \
      -e GIT_AUTHOR_NAME="$MERGE_GIT_AUTHOR_NAME" -e GIT_AUTHOR_EMAIL="$MERGE_GIT_AUTHOR_EMAIL" \
      -e GIT_COMMITTER_NAME="$MERGE_GIT_AUTHOR_NAME" -e GIT_COMMITTER_EMAIL="$MERGE_GIT_AUTHOR_EMAIL" \
      -e MERGE_BRANCH="$branch" -e MERGE_MSG="$message" \
      "$DOCKER_SERVICE" sh -c "$full_cmd" 2>&1
    return $?
  fi
  git merge --no-ff "$branch" -m "$message" 2>&1
}

FAILED=0

for BRANCH in "${BRANCHES[@]}"; do
  # Resolve the ref first. Without this, `git log HEAD..<branch>` errors on an
  # unknown ref and (with stderr suppressed) leaves PENDING empty — which is
  # indistinguishable from "already merged", so a typo'd or deleted branch would
  # report success and be silently skipped.
  if ! git rev-parse --verify --quiet "${BRANCH}^{commit}" >/dev/null; then
    echo "MERGE: $BRANCH failed (no such branch)" >&2
    _trace MERGE "branch=$BRANCH success=false reason=no-such-branch"
    FAILED=1
    continue
  fi

  # Gate before touching the working tree. A branch that was never verified (or
  # was verified at an earlier commit) is skipped, not merged — and skipping it
  # is a failure, so the sprint cannot report it as merged.
  if [ -f "$RECEIPTS_SCRIPT" ]; then
    if ! bash "$RECEIPTS_SCRIPT" check verify --branch "$BRANCH"; then
      echo "MERGE: $BRANCH failed (unverified — see receipt error above)" >&2
      _trace MERGE "branch=$BRANCH success=false reason=unverified"
      FAILED=1
      continue
    fi
  fi

  # Check if already merged: git log HEAD..<branch> is empty when already merged
  PENDING=$(git log "HEAD..${BRANCH}" --oneline 2>/dev/null)
  if [ -z "$PENDING" ]; then
    echo "MERGE: $BRANCH already-merged success"
    _trace MERGE "branch=$BRANCH success=true reason=already-merged"
    continue
  fi

  # Attempt merge
  if _do_merge "$BRANCH" "Merge branch '$BRANCH'"; then
    echo "MERGE: $BRANCH success"
    _trace MERGE "branch=$BRANCH success=true"
  else
    # Abort the failed merge to leave a clean state
    git merge --abort 2>/dev/null || true
    echo "MERGE: $BRANCH failed (conflict — aborted cleanly)" >&2
    _trace MERGE "branch=$BRANCH success=false reason=conflict"
    FAILED=1
    # Continue to next branch
  fi
done

exit $FAILED
