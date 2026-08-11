#!/usr/bin/env bats

# Tests for crew-afk coverage validation step

load helpers/render

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

@test "Coverage validation section appears between squash and Branch cleanup" {
  # Code review now runs per-branch before merge (Step 4), not in Wrap Up.
  # Coverage validation is in Wrap Up, between squash and branch cleanup.
  squash_line=$(grep -n "squash-commits.sh\|Squash Commit" "$SKILL_FILE" | head -1 | cut -d: -f1)
  coverage_line=$(grep -n "### Coverage validation" "$SKILL_FILE" | head -1 | cut -d: -f1)
  cleanup_line=$(grep -n "### Worktree and branch cleanup" "$SKILL_FILE" | head -1 | cut -d: -f1)

  # Verify order: squash -> coverage validation -> branch cleanup
  [ "$squash_line" -lt "$coverage_line" ]
  [ "$coverage_line" -lt "$cleanup_line" ]
}

# --- Script Existence Tests ---

@test "coverage-validation.sh script exists" {
  [ -f "$COVERAGE_SCRIPT" ]
}

@test "coverage-validation.sh is invoked via bash in SKILL.md" {
  # Per D2: scripts are called as 'bash "<skill-dir>/scripts/<name>.sh"' not executed directly
  grep -q 'bash.*coverage-validation\.sh' "$SKILL_FILE"
}

@test "coverage-validation.sh is invoked via bash in copilot.SKILL.md" {
  # Platform parity: Copilot must also use the script
  grep -q 'bash.*coverage-validation\.sh' "$(afk_variant copilot)"
}

# --- Skip Behavior Tests ---

@test "coverage-validation.sh skips when no PRD.md exists" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature/issues

  run bash "$COVERAGE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Coverage validation: skipped"* ]]
}

@test "coverage-validation.sh skip message includes reason" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature/issues

  run bash "$COVERAGE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"no PRD.md found"* ]]
}

@test "coverage-validation.sh outputs PRD path when PRD.md exists" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature
  echo "# PRD" > .scratch/test-feature/PRD.md

  run bash "$COVERAGE_SCRIPT"

  [ "$status" -eq 0 ]
  # Must NOT output a skip message
  [[ "$output" != *"skipped"* ]]
  # Must output the PRD path so the orchestrator knows what to read
  [[ "$output" == *"PRD.md"* ]]
}

# --- No Dead Stub Tests ---

@test "coverage-validation.sh does not contain 'not yet implemented'" {
  run grep -c "not yet implemented" "$COVERAGE_SCRIPT"
  [ "$output" -eq 0 ]
}

@test "No script file body only reports 'not yet implemented'" {
  # Scan all scripts in skills/crew-afk/scripts/ for stub bodies
  for f in "$SCRIPT_DIR/skills/crew-afk/scripts/"*.sh; do
    count=$(grep -c "not yet implemented" "$f" 2>/dev/null || echo 0)
    if [ "$count" -gt 0 ]; then
      echo "Dead stub found in: $f"
      return 1
    fi
  done
}

# --- Model Tier Tests ---

@test "Coverage validation does not use haiku model tier" {
  # The coverage validation agent must NOT be on a cheap tier
  # Extract the coverage validation section and check it doesn't say haiku
  coverage_start=$(grep -n "### Coverage validation" "$SKILL_FILE" | head -1 | cut -d: -f1)
  cleanup_start=$(grep -n "### Worktree and branch cleanup" "$SKILL_FILE" | head -1 | cut -d: -f1)

  if [ -z "$coverage_start" ] || [ -z "$cleanup_start" ]; then
    skip "Could not find section boundaries"
  fi

  # Extract lines between coverage validation and branch cleanup
  section=$(sed -n "${coverage_start},${cleanup_start}p" "$SKILL_FILE")
  echo "$section" | grep -q -i "haiku" && { echo "FAIL: haiku found in coverage validation section"; return 1; } || true
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

# --- Copilot Parity Tests ---

@test "copilot.SKILL.md includes Coverage validation section" {
  grep -q -i 'coverage' "$(afk_variant copilot)"
}
