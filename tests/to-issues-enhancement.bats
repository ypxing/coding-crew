#!/usr/bin/env bats

# Tests for the to-issues skill body: issue template, criteria rubric, cross-cutting rules.
# Asserted against the rendered skill, which is what a consuming repo receives.

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export SKILL_FILE="$(rendered_skill to-issues claude)"
}

# --- Template Sections ---

@test "to-issues/SKILL.md template includes Context Documents section" {
  grep -q '## Context Documents' "$SKILL_FILE"
}

@test "to-issues/SKILL.md template includes Cross-cutting Requirements section" {
  grep -q '## Cross-cutting Requirements' "$SKILL_FILE"
}

@test "to-issues template has Implements after What to build, and no Part of Flow" {
  grep -q '^## Implements$' "$SKILL_FILE"
  ! grep -q 'Part of Flow' "$SKILL_FILE"
  build=$(grep -n '^## What to build$' "$SKILL_FILE" | head -1 | cut -d: -f1)
  impl=$(grep -n '^## Implements$' "$SKILL_FILE" | head -1 | cut -d: -f1)
  ac=$(grep -n '^## Acceptance criteria$' "$SKILL_FILE" | head -1 | cut -d: -f1)
  [ "$build" -lt "$impl" ]
  [ "$impl" -lt "$ac" ]
  grep -qi 'PRD IDs' "$SKILL_FILE"
  grep -qi 'verified at' "$SKILL_FILE"
}

@test "to-issues: Interfaces is included for consumers and consumed issues; a consumed root has Exposes" {
  grep -qF 'consumes from or is consumed by another' "$SKILL_FILE"
  ! grep -qF "only include this section if \`## Blocked by\` is non-empty" "$SKILL_FILE"
  grep -q '^### Exposes:$' "$SKILL_FILE"
  grep -qiE 'root issue.*(Exposes)' "$SKILL_FILE"
}

@test "to-issues: Cross-cutting Requirements carries only a PRD rule the criteria do not cover; ten-category scan is gone" {
  grep -qF 'do not already cover' "$SKILL_FILE"
  ! grep -q 'Extract cross-cutting requirements' "$SKILL_FILE"
  ! grep -qE '\(10 total\)|10 categories' "$SKILL_FILE"
  ! grep -q 'Multi-Issue Flows' "$SKILL_FILE"
}

@test "to-issues: acceptance-criteria rubric" {
  grep -qF 'one observable behaviour or consumed contract' "$SKILL_FILE"
  grep -qF 'checkable from the diff plus the checks' "$SKILL_FILE"
  grep -qF 'never "tests pass"' "$SKILL_FILE"
  grep -qF 'names the mechanism that prevents it' "$SKILL_FILE"
  grep -qF 'stay in the PRD' "$SKILL_FILE"
  grep -qF 'is itself the requirement' "$SKILL_FILE"
}

@test "to-issues: a slice taking input or calling something external carries failure-behaviour criteria" {
  grep -qE 'takes input or calls something external' "$SKILL_FILE"
  grep -qF 'invalid input, missing dependency, failing call' "$SKILL_FILE"
}

@test "to-issues: file-path ban is gone; What to build may cite grounded paths and opens with a one-line summary" {
  ! grep -q 'Avoid specific file paths' "$SKILL_FILE"
  grep -qF 'grounded paths and signatures' "$SKILL_FILE"
  grep -qF 'first sentence is a one-line summary' "$SKILL_FILE"
  grep -qF 'squash-commits.sh:109' "$SKILL_FILE"
}

# --- Extraction Logic References ---

@test "to-issues/SKILL.md names PRD.md as the context source" {
  # design.md was consolidated into PRD.md as the single context document.
  grep -q 'PRD\.md' "$SKILL_FILE"
  ! grep -q 'design\.md' "$SKILL_FILE"
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
