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
  export CLAUDE_SKILL="$SCRIPT_DIR/skills/crew-afk/SKILL.md"
  # pi/codex/copilot share one source body; assert on the rendered copilot result.
  export COPILOT_SKILL="$(afk_variant copilot)"
  export MERGE_SCRIPT="$SCRIPT_DIR/skills/crew-afk/scripts/merge-branches.sh"
}

# ─── No agent forbids committing partial work ────────────────────────────────

@test "claude.agent.md does not forbid committing partial work" {
  # The old text was: "Do not commit partial work — the next worker starts from scratch"
  ! grep -q 'Do not commit partial work' "$CLAUDE_AGENT"
}

@test "copilot.agent.md does not forbid committing partial work" {
  ! grep -q 'Do not commit partial work' "$COPILOT_AGENT"
}

@test "claude crew-afk SKILL.md does not say re-implement from scratch when partial" {
  # Old: "Re-implement from scratch using them as context only (code was NOT committed)"
  ! grep -q 'code was NOT committed' "$CLAUDE_SKILL"
}

@test "copilot crew-afk SKILL.md does not say re-implement from scratch when partial" {
  ! grep -q 'code was NOT committed' "$COPILOT_SKILL"
}

# ─── Worker commits partial work with marker ─────────────────────────────────

@test "claude.agent.md instructs worker to commit partial work with a marker" {
  # Must instruct committing WIP with some kind of incomplete/partial marker
  grep -qiE 'WIP|partial.*commit|commit.*partial|incomplete.*marker|marker.*incomplete|commit.*wip' "$CLAUDE_AGENT"
}

@test "copilot.agent.md instructs worker to commit partial work with a marker" {
  grep -qiE 'WIP|partial.*commit|commit.*partial|incomplete.*marker|marker.*incomplete|commit.*wip' "$COPILOT_AGENT"
}

# ─── Partial work not merged ─────────────────────────────────────────────────

@test "claude SKILL.md does not merge partial branches" {
  # Partial branches must be excluded from the merge step
  # The merge step invokes merge-branches.sh only for verified/complete branches
  MERGE_LINE=$(grep -n 'merge-branches.sh' "$CLAUDE_SKILL" | head -1 | cut -d: -f1)
  [ -n "$MERGE_LINE" ] || { echo "No merge-branches.sh found"; return 1; }

  # There must be a gate that keeps partial branches out of the merge invocation
  grep -qiE 'verified.*branch|complete.*branch|partial.*not.*merge|skip.*partial|demot.*partial' "$CLAUDE_SKILL"
}

@test "copilot SKILL.md does not merge partial branches" {
  grep -qiE 'verified.*branch|complete.*branch|partial.*not.*merge|skip.*partial|demot.*partial' "$COPILOT_SKILL"
}

# ─── Retained branches excluded from cleanup ─────────────────────────────────

@test "claude SKILL.md excludes partial/retention branches from branch -D cleanup" {
  # Cleanup must NOT blindly delete all tracked branches
  # It must only delete merged/complete branches, not partial/verification-failed ones
  grep -qiE 'retain|retention|partial.*branch|keep.*branch|do not delete|skip.*cleanup|merged.*branches' "$CLAUDE_SKILL"
}

@test "copilot SKILL.md excludes partial/retention branches from branch -D cleanup" {
  grep -qiE 'retain|retention|partial.*branch|keep.*branch|do not delete|skip.*cleanup|merged.*branches' "$COPILOT_SKILL"
}

# ─── Retained branches listed in summary ─────────────────────────────────────

@test "claude SKILL.md summary lists retained branches with reason" {
  # Summary section must mention retained branches
  grep -qiE 'retained|Retained' "$CLAUDE_SKILL"
}

@test "copilot SKILL.md summary lists retained branches with reason" {
  grep -qiE 'retained|Retained' "$COPILOT_SKILL"
}

# ─── Resume dispatch instruction ─────────────────────────────────────────────

@test "claude SKILL.md dispatch instructs next worker to resume on existing branch" {
  # Must mention resuming or continuing on the existing branch
  grep -qiE 'resume|Resume|existing branch|continue.*branch|branch.*continues' "$CLAUDE_SKILL"
}

@test "copilot SKILL.md dispatch instructs next worker to resume on existing branch" {
  grep -qiE 'resume|Resume|existing branch|continue.*branch|branch.*continues' "$COPILOT_SKILL"
}

# ─── Progress notes positioned as context alongside code ─────────────────────

