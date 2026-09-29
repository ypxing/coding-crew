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

@test "to-issues/SKILL.md names PRD.md as the context source" {
  # design.md was consolidated into PRD.md as the single context document.
  grep -q 'PRD\.md' "$SKILL_FILE"
  ! grep -q 'design\.md' "$SKILL_FILE"
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


@test "to-issues/SKILL.md template includes an optional Requires section, one command per bullet" {
  grep -q '^## Requires$' "$SKILL_FILE"
  grep -q 'exit 0 = satisfied' "$SKILL_FILE"
}

@test "to-issues runs each Requires command while authoring, and a failure makes the issue ready-for-human" {
  grep -q 'Run each one while authoring' "$SKILL_FILE"
  grep -qE 'fails, publish the issue as `Status: ready-for-human`' "$SKILL_FILE"
}

@test "to-issues: codebase exploration is required, not optional" {
  # Issues drafted from the PRD alone named functions that did not exist and bugs already fixed;
  # the coder's premise check (solve-issue §3) is the backstop, this is the prevention.
  ! grep -q '^### 3\. Explore the codebase (optional)' "$SKILL_FILE"
  grep -q '^### 3\. Explore the codebase$' "$SKILL_FILE"
}

@test "to-issues: every assumption about current code is grounded at file:line, new things say so" {
  section=$(awk '/^### 3\. Explore/{f=1;next} /^### /{f=0} f' "$SKILL_FILE")
  echo "$section" | grep -q 'Ground every assumption'
  echo "$section" | grep -qF 'confirm it at a `file:line`'
  echo "$section" | grep -q 'the code path that produces it'
  echo "$section" | grep -q 'its issue says so'
}

@test "to-issues: a contradicted assumption goes to the quiz, never silently into an issue" {
  section=$(awk '/^### 3\. Explore/{f=1;next} /^### /{f=0} f' "$SKILL_FILE")
  echo "$section" | grep -q 'never silently into an issue'
  echo "$section" | grep -q 'Already there'
  echo "$section" | grep -q 'test-only slice'
  echo "$section" | grep -q 'Wrong assumption'
  quiz=$(awk '/^### 5\. Quiz/{f=1;next} /^### /{f=0} f' "$SKILL_FILE")
  echo "$quiz" | grep -q 'If step 3 contradicted any assumption'
}
