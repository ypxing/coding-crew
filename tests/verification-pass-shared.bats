#!/usr/bin/env bats

# One verification pass — re-run the source behind every cited fact, check each decision for
# correctness and the set for coherence — rendered into every skill that summarizes or publishes a
# design. It lives once, in skills/_shared/fragments/verification-pass.md; these tests read the
# *rendered* output, so crew-grill, crew-brainstorm and to-prd cannot drift into three passes.
# Implementation follows the issue, so the coder and solve-issue never carry it.

load helpers/render
load helpers/platforms

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
PASS="$REPO_ROOT/skills/_shared/fragments/verification-pass.md"

# The fragment's lines, each of which must appear verbatim in a rendered body.
assert_pass_in() {
  local file="$1" line
  [ -f "$file" ] || { echo "missing: $file" >&2; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qF -- "$line" "$file" || { echo "$file lacks pass line: $line" >&2; return 1; }
  done < "$PASS"
}

# No line of the fragment appears in a rendered body.
assert_pass_absent_from() {
  local file="$1" line
  [ -f "$file" ] || { echo "missing: $file" >&2; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ! grep -qF -- "$line" "$file" || { echo "$file carries pass line: $line" >&2; return 1; }
  done < "$PASS"
}

# The line number of the fragment's first line in a rendered body.
pass_line() { grep -nF -- "$(head -1 "$PASS")" "$1" | head -1 | cut -d: -f1; }

@test "crew-grill, crew-brainstorm and to-prd render the pass, for every platform" {
  for skill in crew-grill crew-brainstorm to-prd; do
    for p in "${PLATFORMS[@]}"; do
      run rendered_skill "$skill" "$p"
      [ "$status" -eq 0 ]
      assert_pass_in "$output"
      ! grep -q '{{' "$output" || { echo "$skill/$p has a leftover placeholder" >&2; return 1; }
    done
  done
}

@test "to-issues renders with no leftover placeholder, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    ! grep -q '{{' "$output"
  done
}

@test "each skill's source includes the pass by its whole-line fragment" {
  for skill in crew-grill crew-brainstorm to-prd; do
    grep -q '^{{FRAGMENT:verification-pass}}$' "$REPO_ROOT/skills/$skill/SKILL.md"
  done
}

@test "the coder role and solve-issue never carry the pass, for every platform" {
  for p in "${CODER_VARIANTS[@]}"; do
    assert_pass_absent_from "$(role_prompt coder "$p")"
    run rendered_skill solve-issue "$p"
    [ "$status" -eq 0 ]
    assert_pass_absent_from "$output"
  done
}

@test "crew-grill runs the pass after the subtraction pass and before the Phase 1 summary list" {
  local f sub pass summ
  f="$(rendered_skill crew-grill claude)"
  sub=$(grep -n 'run a \*\*subtraction pass\*\*' "$f" | head -1 | cut -d: -f1)
  pass=$(pass_line "$f")
  summ=$(grep -n '^1\. Summarize all implementation decisions' "$f" | head -1 | cut -d: -f1)
  [ -n "$sub" ]
  [ -n "$pass" ]
  [ -n "$summ" ]
  [ "$sub" -lt "$pass" ]
  [ "$pass" -lt "$summ" ]
}

@test "crew-grill's facts item lists the facts the verification pass re-checked" {
  grep -E '^2\. List the \*\*facts you established\*\*' "$(rendered_skill crew-grill claude)" |
    grep -qF 'the verification pass re-checked'
}

@test "crew-brainstorm runs the pass after the subtraction pass and before final approval" {
  local f sub pass appr
  f="$(rendered_skill crew-brainstorm claude)"
  sub=$(grep -n 'run a \*\*subtraction pass\*\*' "$f" | head -1 | cut -d: -f1)
  pass=$(pass_line "$f")
  appr=$(grep -n 'final approval' "$f" | awk -F: -v p="$pass" '$1>p{print $1; exit}')
  [ -n "$sub" ]
  [ -n "$pass" ]
  [ -n "$appr" ]
  [ "$sub" -lt "$pass" ]
  [ "$pass" -lt "$appr" ]
}

@test "to-prd runs the pass before its publish step" {
  local f pass pub
  f="$(rendered_skill to-prd claude)"
  pass=$(pass_line "$f")
  pub=$(grep -n 'execute the `publish` operation' "$f" | head -1 | cut -d: -f1)
  [ -n "$pass" ]
  [ -n "$pub" ]
  [ "$pass" -lt "$pub" ]
}

@test "the pass re-runs the source behind each cited fact and reports corrections as said X → actually Y" {
  for claim in 'count' '`path:line`' 'list' '"nothing else reads/does X"' 're-run'; do
    grep -qF -- "$claim" "$PASS" || { echo "pass lacks: $claim" >&2; return 1; }
  done
  grep -qF '"said X → actually Y (source)"' "$PASS"
}

@test "the pass checks each decision against criterion 2 (Correct) and the set for coherence" {
  grep -qF 'criterion 2 (**Correct**)' "$PASS"
  for signal in 'contradict' 'no decision provides' '`(auto)` line' 'answer the user gave'; do
    grep -qF -- "$signal" "$PASS" || { echo "pass lacks coherence check: $signal" >&2; return 1; }
  done
  grep -qF 'built on a corrected fact before the summary' "$PASS"
}

@test "the pass leaves necessity to the subtraction pass, and to-prd re-checks only what it adds" {
  grep -i 'necess' "$PASS" | grep -qF 'subtraction pass'
  grep -qF 'only what it adds beyond an already-verified summary' "$PASS"
  grep -qF 'standalone' "$PASS"
  grep -qF 'everything it cites' "$PASS"
}