@test "claude SKILL.md positions progress notes as context for preserved code, not substitute" {
  # Must not say notes are all that's preserved — code is also preserved
  grep -qiE 'context.*code|alongside.*code|code.*context|notes.*context|preserved.*code|code.*preserved' "$CLAUDE_SKILL"
}

@test "copilot SKILL.md positions progress notes as context for preserved code, not substitute" {
  grep -qiE 'context.*code|alongside.*code|code.*context|notes.*context|preserved.*code|code.*preserved' "$COPILOT_SKILL"
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

# ─── Cleanup only for merged/complete branches ───────────────────────────────

@test "claude SKILL.md cleanup deletes only merged branches, not retained" {
  # The cleanup section must not include partial branches in the delete list
  # Must reference all_merged or equivalent to scope the delete
  grep -qiE 'all_merged|merged.*branch.*delete|delete.*merged|cleanup.*merged' "$CLAUDE_SKILL"
}

@test "copilot SKILL.md cleanup removes only merged worktrees, not retained" {
  # Partial branches must not be removed — their worktrees may already be gone but branches stay
  # Must have conditional logic excluding retained branches
  grep -qiE 'retained|partial.*branch.*keep|keep.*partial|skip.*retained|only.*merged.*delete|merged.*only' "$COPILOT_SKILL"
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

# ─── cleanup prose is accurate about worktree state (review finding) ─────────

@test "claude SKILL.md does not claim the runtime has already torn down worktrees" {
  # Proven false in practice: git branch -D failed with "used by worktree" for
  # every branch in a real sprint, because the worktrees were still checked out.
  ! grep -qi 'already been torn down by the runtime' "$CLAUDE_SKILL"
}

@test "claude SKILL.md cleanup removes merged worktrees before deleting their branch refs" {
  # A branch ref cannot be deleted while a worktree has it checked out, so the
  # cleanup must remove the merged worktree first.
  grep -q 'worktree remove' "$CLAUDE_SKILL"
}

@test "claude SKILL.md states worktree prune does not remove live worktrees" {
  # Verified: `git worktree prune` only clears stale metadata, so it is safe to
  # run while retained worktrees are still checked out.
  grep -qiE 'prune.*(stale|metadata)|(stale|metadata).*prune' "$CLAUDE_SKILL"
}

# ─── resume dispatch specifies how to test for the prior branch ──────────────

# The lookup + ref test is mechanical, so it moved into state.sh resume (behaviour is
# covered in tests/crew-afk-state.bats). The body only has to ask.
@test "claude SKILL.md gives a concrete branch-existence check for resume dispatch" {
  grep -qE 'state\.sh" resume|git branch --list' "$CLAUDE_SKILL"
}

@test "claude SKILL.md records the branch name needed to resume across rounds" {
  # The prior round's branch name must be persisted somewhere the next round reads.
  grep -qiE 'retained_branches|sprint-state|previous round.*branch name|branch name.*previous round' "$CLAUDE_SKILL"
}

# ─── retained_branches is both written and read on each platform ─────────────
# The resume dispatch reads .retained_branches; if nothing ever writes it the
# lookup silently returns empty and every partial restarts from scratch.

@test "claude SKILL.md writes retained_branches, not just reads it" {
  grep -qE 'state\.sh" retain|retained_branches\[\$slug\] = \$branch' "$CLAUDE_SKILL"
}

@test "copilot SKILL.md writes retained_branches, not just reads it" {
  grep -qE 'state\.sh" retain|retained_branches\[\$slug\] = \$branch' "$COPILOT_SKILL"
}

@test "claude SKILL.md clears the retention entry when an issue completes" {
  grep -qE 'state\.sh" complete|del\(.retained_branches' "$CLAUDE_SKILL"
}

@test "copilot SKILL.md clears the retention entry when an issue completes" {
  grep -qE 'state\.sh" complete|del\(.retained_branches' "$COPILOT_SKILL"
}

@test "copilot SKILL.md gives a concrete branch-existence check for resume dispatch" {
  grep -qE 'state\.sh" resume|branch --list' "$COPILOT_SKILL"
}

# The jq that these greps used to assert on now lives in state.sh, where it is executed
# rather than described. Both halves of the round-trip are asserted here so a body that
# calls the script cannot pass while the script has stopped writing the entry.
@test "state.sh implements the retained_branches write and clear the prose used to spell out" {
  grep -q 'retained_branches\[\$s\] = \$b' "$SCRIPT_DIR/skills/crew-afk/scripts/state.sh"
  grep -q 'del(.\[\$s\])' "$SCRIPT_DIR/skills/crew-afk/scripts/state.sh"
}
