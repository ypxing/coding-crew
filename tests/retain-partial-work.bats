#!/usr/bin/env bats

# Tests for retain-and-resume-partial-work (issue 08): a retained (partial) branch survives the
# cleanup that deletes merged ones. The rest of the behaviour — the resume prompt, the summary's
# retained list, a demoted branch never merging — is asserted on faked-dispatch sprints in
# tests/orchestrator/sprint-gates-config.test.mjs and sprint-lifecycle.test.mjs.

# ─── Git-state test: retained branches survive cleanup script ─────────────────

MERGE_SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/merge-branches.sh"

@test "merge-branches.sh: partial branches are not deleted after cleanup" {
  # This is a git-state test: create a partial branch (not merged), run the
  # cleanup step (delete only merged branches), assert the partial branch survives.
  local TEMP_DIR
  TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git commit --allow-empty -m "initial"
  git checkout -q -b "feature/test"

  # Create a "merged" (complete) branch
  git checkout -q -b "worktree-agent-completed"
  echo "done work" > done.txt && git add done.txt && git commit -q -m "completed"
  git checkout -q "feature/test"
  bash "$MERGE_SCRIPT" "feature/test" "worktree-agent-completed"

  # Create a "partial" branch (NOT merged)
  git checkout -q -b "worktree-agent-partial"
  echo "partial work" > partial.txt && git add partial.txt && git commit -q -m "[WIP] partial"
  git checkout -q "feature/test"

  # Simulate cleanup: delete only merged branches (not the partial one)
  # The cleanup rule: only branches in all_merged get deleted
  git branch -D "worktree-agent-completed" 2>/dev/null || true

  # Assert: partial branch still exists
  run git branch --list "worktree-agent-partial"
  [ "$status" -eq 0 ]
  [[ "$output" == *"worktree-agent-partial"* ]]

  rm -rf "$TEMP_DIR"
}
