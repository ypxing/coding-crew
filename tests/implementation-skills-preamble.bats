#!/usr/bin/env bats

# Tests for preamble and tracker operation references in implementation skills

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export SOLVE_ISSUE="$SCRIPT_DIR/skills/solve-issue/SKILL.md"
  export CREW_AFk="$SCRIPT_DIR/skills/crew-afk/SKILL.md"
  export ADDRESS_REVIEW="$SCRIPT_DIR/skills/address-code-review/SKILL.md"
}

# --- Tracker Configuration preamble ---

@test "solve-issue/SKILL.md contains the Tracker Configuration section" {
  grep -q '^## Tracker Configuration' "$SOLVE_ISSUE"
}

@test "crew-afk/SKILL.md contains the Tracker Configuration section" {
  grep -q '^## Tracker Configuration' "$CREW_AFk"
}

@test "address-code-review/SKILL.md contains the Tracker Configuration section" {
  grep -q '^## Tracker Configuration' "$ADDRESS_REVIEW"
}

@test "solve-issue/SKILL.md preamble references issue-tracker.md lookup chain" {
  grep -q 'issue-tracker.md' "$SOLVE_ISSUE"
  grep -q 'git rev-parse --show-toplevel' "$SOLVE_ISSUE"
}

@test "crew-afk/SKILL.md preamble references issue-tracker.md lookup chain" {
  grep -q 'issue-tracker.md' "$CREW_AFk"
  grep -q 'git rev-parse --show-toplevel' "$CREW_AFk"
}

@test "address-code-review/SKILL.md preamble references issue-tracker.md lookup chain" {
  grep -q 'issue-tracker.md' "$ADDRESS_REVIEW"
  grep -q 'git rev-parse --show-toplevel' "$ADDRESS_REVIEW"
}

# --- crew-afk no longer has hardcoded tracker logic ---

@test "crew-afk/SKILL.md does not contain 'Issue tracker: local only' string" {
  ! grep -q 'Issue tracker: local only' "$CREW_AFk"
}

@test "crew-afk/SKILL.md does not contain hardcoded .scratch/*/issues/*.md glob in tracker operation logic" {
  # The glob pattern used for listing issues must not appear in tracker operation logic
  # The crew-afk skill references this pattern only in the issue tracker conventions doc reference,
  # not as a hard-coded list command
  ! grep -q 'grep -rl.*\.scratch/\*/issues/\*\.md' "$CREW_AFk"
}

@test "crew-afk/SKILL.md references the list operation from issue-tracker.md" {
  grep -qE 'list.*operation|operation.*list|Execute.*list' "$CREW_AFk"
}

# --- Core workflows still intact ---

@test "solve-issue/SKILL.md still contains core step structure" {
  grep -q '### 0. Feature Branch Setup' "$SOLVE_ISSUE" || grep -q '### 1. Understand the issue' "$SOLVE_ISSUE"
}

@test "crew-afk/SKILL.md still contains the sprint loop" {
  grep -q '### Step 1' "$CREW_AFk" || grep -q '## Loop' "$CREW_AFk"
}

@test "address-code-review/SKILL.md still contains triage steps" {
  grep -q 'Challenge' "$ADDRESS_REVIEW" || grep -q 'Step 3' "$ADDRESS_REVIEW"
}
