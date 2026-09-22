#!/usr/bin/env bats

# Tests for preamble and tracker operation references in planning skills

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export TO_ISSUES="$SCRIPT_DIR/skills/to-issues/SKILL.md"
  export TO_PRD="$SCRIPT_DIR/skills/to-prd/SKILL.md"
}

# --- Tracker Configuration preamble ---
#
# The preamble itself now lives in one shared fragment (skills/_shared/fragments/<platform>/
# tracker-configuration.md), referenced from the source SKILL.md via {{FRAGMENT:...}} rather
# than copy-pasted — see .scratch/github-issue-tracker/issues/open/
# 08-skill-prose-github-support.md. So these assertions run against the *rendered* body,
# which is what a consuming repo actually receives, same as tests/helpers/render.bash's own
# rationale for every other rendered-body assertion in this suite.

@test "to-issues/SKILL.md contains the Tracker Configuration section" {
  grep -q '^## Tracker Configuration' "$(rendered_skill to-issues claude)"
}

@test "to-prd/SKILL.md contains the Tracker Configuration section" {
  grep -q '^## Tracker Configuration' "$(rendered_skill to-prd claude)"
}

@test "to-issues/SKILL.md preamble references issue-tracker.md lookup chain" {
  local f="$(rendered_skill to-issues claude)"
  grep -q 'issue-tracker.md' "$f"
  grep -q 'git rev-parse --show-toplevel' "$f"
}

@test "to-prd/SKILL.md preamble references issue-tracker.md lookup chain" {
  local f="$(rendered_skill to-prd claude)"
  grep -q 'issue-tracker.md' "$f"
  grep -q 'git rev-parse --show-toplevel' "$f"
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
