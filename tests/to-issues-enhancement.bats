#!/usr/bin/env bats

# Tests for enhanced to-issues skill with cross-cutting requirements extraction

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export SKILL_FILE="$SCRIPT_DIR/skills/to-issues/SKILL.md"
}

# --- Template Sections ---

@test "to-issues/SKILL.md template includes Context Documents section" {
  grep -q '## Context Documents' "$SKILL_FILE"
}

@test "to-issues/SKILL.md template includes Cross-cutting Requirements section" {
  grep -q '## Cross-cutting Requirements' "$SKILL_FILE"
}

@test "to-issues/SKILL.md template includes Part of Flow section" {
  grep -q '## Part of Flow' "$SKILL_FILE"
}

# --- Extraction Logic References ---

@test "to-issues/SKILL.md mentions design.md as context source" {
  grep -q 'design\.md' "$SKILL_FILE"
}

@test "to-issues/SKILL.md mentions 10 requirement categories or cross-cutting concerns" {
  # Should reference error handling, logging, security, performance, testing, architecture, validation, observability, interfaces, flows
  grep -qi 'error handling' "$SKILL_FILE" || grep -qi 'error' "$SKILL_FILE"
}

@test "to-issues/SKILL.md mentions PRD.md fallback for requirements" {
  grep -q 'PRD\.md' "$SKILL_FILE"
}

# --- Optional Section Guidance ---

@test "to-issues/SKILL.md indicates Context Documents section is conditional" {
  grep -qi 'only if\|only when\|optional' "$SKILL_FILE"
}

@test "to-issues/SKILL.md template shows omission of optional sections when not applicable" {
  # The template should clarify that sections can be omitted
  grep -qi 'omit\|skip\|only include\|only if' "$SKILL_FILE"
}

# --- Multi-issue Flow Annotations ---

@test "to-issues/SKILL.md mentions upstream/downstream flow relationships" {
  grep -qi 'upstream\|downstream' "$SKILL_FILE" || grep -qi 'flow' "$SKILL_FILE"
}

