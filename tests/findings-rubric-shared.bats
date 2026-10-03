#!/usr/bin/env bats

# One rubric for classifying a review finding — Actionable / Debatable / Dismiss, and the two hard
# rules that force Debatable — rendered into both /crew-address-findings (a human's run) and
# crew-triage's findings mode (the unattended one). It lives once, in
# skills/_shared/fragments/common/findings-rubric.md; these tests read the *rendered* output of
# each, so the two can never describe different rubrics.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
RUBRIC="$REPO_ROOT/skills/_shared/fragments/common/findings-rubric.md"

triage_variant() {
  role_prompt triage "$1"
}

# The rubric's lines, each of which must appear verbatim in a rendered body.
assert_rubric_in() {
  local file="$1" line
  [ -f "$file" ] || { echo "missing: $file" >&2; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qF -- "$line" "$file" || { echo "$file lacks rubric line: $line" >&2; return 1; }
  done < "$RUBRIC"
}

@test "the rubric names the three verdicts and the two hard rules" {
  for word in '**Actionable**' '**Debatable**' '**Dismiss**' 'ADR' 'CONTEXT.md' 'protected path' '.github/workflows/' '.env'; do
    grep -qF -- "$word" "$RUBRIC" || { echo "rubric lacks $word" >&2; return 1; }
  done
  grep -q 'local, unambiguous, and changes no public contract' "$RUBRIC"
}

@test "/crew-address-findings renders the rubric, for every platform" {
  for p in claude copilot pi codex; do
    run rendered_skill crew-address-findings "$p"
    [ "$status" -eq 0 ]
    assert_rubric_in "$output"
    ! grep -q '{{FRAGMENT' "$output"
  done
}

@test "crew-triage renders the same rubric, for every platform" {
  for p in claude copilot pi codex; do
    assert_rubric_in "$(triage_variant "$p")"
    ! grep -q '{{FRAGMENT' "$(triage_variant "$p")"
  done
}

@test "the rubric is not restated by hand in either body's source" {
  # A copy in a source file is a second rubric that can drift from the fragment.
  for f in "$REPO_ROOT/skills/crew-address-findings/SKILL.md" "$REPO_ROOT/orchestrator/roles/triage.md"; do
    grep -q '{{FRAGMENT:findings-rubric}}' "$f"
    ! grep -qF 'changes no public contract' "$f"
  done
}

@test "/crew-address-findings leads with Debatable and collapses Dismissed" {
  run rendered_skill crew-address-findings claude
  grep -q 'Lead with Debatable' "$output"
  grep -q 'collapse the Dismissed ones' "$output"
  grep -q '`verdict`' "$output"
}

@test "crew-triage has a findings mode that writes one verdict per finding" {
  f="$(triage_variant claude)"
  grep -q '^## Findings Mode' "$f"
  grep -q '"verdict": "actionable"' "$f"
  grep -q 'falls back to promoting by severity' "$f"
}
