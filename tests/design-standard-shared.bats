#!/usr/bin/env bats

# One design standard — four criteria in priority order, each with its failure signals, and the
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

@test "the standard names its four criteria in priority order, with correctness after the first" {
  local nec cor reu few say
  nec=$(grep -n '\*\*Necessary\*\*' "$STANDARD" | head -1 | cut -d: -f1)
  reu=$(grep -n '\*\*Reusable along real axes\*\*' "$STANDARD" | head -1 | cut -d: -f1)
  few=$(grep -n '\*\*Fewest moving parts\*\*' "$STANDARD" | head -1 | cut -d: -f1)
  say=$(grep -n '\*\*Says what it does\*\*' "$STANDARD" | head -1 | cut -d: -f1)
  [ -n "$nec" ] && [ -n "$reu" ] && [ -n "$few" ] && [ -n "$say" ]
  [ "$nec" -lt "$reu" ] && [ "$reu" -lt "$few" ] && [ "$few" -lt "$say" ]
  grep -qF 'necessary > correct > reusable along real axes > fewest moving parts > says what it does' "$STANDARD"
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

@test "criterion 2 takes its axes from the project's CLAUDE.md and falls back to real callers now" {
  grep -qF "axes of variation the project's \`CLAUDE.md\` names" "$STANDARD"
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

@test "the reviewer applies criteria 2-4, at LOW with file:line and a snippet, never as an unmet criterion" {
  local f; f="$(role_prompt reviewer claude)"
  grep -qF 'criteria 2–4' "$f"
  grep -qF 'design-only finding' "$f"
  grep -qF 'at `LOW`, only with its exact `file:line` and a snippet' "$f"
  grep -qF 'never makes an acceptance criterion `unmet`' "$f"
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

@test "to-issues rewrites a single-slice source issue in place and keeps ## Parent for a split one, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    grep -qF 'gh issue edit <n> --body-file' "$output"
    grep -qi 'rewrit.* in place' "$output"
    grep -qF 'under `local`, overwrite that issue file' "$output"
    grep -qF 'several slices' "$output"
    grep -qF '## Parent' "$output"
  done
}

@test "to-issues' github in-place rewrite swaps the triage label for the slice's status and sets the milestone, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    grep -qF -- '--remove-label needs-triage --add-label <status>' "$output"
    grep -qF -- '--milestone <feature-slug>' "$output"
    if grep -qF 'its body is the one edit made to it' "$output"; then false; fi
  done
}

@test "to-issues exempts auto-promoted fix issues under both trackers, by promote-findings.sh's column-0 Source: rule, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    line=$(grep -F 'not checked against the design standard' "$output")
    [[ "$line" == *'column-0 `Source:` line outside a code fence'* ]]
    [[ "$line" == *'`Source: review (<branch>)`'*'github'* ]]
    [[ "$line" == *'`Source: <report> (<branch>)` after the title and `Status:` lines under `local`'* ]]
    grep -F 'Fails the design standard' "$output" | grep -qF 'An auto-promoted issue (a column-0 `Source:` line, step 1) is exempt.'
  done
}

@test "to-issues' in-place rewrite keeps a source issue's Source: line in the same position under both trackers, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    line=$(grep -F "rewrite that issue's body in place" "$output")
    [[ "$line" == *'column-0 `Source:` line stays in the same position — the body'"'"'s first line under `github`, after the title and `Status:` lines under `local`'* ]]
  done
}

@test "the guide's lifecycle note exempts auto-promoted fix issues by their column-0 Source: line under both trackers" {
  note=$(grep -A3 -F 'checks the issue against the design standard' "$REPO_ROOT/docs/guide.md")
  [[ "$note" == *'column-0 `Source:` line'* ]]
  [[ "$note" == *'`Source: review (<branch>)`'* ]]
  [[ "$note" == *'`Source: <report> (<branch>)`'* ]]
}

@test "to-issues creates the missing <feature-slug> milestone, list first, before the github in-place edit, for every platform" {
  for p in "${PLATFORMS[@]}"; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    line=$(grep -F 'gh issue edit <n> --body-file' "$output")
    [[ "$line" == *'gh api --paginate repos/{owner}/{repo}/milestones --jq'*'gh api repos/{owner}/{repo}/milestones -f title=<feature-slug>'*'gh issue edit <n> --body-file'* ]]
  done
}

@test "the guide names /to-issues <ref> as the needs-triage to ready-for-agent step" {
  local guide="$REPO_ROOT/docs/guide.md"
  grep -qF 'needs-triage  →  /to-issues <ref>  →  ready-for-agent' "$guide"
  awk '/^### Triage Labels/{f=1;next} /^---/{f=0} f' "$guide" | grep -qF '`/to-issues <ref>`'
}
