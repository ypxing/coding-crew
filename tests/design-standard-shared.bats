#!/usr/bin/env bats

# One design standard — five criteria in priority order, each with its failure signals, and the
# guard against cutting needed structure — rendered into every skill that decides a design. It
# lives once, in skills/_shared/fragments/design-standard.md; these tests read the *rendered*
# output, so crew-grill and crew-brainstorm can never drift into two standards again (their
# hand-copied size paragraphs had). Implementation follows the issue, so the coder and
# solve-issue never carry it (PRD D11).

load helpers/render
load helpers/platforms

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
STANDARD="$REPO_ROOT/skills/_shared/fragments/design-standard.md"

# The fragment's lines, each of which must appear verbatim in a rendered body.
assert_standard_in() {
  local file="$1" line
  [ -f "$file" ] || { echo "missing: $file" >&2; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    grep -qF -- "$line" "$file" || { echo "$file lacks standard line: $line" >&2; return 1; }
  done < "$STANDARD"
}

# No line of the fragment appears in a rendered body.
assert_standard_absent_from() {
  local file="$1" line
  [ -f "$file" ] || { echo "missing: $file" >&2; return 1; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    ! grep -qF -- "$line" "$file" || { echo "$file carries standard line: $line" >&2; return 1; }
  done < "$STANDARD"
}

@test "the standard numbers its five criteria in priority order, with Correct as 2" {
  grep -qE '^1\. \*\*Necessary\*\*' "$STANDARD"
  grep -qE '^2\. \*\*Correct\*\*' "$STANDARD"
  grep -qE '^3\. \*\*Reusable along real axes\*\*' "$STANDARD"
  grep -qE '^4\. \*\*Fewest moving parts\*\*' "$STANDARD"
  grep -qE '^5\. \*\*Says what it does\*\*' "$STANDARD"
  grep -qF 'against five criteria' "$STANDARD"
  ! grep -qF 'four criteria' "$STANDARD"
  grep -qF 'necessary > correct > reusable along real axes > fewest moving parts > says what it does' "$STANDARD"
}

@test "criterion 2 says what Correct means and names its failure signals" {
  local c2; c2=$(grep -E '^2\. \*\*Correct\*\*' "$STANDARD")
  for part in 'does what it claims against the real code' 'rationale holds' 'rationale the code contradicts' \
    'cannot reach its target case' 'signal, retry, concurrent run, early return'; do
    grep -qF -- "$part" <<<"$c2" || { echo "criterion 2 lacks: $part" >&2; return 1; }
  done
}

@test "each criterion names the evidence that shows it failing" {
  for signal in 'no cited problem' 'coded in two or more places' 'branches on which implementation' \
    'one implementation and no named axis' 'unused parameter' 'per-caller flags' \
    'already known earlier' 'contradicts what it does'; do
    grep -qF -- "$signal" "$STANDARD" || { echo "standard lacks failure signal: $signal" >&2; return 1; }
  done
}

@test "the standard keeps the guard against cutting structure the design needs now" {
  grep -qF 'one owner per concern, no duplicated logic, a seam its tests need' "$STANDARD"
  grep -qi 'never cut' "$STANDARD"
}

@test "criterion 3 takes its axes from the project's CLAUDE.md or AGENTS.md and falls back to real callers now" {
  grep -qF "axes of variation the project's \`CLAUDE.md\` (or \`AGENTS.md\`) names" "$STANDARD"
  grep -qF 'two or more real callers or implementations now' "$STANDARD"
}

@test "the standard names no axis specific to this repo" {
  for axis in 'platform' 'tracker' 'crew-afk' 'dep-install' 'ecosystem' 'pane host' 'herdr' 'orca' \
    'copilot' 'codex' 'github'; do
    ! grep -qi -- "$axis" "$STANDARD" || { echo "standard names repo-specific axis: $axis" >&2; return 1; }
  done
}

@test "this repo's CLAUDE.md lists its axes of variation" {
  local section
  section=$(awk '/^## Axes of variation/{f=1;next} /^## /{f=0} f' "$REPO_ROOT/CLAUDE.md")
  [ -n "$section" ]
  for axis in 'platforms' 'trackers' 'crew-afk roles' 'dependency-install ecosystems' 'pane hosts'; do
    grep -qi -- "$axis" <<<"$section" || { echo "CLAUDE.md axes lack: $axis" >&2; return 1; }
  done
}

@test "crew-grill and crew-brainstorm render the standard, for every platform" {
  for skill in crew-grill crew-brainstorm; do
    for p in "${PLATFORMS[@]}"; do
      run rendered_skill "$skill" "$p"
      [ "$status" -eq 0 ]
      assert_standard_in "$output"
      ! grep -q '{{FRAGMENT' "$output"
    done
  done
}

@test "neither design skill's source keeps its own copy of the size paragraph" {
  for f in "$REPO_ROOT/skills/crew-grill/SKILL.md" "$REPO_ROOT/skills/crew-brainstorm/SKILL.md"; do
    grep -q '^{{FRAGMENT:design-standard}}$' "$f"
    ! grep -qF 'unjustified** size is not' "$f"
    ! grep -qF 'no duplicated logic' "$f"
    ! grep -qF 'gets one shared owner' "$f"
  done
}

@test "the coder role and solve-issue never carry the standard, for every platform" {
  for p in "${CODER_VARIANTS[@]}"; do
    assert_standard_absent_from "$(role_prompt coder "$p")"
    run rendered_skill solve-issue "$p"
    [ "$status" -eq 0 ]
    assert_standard_absent_from "$output"
  done
}

@test "the reviewer role renders the standard, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    assert_standard_in "$(role_prompt reviewer "$p")"
    ! grep -q '{{FRAGMENT' "$(role_prompt reviewer "$p")"
  done
  grep -q '^{{FRAGMENT:design-standard}}$' "$REPO_ROOT/orchestrator/roles/reviewer.md"
}

@test "the reviewer applies criteria 3-5, at LOW with file:line and a snippet, never as an unmet criterion" {
  local f; f="$(role_prompt reviewer claude)"
  grep -qF 'criteria 3–5' "$f"
  ! grep -qF 'criteria 2–4' "$f"
  grep -qF 'design-only finding' "$f"
  grep -qF 'at `LOW`, only with its exact `file:line` and a snippet' "$f"
  grep -qF 'never makes an acceptance criterion `unmet`' "$f"
}

@test "the reviewer reports a criterion-2 failure at its real severity, never with the design-only prefix" {
  local s; s=$(tr '\n' ' ' <"$(role_prompt reviewer claude)" | grep -oE 'A criterion-2 failure[^.]*\.[^.]*\.')
  grep -qF 'real severity' <<<"$s"
  grep -qF 'Steps 2–3' <<<"$s"
  grep -qF 'never with the `Design standard (criterion` prefix' <<<"$s"
}

@test "this repo's CLAUDE.md cites the reusability criterion as criterion 3" {
  grep -qF '(`skills/_shared/fragments/design-standard.md`, criterion 3) counts these as real axes' "$REPO_ROOT/CLAUDE.md"
}

@test "to-issues renders the standard, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    assert_standard_in "$output"
    ! grep -q '{{FRAGMENT' "$output"
  done
}

