#!/usr/bin/env bats

# The light-path judgement lives once, in skills/_shared/fragments/light-path.md, and renders into
# crew-grill and crew-brainstorm only. to-issues decides slicing and the PRD; the coder never
# judges the source. These tests read the *rendered* output.

load helpers/render
load helpers/platforms

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
LIGHT="$REPO_ROOT/skills/_shared/fragments/light-path.md"

assert_light_in() {
  local file="$1" line
  [ -f "$file" ] || { echo "missing: $file" >&2; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qF -- "$line" "$file" || { echo "$file lacks light-path line: $line" >&2; return 1; }
  done < "$LIGHT"
}

assert_light_absent_from() {
  local file="$1" line
  [ -f "$file" ] || { echo "missing: $file" >&2; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ! grep -qF -- "$line" "$file" || { echo "$file carries light-path line: $line" >&2; return 1; }
  done < "$LIGHT"
}

@test "crew-grill and crew-brainstorm render the light path, for every platform" {
  for skill in crew-grill crew-brainstorm; do
    for p in "${PLATFORMS[@]}"; do
      run rendered_skill "$skill" "$p"
      [ "$status" -eq 0 ]
      assert_light_in "$output"
      ! grep -q '{{' "$output" || { echo "$skill/$p has a leftover placeholder" >&2; return 1; }
    done
  done
}

@test "to-issues and the coder role never carry the light path, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    assert_light_absent_from "$output"
  done
  for p in "${CODER_VARIANTS[@]}"; do
    assert_light_absent_from "$(role_prompt coder "$p")"
  done
}

@test "each skill's source includes the light path by its whole-line fragment" {
  for skill in crew-grill crew-brainstorm; do
    grep -q '^{{FRAGMENT:light-path}}$' "$REPO_ROOT/skills/$skill/SKILL.md"
  done
}

@test "the fragment states the four checks, the evidence rule, and both outcomes" {
  for claim in 'Problem' 'One slice' 'Criteria' 'No fork' '"annoyed" lane' 'a quote from the source or a `file:line`' \
    '`Light path:' 'invoke `to-issues`' 'Ask no question' 'Print nothing about it' 'continue with the Q&A'; do
    grep -qF -- "$claim" "$LIGHT" || { echo "fragment lacks: $claim" >&2; return 1; }
  done
}

@test "crew-grill and crew-brainstorm print nothing when a light-path check fails, for every platform" {
  for skill in crew-grill crew-brainstorm; do
    for p in "${PLATFORMS[@]}"; do
      run rendered_skill "$skill" "$p"
      [ "$status" -eq 0 ]
      ! grep -qF 'print one line naming it' "$output" || { echo "$skill/$p still prints a line on failure" >&2; return 1; }
      grep -qF 'Print nothing about it' "$output"
      grep -qF 'Light path: <reason per check>' "$output"
    done
  done
}

@test "crew-grill and crew-brainstorm hand off to to-issues only, and never instruct to-prd" {
  for p in "${PLATFORMS[@]}"; do
    for skill in crew-grill crew-brainstorm; do
      run rendered_skill "$skill" "$p"
      [ "$status" -eq 0 ]
      grep -qF 'to-issues' "$output"
      # the verification-pass fragment names to-prd descriptively; only an instruction to run it is out
      ! grep -iE '(invoke|run|transition to)[^.]*`to-prd`' "$output" || { echo "$skill/$p instructs to-prd" >&2; return 1; }
      ! grep -qF 'Ready to write the PRD' "$output"
    done
  done
}

@test "rendered crew-brainstorm has no feature-slug capture step" {
  run rendered_skill crew-brainstorm claude
  [ "$status" -eq 0 ]
  ! grep -qi 'capture feature slug' "$output"
  ! grep -qi 'capture the feature slug' "$output"
}

@test "rendered to-issues no longer asks about /to-prd, and states the one-slice rules" {
  local f
  f="$(rendered_skill to-issues claude)"
  ! grep -qF 'Would you like me to run `/to-prd`' "$f"
  grep -qF 'One slice publishes without a PRD' "$f"
  grep -qF 'two or more origin issues' "$f"
  grep -qF "existing milestone" "$f"
  grep -qF "a local issue ref's feature" "$f"
  grep -qF '## Decisions' "$f"
  grep -qF 'the slug' "$f"
}

@test "every term the light-path fragment cites is defined in each rendered skill" {
  ! grep -qF 'Gate 2' "$LIGHT" || { echo "fragment cites Gate 2, which crew-brainstorm lacks" >&2; return 1; }
  for skill in crew-grill crew-brainstorm; do
    run rendered_skill "$skill" claude
    [ "$status" -eq 0 ]
    # the annoyed lane is stated in the fragment itself, so it is defined wherever the fragment renders
    grep -qF 'annoyed to learn you made without asking' "$output"
    grep -qF 'conflicting in-repo precedent' "$output"
  done
}

@test "rendered crew-brainstorm allows the light path in its HARD-GATE, anti-pattern section and flow, and never demands a design for every project" {
  run rendered_skill crew-brainstorm claude
  [ "$status" -eq 0 ]
  local hard anti flow
  hard="$(sed -n '/<HARD-GATE>/,/<\/HARD-GATE>/p' "$output")"
  anti="$(sed -n '/^## Anti-Pattern/,/^## Checklist/p' "$output")"
  flow="$(sed -n '/^```dot/,/^```$/p' "$output")"
  grep -qF 'light-path' <<<"$hard"
  grep -qF 'light-path' <<<"$anti"
  grep -qF 'Light path' <<<"$flow"
  ! grep -qF 'EVERY project' "$output"
  ! grep -qF 'Every project goes through this process.' "$output"
}

@test "registry descriptions of crew-grill and crew-brainstorm name to-issues and no unconditional PRD" {
  for skill in crew-grill crew-brainstorm; do
    d="$(jq -r --arg s "$skill" '.skills[$s].description' "$REPO_ROOT/registry.json")"
    grep -qF 'to-issues' <<<"$d"
    ! grep -qi 'PRD' <<<"$d"
  done
}
