#!/usr/bin/env bats

# Tests for crew-address-findings review path handling (feature-scoped)

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export ADDRESS_REVIEW="$SCRIPT_DIR/skills/crew-address-findings/SKILL.md"
}

# --- Auto-detect: scans feature-scoped review paths ---

@test "auto-detect scans feature-scoped reviews path (not flat .scratch/reviews/)" {
  # Must reference the feature-scoped pattern .scratch/*/reviews/ or equivalent find command
  grep -qE '\.scratch.*reviews|reviews.*\.md.*find|find.*reviews' "$ADDRESS_REVIEW"
  # Must NOT use the old flat .scratch/reviews/*.md pattern
  ! grep -qE "ls.*\.scratch/reviews/\*\.md|\.scratch/reviews/\*\.md" "$ADDRESS_REVIEW"
}

@test "auto-detect excludes done/ subdirectory" {
  # The scan must exclude done/ subdirs
  grep -qE 'done|not.*done|exclude.*done|prune.*done|-path.*done|grep.*done' "$ADDRESS_REVIEW"
}

@test "auto-detect prompts user when multiple reviews found" {
  # Must mention prompting or asking user when multiple reviews found
  grep -qiE 'Which one|prompt|ask|multiple' "$ADDRESS_REVIEW"
}

@test "auto-detect silently selects single result without prompting" {
  # Must mention auto-select or silent selection when only one found
  grep -qiE 'only one|auto.select|single.*found|found.*single|silently' "$ADDRESS_REVIEW"
}

@test "auto-detect groups results by feature slug" {
  # Must show results grouped by feature (e.g. listing feature — filename)
  grep -qE 'feature|slug|—|auth-flow' "$ADDRESS_REVIEW"
}

# --- Move on completion: feature-scoped reviews/done/ ---

@test "archive step uses dirname-based done path (not hardcoded .scratch/reviews/done)" {
  # Must NOT reference flat .scratch/reviews/done path
  ! grep -qE '\.scratch/reviews/done' "$ADDRESS_REVIEW"
}

@test "archive step uses mkdir -p with dirname to create feature-scoped done dir" {
  # Must use $(dirname <path>)/done pattern
  grep -qE 'dirname.*report|dirname.*path|dirname.*REPORT|dirname.*FILE' "$ADDRESS_REVIEW"
}

@test "archive step moves report to its own feature reviews/done/ directory" {
  # Must reference moving to $(dirname <var>)/done/
  grep -qE '\$\(dirname.*\)/done' "$ADDRESS_REVIEW"
}
