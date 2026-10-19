#!/usr/bin/env bats
# crew-review is one SKILL.md and no script of its own (scripts/tracker is a link to lib/tracker/, copied through at install). These pin what solve-feature's fix step reads from its report, and that
# it only reports.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKILL="$REPO_ROOT/skills/crew-review/SKILL.md"

@test "crew-review is one file, review-pr is gone, and the registry ships crew-review as solve-feature's dep" {
  # LC_ALL=C: under a UTF-8 locale ls may sort case-insensitively, scripts before SKILL.md.
  run bash -c 'cd "$1" && LC_ALL=C ls | paste -sd" " -' _ "$REPO_ROOT/skills/crew-review"
  [ "$output" = "SKILL.md scripts" ] || { echo "got: $output"; return 1; }
  [ "$(ls "$REPO_ROOT/skills/crew-review/scripts")" = tracker ]
  jq -e '.skills["crew-review"].libs == ["tracker"]' "$REPO_ROOT/registry.json" >/dev/null
  [ ! -e "$REPO_ROOT/skills/review-pr" ]
  jq -e '.skills["crew-review"]["source-dir"] == "crew-review"' "$REPO_ROOT/registry.json" >/dev/null
  jq -e '.skills | has("review-pr") | not' "$REPO_ROOT/registry.json" >/dev/null
  jq -e '.skills["solve-feature"].deps | index("crew-review") and (index("review-pr") | not)' "$REPO_ROOT/registry.json" >/dev/null
}

@test "the review asks the three questions, hostile input included, leaving the repo as found, gaps against the code at HEAD, and names the report fields fix reads" {
  grep -qF '1. **Spec.**' "$SKILL"
  grep -qF '2. **What breaks.**' "$SKILL"
  grep -qF '**Hostile input:**' "$SKILL"
  grep -qF 'opens a security hole' "$SKILL"
  grep -qF '3. **Standards.**' "$SKILL"
  grep -qF 'Leave the repo as you found it' "$SKILL"
  grep -qF 'read the deleted files in full and trace the old path' "$SKILL"
  grep -qF 'the spec require that the code at HEAD lacks' "$SKILL"
  grep -qF '"spec": "met|unmet|none"' "$SKILL"
  grep -qF '"gaps"' "$SKILL"
  grep -qF '"findings"' "$SKILL"
  grep -qF '<details><summary>Spec</summary>' "$SKILL"
}

@test "crew-review reports only: no review, comment or ready call, and reviews itself when started to review, else in one fresh subagent that can run any shell command" {
  ! grep -qE 'gh pr (review|comment|ready)' "$SKILL" || false
  grep -qF '**fresh subagent**' "$SKILL"
  grep -qF 'run any shell command and write scratch files outside the repo' "$SKILL"
  ! grep -qF 'no tool that edits files' "$SKILL" || false
  ! grep -qi 'read-only' "$SKILL" || false
  grep -qF 'If HEAD moved or the tree changed, say so' "$SKILL"
  grep -qF 'When you were started to review it, do the review below' "$SKILL"
  grep -qF 'Use the crew-review skill on <the change>' "$SKILL"
  ! grep -qF 'answer its three questions yourself' "$SKILL" || false
  grep -qF 'Start helper subagents whenever they help' "$SKILL"
  grep -qF 'Every judgement about the change is made on your model, never a weaker' "$SKILL"
  grep -qF 'the report is yours, judged across the whole change' "$SKILL"
  ! grep -qF 'you write every finding yourself' "$SKILL" || false
  grep -qF 'print it' "$SKILL"
}
