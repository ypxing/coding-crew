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
    '`Light path:' 'invoke `to-issues`' 'Ask no question' 'print one line naming it' 'continue with the Q&A'; do
    grep -qF -- "$claim" "$LIGHT" || { echo "fragment lacks: $claim" >&2; return 1; }
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
  grep -qF 'existing `.scratch/<slug>/` directory' "$f"
  grep -qF '## Decisions' "$f"
  grep -qF 'the slug' "$f"
}
