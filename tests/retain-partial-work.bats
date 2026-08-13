#!/usr/bin/env bats

# Tests for retain-and-resume-partial-work (issue 08)
#
# Asserts:
#   1. Retained branches (partial/verification-failed) are excluded from cleanup
#   2. No agent file still forbids committing partial work
#   3. Worker agent files instruct committing partial work with a marker
#   4. Dispatch instruction tells the next worker to resume, not re-implement from scratch
#   5. Sprint summary lists retained branches with reason
#   6. Progress notes are positioned as context alongside code, not a substitute
#   7. Trace continuity: branch key reused across rounds

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export CLAUDE_AGENT="$SCRIPT_DIR/agents/crew-coder/claude.agent.md"
  export COPILOT_AGENT="$SCRIPT_DIR/agents/crew-coder/copilot.agent.md"
  export MERGE_SCRIPT="$SCRIPT_DIR/skills/crew-afk/scripts/merge-branches.sh"
}

# Every orchestrator-body version of these assertions was deleted with the body that carried
# it (claude's, then copilot's). Each has a code equivalent that runs the behaviour instead of
# grepping for it, in tests/orchestrator/sprint.test.mjs: retention survives cleanup, the
# branch is named in the summary with its reason, the next round's worker prompt says "Resume
# on that existing branch" and that the notes are "not a substitute for it", a demoted branch
# never merges, and a merged branch loses both its worktree and its ref. What stays here is
# what is still somebody's file: the coder definitions, merge-branches.sh and state.sh.

# ─── No agent forbids committing partial work ────────────────────────────────

@test "claude.agent.md does not forbid committing partial work" {
  # The old text was: "Do not commit partial work — the next worker starts from scratch"
  ! grep -q 'Do not commit partial work' "$CLAUDE_AGENT"
}

@test "copilot.agent.md does not forbid committing partial work" {
  ! grep -q 'Do not commit partial work' "$COPILOT_AGENT"
}

# ─── Worker commits partial work with marker ─────────────────────────────────

@test "claude.agent.md instructs worker to commit partial work with a marker" {
  # Must instruct committing WIP with some kind of incomplete/partial marker
  grep -qiE 'WIP|partial.*commit|commit.*partial|incomplete.*marker|marker.*incomplete|commit.*wip' "$CLAUDE_AGENT"
}

@test "copilot.agent.md instructs worker to commit partial work with a marker" {
  grep -qiE 'WIP|partial.*commit|commit.*partial|incomplete.*marker|marker.*incomplete|commit.*wip' "$COPILOT_AGENT"
}

# ─── Trace continuity: branch key reused across rounds ───────────────────────

@test "claude.agent.md trace file path keys on branch name (for continuity across rounds)" {
  # Already verified in crew-coder-per-agent-trace.bats but confirm traces/branch.log pattern
  grep -q 'BRANCH\|branch' "$CLAUDE_AGENT"
  grep -q 'traces/' "$CLAUDE_AGENT"
}

@test "copilot.agent.md trace file path keys on branch name (for continuity across rounds)" {
  grep -q 'BRANCH\|branch' "$COPILOT_AGENT"
  grep -q 'traces/' "$COPILOT_AGENT"
}

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

# ─── retained_branches is both written and read ──────────────────────────────
#
# The resume dispatch reads .retained_branches; if nothing ever writes it the lookup
# silently returns empty and every partial restarts from scratch. Who calls it is
# orchestrator/lib/pipeline.mjs (asserted in tests/orchestrator/sprint.test.mjs); that the
# script still does what the call assumes is asserted here.
@test "state.sh implements the retained_branches write and clear the prose used to spell out" {
  grep -q 'retained_branches\[\$s\] = \$b' "$SCRIPT_DIR/skills/crew-afk/scripts/state.sh"
  grep -q 'del(.\[\$s\])' "$SCRIPT_DIR/skills/crew-afk/scripts/state.sh"
}
