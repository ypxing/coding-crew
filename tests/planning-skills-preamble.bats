#!/usr/bin/env bats

# Tests for preamble and tracker operation references in planning skills

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export TO_ISSUES="$SCRIPT_DIR/skills/to-issues/SKILL.md"
  export TO_PRD="$SCRIPT_DIR/skills/to-prd/SKILL.md"
}

# --- Tracker Configuration preamble ---

@test "to-issues/SKILL.md contains the Tracker Configuration section" {
  grep -q '^## Tracker Configuration' "$TO_ISSUES"
}

@test "to-prd/SKILL.md contains the Tracker Configuration section" {
  grep -q '^## Tracker Configuration' "$TO_PRD"
}

@test "to-issues/SKILL.md preamble references issue-tracker.md lookup chain" {
  grep -q 'issue-tracker.md' "$TO_ISSUES"
  grep -q 'git rev-parse --show-toplevel' "$TO_ISSUES"
}

@test "to-prd/SKILL.md preamble references issue-tracker.md lookup chain" {
  grep -q 'issue-tracker.md' "$TO_PRD"
  grep -q 'git rev-parse --show-toplevel' "$TO_PRD"
}

# --- No inline .scratch/ tracker operation logic ---

@test "to-issues/SKILL.md does not contain inline triage label table" {
  # The triage label table should now come from issue-tracker.md, not be inline
  ! grep -q '| `needs-triage`' "$TO_ISSUES"
}

@test "to-prd/SKILL.md does not contain inline Issue Tracker Conventions block with .scratch paths" {
  # Inline convention block should be replaced by preamble reference
  ! grep -q '^## Issue Tracker Conventions' "$TO_PRD"
}

@test "to-issues/SKILL.md does not contain inline Issue Tracker Conventions block" {
  ! grep -q '^## Issue Tracker Conventions' "$TO_ISSUES"
}

# --- Named operation references instead of inline logic ---

@test "to-issues/SKILL.md references the publish operation by name" {
  grep -qE 'publish.*operation|operation.*publish' "$TO_ISSUES"
}

@test "to-prd/SKILL.md references the publish operation by name" {
  grep -qE 'publish.*operation|operation.*publish' "$TO_PRD"
}

# --- Feature slug concept still managed by skill ---

@test "to-issues/SKILL.md still manages feature slug" {
  grep -q 'feature slug' "$TO_ISSUES" || grep -q 'feature-slug' "$TO_ISSUES"
}

@test "to-prd/SKILL.md still manages feature slug" {
  grep -q 'feature slug' "$TO_PRD" || grep -q 'feature-slug' "$TO_PRD"
}

@test "to-issues/SKILL.md still references .scratch workspace directory" {
  grep -q '\.scratch/' "$TO_ISSUES"
}

@test "to-prd/SKILL.md still references .scratch workspace directory" {
  grep -q '\.scratch/' "$TO_PRD"
}
