#!/usr/bin/env bats

# The PRD template to-prd writes: section order, ID formats, conditional sections.

load helpers/render

setup() {
  BODY="$(rendered_skill to-prd claude)"
  TEMPLATE="$(sed -n '/<prd-template>/,/<\/prd-template>/p' "$BODY")"
}

@test "template sections appear in order and Key User Stories is gone" {
  local headings
  headings="$(printf '%s\n' "$TEMPLATE" | grep '^## ' | sed 's/^## //')"
  local expected="Problem Statement
Solution
Behaviours
Decisions
Trust Boundaries & Risks
Compatibility & Migration
Testing Decisions
Assumptions
Out of Scope
Further Notes"
  [ "$headings" = "$expected" ]
  ! grep -q 'Key User Stories' "$BODY"
}

@test "Problem Statement carries one actor line" {
  printf '%s\n' "$TEMPLATE" | sed -n '/^## Problem Statement/,/^## Solution/p' | grep -qi 'actor'
}

@test "Behaviours are 3-8 B<n> items with given/happens/seam, Decisions are D<n> items" {
  local b d
  b="$(printf '%s\n' "$TEMPLATE" | sed -n '/^## Behaviours/,/^## Decisions/p')"
  d="$(printf '%s\n' "$TEMPLATE" | sed -n '/^## Decisions/,/^## Trust Boundaries/p')"
  [[ "$b" == *'3–8'* ]]
  [[ "$b" == *'- **B<n>** — given'* ]]
  [[ "$b" == *'at <seam>'* ]]
  [[ "$d" == *'- **D<n>** — '* ]]
}

@test "Decisions guidance: deep modules, one owner, dependency direction, lean PRD" {
  local d
  d="$(printf '%s\n' "$TEMPLATE" | sed -n '/^## Decisions/,/^## Trust Boundaries/p')"
  [[ "$d" == *'deep module'* ]]
  [[ "$d" == *'one owner'* ]]
  [[ "$d" == *'dependency direction'* ]]
  [[ "$d" == *'lean'* ]]
  [[ "$d" == *'every coder and reviewer'* ]]
}

@test "Trust Boundaries & Risks is conditional and asks for failure behaviour" {
  local s
  s="$(printf '%s\n' "$TEMPLATE" | sed -n '/^## Trust Boundaries/,/^## Compatibility/p')"
  [[ "$s" == *'untrusted input'* ]]
  [[ "$s" == *'secrets'* ]]
  [[ "$s" == *'auth'* ]]
  [[ "$s" == *'shell/exec'* ]]
  [[ "$s" == *'network'* ]]
  [[ "$s" == *'failure behaviour'* ]]
  [[ "$s" == *'only'* ]]
}

@test "Compatibility & Migration is conditional: breaks, migrates, expand–contract" {
  local s
  s="$(printf '%s\n' "$TEMPLATE" | sed -n '/^## Compatibility/,/^## Testing Decisions/p')"
  [[ "$s" == *'shipped contract'* ]]
  [[ "$s" == *'what breaks'* ]]
  [[ "$s" == *'what migrates'* ]]
  [[ "$s" == *'expand–contract'* ]]
  [[ "$s" == *'only'* ]]
}

@test "Assumptions is conditional on to-prd filling a gap itself, one line each" {
  local s
  s="$(printf '%s\n' "$TEMPLATE" | sed -n '/^## Assumptions/,/^## Out of Scope/p')"
  [[ "$s" == *'grilling session'* ]]
  [[ "$s" == *'one line per assumption'* ]]
  [[ "$s" == *'only'* ]]
}

@test "Compatibility & Migration names where existing data lives for a new reader or gate" {
  printf '%s\n' "$TEMPLATE" | grep -qF 'name where that data lives'
}

@test "Decisions describes the (no slice) marker for a decision no issue implements" {
  printf '%s\n' "$TEMPLATE" | sed -n '/^## Decisions/,/^## Trust Boundaries/p' | grep -q '(no slice)'
}

@test "Decisions guidance: every/always/only/never names the easy-to-miss cases, pre-seeded ones too" {
  local d
  d="$(printf '%s\n' "$TEMPLATE" | sed -n '/^## Decisions/,/^## Trust Boundaries/p')"
  [[ "$d" == *'"every", "always", "only" or "never"'* ]]
  [[ "$d" == *'signals'* ]]
  [[ "$d" == *'included or excluded'* ]]
  [[ "$d" == *'pre-seeded'* ]]
}
