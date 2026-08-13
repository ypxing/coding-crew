#!/usr/bin/env bats

# Tests for preamble and tracker operation references in implementation skills

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export SOLVE_ISSUE="$SCRIPT_DIR/skills/solve-issue/SKILL.md"
  export ADDRESS_REVIEW="$SCRIPT_DIR/skills/crew-address-findings/SKILL.md"
}

# crew-afk is absent from this file on purpose. Its claude body was the last one that read
# the tracker itself; the orchestrator program is the tracker implementation now (issue
# discovery, `Status:` parsing and `## Blocked by` resolution live in
# orchestrator/lib/tracker.mjs, covered by tests/orchestrator/tracker.test.mjs), so a
# launcher that re-stated the tracker operations would be describing work it does not do.

# --- Tracker Configuration preamble ---

@test "solve-issue/SKILL.md points at issue-tracker.md without a section of its own" {
  # The 6-line `## Tracker Configuration` section became one line under `## Inputs`.
  # A worker only needs to know where the operations are defined; the lookup "chain"
  # had exactly one link, and re-stating it as a section cost more than it explained.
  ! grep -q '^## Tracker Configuration' "$SOLVE_ISSUE"
  grep -q 'issue-tracker\.md' "$SOLVE_ISSUE"
  grep -q 'configure-tracker' "$SOLVE_ISSUE"
}

@test "crew-address-findings/SKILL.md contains the Tracker Configuration section" {
  grep -q '^## Tracker Configuration' "$ADDRESS_REVIEW"
}

@test "solve-issue/SKILL.md preamble references issue-tracker.md lookup chain" {
  grep -q 'issue-tracker.md' "$SOLVE_ISSUE"
  grep -q 'git rev-parse --show-toplevel' "$SOLVE_ISSUE"
}

@test "crew-address-findings/SKILL.md preamble references issue-tracker.md lookup chain" {
  grep -q 'issue-tracker.md' "$ADDRESS_REVIEW"
  grep -q 'git rev-parse --show-toplevel' "$ADDRESS_REVIEW"
}

# --- Core workflows still intact ---

@test "solve-issue/SKILL.md still contains core step structure" {
  grep -q '### 0. Branch guard' "$SOLVE_ISSUE" || grep -q '### 1. Understand the issue' "$SOLVE_ISSUE"
}

@test "crew-address-findings/SKILL.md still contains triage steps" {
  grep -q 'Challenge' "$ADDRESS_REVIEW" || grep -q 'Step 3' "$ADDRESS_REVIEW"
}