# Step 3's section of a rendered to-issues body: from its heading to step 4's.
to_issues_step() {
  awk -v n="$2" '$0 ~ "^### "n"\\. "{f=1;print;next} /^### [0-9]/{f=0} f' "$1"
}

@test "to-issues step 3 checks each slice against the standard beside its other two checks, for every platform" {
  local step3
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    step3=$(to_issues_step "$output" 3)
    grep -qF -- '- **Already there**' <<<"$step3"
    grep -qF -- '- **Wrong assumption**' <<<"$step3"
    grep -qF -- '- **Fails the design standard**' <<<"$step3"
    grep -qF 'Necessary' <<<"$step3"
  done
}

@test "to-issues step 5's quiz lists design-standard failures with file:line evidence, for every platform" {
  local step5
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    step5=$(to_issues_step "$output" 5)
    grep -E '^[0-9]+\. \*\*Design-standard failures\*\*' <<<"$step5" | grep -qF '`file:line`'
  done
}

@test "to-issues rewrites a single-slice source issue in place through the CLI's rewrite and keeps ## Parent for a split one, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    grep -qF 'node "$TRACKER" rewrite <ref> --body-file <file> --status <status> --feature-slug <feature-slug>' "$output"
    grep -qi 'rewrit.* in place' "$output"
    grep -qF 'several slices' "$output"
    grep -qF '## Parent' "$output"
  done
}

@test "to-issues' in-place rewrite sets the slice's status and files it under the feature, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    grep -qF "\`<status>\` is the slice's status" "$output"
    grep -qF '`rewrite` also files it under the feature' "$output"
    if grep -qF 'its body is the one edit made to it' "$output"; then false; fi
  done
}

@test "to-issues exempts auto-promoted fix issues by promote-findings.sh's column-0 Source: rule, both forms, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    line=$(grep -F 'not checked against the design standard' "$output")
    [[ "$line" == *'column-0 `Source:` line outside a code fence'* ]]
    [[ "$line" == *'`Source: review (<branch>)`'* ]]
    [[ "$line" == *'`Source: <report> (<branch>)`'* ]]
    grep -F 'Fails the design standard' "$output" | grep -qF 'An auto-promoted issue (a column-0 `Source:` line, step 1) is exempt.'
  done
}

@test "to-issues' in-place rewrite keeps a source issue's title and Source: line as fetch printed them, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    grep -qF "Keep the source's title and its column-0 \`Source:\` line as \`fetch\` printed them" "$output"
  done
}

@test "the guide's lifecycle note exempts auto-promoted fix issues by their column-0 Source: line under both trackers" {
  note=$(grep -A3 -F 'checks the issue against the design standard' "$REPO_ROOT/docs/guide.md")
  [[ "$note" == *'column-0 `Source:` line'* ]]
  [[ "$note" == *'`Source: review (<branch>)`'* ]]
  [[ "$note" == *'`Source: <report> (<branch>)`'* ]]
}

@test "the guide names /to-issues <ref> as the needs-triage to ready-for-agent step" {
  local guide="$REPO_ROOT/docs/guide.md"
  grep -qF 'needs-triage  →  /to-issues <ref>  →  ready-for-agent' "$guide"
  awk '/^### Triage Labels/{f=1;next} /^---/{f=0} f' "$guide" | grep -qF '`/to-issues <ref>`'
}
