#!/usr/bin/env bats

# Structural tests for 8 previously-uncovered skills

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

# --- crew-brainstorm ---

@test "crew-brainstorm SKILL.md exists" {
  [ -f "$SCRIPT_DIR/skills/crew-brainstorm/SKILL.md" ]
}

@test "crew-brainstorm SKILL.md references .scratch/ directory" {
  grep -q '\.scratch/' "$SCRIPT_DIR/skills/crew-brainstorm/SKILL.md"
}

@test "crew-brainstorm SKILL.md contains workflow steps" {
  grep -qi 'Step 1\|## Step' "$SCRIPT_DIR/skills/crew-brainstorm/SKILL.md"
}

# --- crew-grill ---

@test "crew-grill SKILL.md exists" {
  [ -f "$SCRIPT_DIR/skills/crew-grill/SKILL.md" ]
}

@test "crew-grill SKILL.md contains Phase 1 and Phase 2 headers" {
  grep -q '## Phase 1' "$SCRIPT_DIR/skills/crew-grill/SKILL.md"
  grep -q '## Phase 2' "$SCRIPT_DIR/skills/crew-grill/SKILL.md"
}

@test "crew-grill SKILL.md references design.md" {
  grep -q 'design\.md' "$SCRIPT_DIR/skills/crew-grill/SKILL.md"
}

# --- tdd ---

@test "tdd SKILL.md exists" {
  [ -f "$SCRIPT_DIR/skills/tdd/SKILL.md" ]
}

@test "tdd SKILL.md mentions red-green-refactor workflow" {
  grep -qi 'red' "$SCRIPT_DIR/skills/tdd/SKILL.md"
  grep -qi 'green' "$SCRIPT_DIR/skills/tdd/SKILL.md"
  grep -qi 'refactor' "$SCRIPT_DIR/skills/tdd/SKILL.md"
}

@test "tdd SKILL.md describes test-first approach" {
  grep -qi 'test' "$SCRIPT_DIR/skills/tdd/SKILL.md"
}

# --- dep-install ---

@test "dep-install SKILL.md exists" {
  [ -f "$SCRIPT_DIR/skills/dep-install/SKILL.md" ]
}

@test "dep-install SKILL.md references install mode detection" {
  grep -qi 'install mode\|detect.*mode\|mode.*detect' "$SCRIPT_DIR/skills/dep-install/SKILL.md"
}

@test "dep-install SKILL.md references host and docker modes" {
  grep -qi 'docker' "$SCRIPT_DIR/skills/dep-install/SKILL.md"
  grep -qi 'host' "$SCRIPT_DIR/skills/dep-install/SKILL.md"
}

# --- domain-modeling ---

@test "domain-modeling SKILL.md exists" {
  [ -f "$SCRIPT_DIR/skills/domain-modeling/SKILL.md" ]
}

@test "domain-modeling SKILL.md references CONTEXT.md" {
  grep -q 'CONTEXT\.md' "$SCRIPT_DIR/skills/domain-modeling/SKILL.md"
}

@test "domain-modeling SKILL.md references ADR" {
  grep -q 'ADR' "$SCRIPT_DIR/skills/domain-modeling/SKILL.md"
}

# --- caveman ---

@test "caveman SKILL.md exists" {
  [ -f "$SCRIPT_DIR/skills/caveman/SKILL.md" ]
}

@test "caveman SKILL.md references token reduction" {
  grep -qi 'token' "$SCRIPT_DIR/skills/caveman/SKILL.md"
}

@test "caveman SKILL.md describes compressed communication mode" {
  grep -qi 'compress\|token.*reduc\|reduc.*token\|75%\|caveman' "$SCRIPT_DIR/skills/caveman/SKILL.md"
}

# --- address-pr-comments ---

@test "address-pr-comments SKILL.md exists" {
  [ -f "$SCRIPT_DIR/skills/address-pr-comments/SKILL.md" ]
}

@test "address-pr-comments SKILL.md references TDD" {
  grep -q 'TDD' "$SCRIPT_DIR/skills/address-pr-comments/SKILL.md"
}

@test "address-pr-comments SKILL.md references PR review comments" {
  grep -qi 'PR\|pull request' "$SCRIPT_DIR/skills/address-pr-comments/SKILL.md"
}

# --- improve-codebase-architecture ---

@test "improve-codebase-architecture SKILL.md exists" {
  [ -f "$SCRIPT_DIR/skills/improve-codebase-architecture/SKILL.md" ]
}

@test "improve-codebase-architecture SKILL.md references CONTEXT.md" {
  grep -q 'CONTEXT\.md' "$SCRIPT_DIR/skills/improve-codebase-architecture/SKILL.md"
}

@test "improve-codebase-architecture SKILL.md describes refactoring or deepening opportunities" {
  grep -qi 'refactor\|deepen\|architecture' "$SCRIPT_DIR/skills/improve-codebase-architecture/SKILL.md"
}
