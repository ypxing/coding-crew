#!/usr/bin/env bats

# Tests for crew-afk coverage validation step

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SKILL_FILE="$SCRIPT_DIR/skills/crew-afk/SKILL.md"
COVERAGE_SCRIPT="$SCRIPT_DIR/skills/crew-afk/scripts/coverage-validation.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git commit --allow-empty -m "initial"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# --- SKILL.md Structure Tests ---

@test "SKILL.md includes Coverage validation section" {
  grep -q '### Coverage validation' "$SKILL_FILE"
}

@test "Coverage validation section appears between Code review and Branch cleanup" {
  # Extract line numbers for each section
  code_review_line=$(grep -n "### Code review" "$SKILL_FILE" | head -1 | cut -d: -f1)
  coverage_line=$(grep -n "### Coverage validation" "$SKILL_FILE" | head -1 | cut -d: -f1)
  cleanup_line=$(grep -n "### Branch cleanup" "$SKILL_FILE" | head -1 | cut -d: -f1)

  # Verify order
  [ "$code_review_line" -lt "$coverage_line" ]
  [ "$coverage_line" -lt "$cleanup_line" ]
}

# --- Script Existence Tests ---

@test "coverage-validation.sh script exists" {
  [ -f "$COVERAGE_SCRIPT" ]
}

@test "coverage-validation.sh is executable" {
  [ -x "$COVERAGE_SCRIPT" ]
}

# --- Feature Slug Extraction Tests ---

@test "coverage-validation.sh extracts feature slug from simple branch" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature
  echo "# Design" > .scratch/test-feature/design.md
  
  run bash "$COVERAGE_SCRIPT"
  
  [ "$status" -eq 0 ]
  # Should NOT skip - design.md should be found
  [[ "$output" != *"skipped"* ]]
}

# --- Skip Behavior Tests ---

@test "coverage-validation.sh skips when neither design.md nor PRD.md exists" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature/issues
  
  run bash "$COVERAGE_SCRIPT"
  
  [ "$status" -eq 0 ]
  [[ "$output" == *"Coverage validation: skipped"* ]]
}

# --- Documentation Format Tests ---

@test "SKILL.md specifies coverage report format" {
  grep -q '✓ N covered' "$SKILL_FILE"
  grep -q '⚠ N partial' "$SKILL_FILE"
  grep -q '✗ N missing' "$SKILL_FILE"
}

@test "SKILL.md mentions validation agent prompt structure" {
  grep -qi 'validation agent' "$SKILL_FILE"
  grep -qi 'extract.*requirements' "$SKILL_FILE"
}
