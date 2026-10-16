#!/usr/bin/env bats
# crew-review is one SKILL.md and no script of its own (scripts/tracker/ is the rendered copy of lib/tracker/). These pin what solve-feature's fix step reads from its report, and that
# it only reports.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKILL="$REPO_ROOT/skills/crew-review/SKILL.md"

@test "crew-review is one file, review-pr is gone, and the registry ships crew-review as solve-feature's dep" {
  [ "$(ls "$REPO_ROOT/skills/crew-review" | paste -sd' ' -)" = "SKILL.md scripts" ]
  [ "$(ls "$REPO_ROOT/skills/crew-review/scripts")" = tracker ]
  jq -e '.skills["crew-review"].libs == ["tracker"]' "$REPO_ROOT/registry.json" >/dev/null
  [ ! -e "$REPO_ROOT/skills/review-pr" ]
  jq -e '.skills["crew-review"]["source-dir"] == "crew-review"' "$REPO_ROOT/registry.json" >/dev/null
  jq -e '.skills | has("review-pr") | not' "$REPO_ROOT/registry.json" >/dev/null
  jq -e '.skills["solve-feature"].deps | index("crew-review") and (index("review-pr") | not)' "$REPO_ROOT/registry.json" >/dev/null
}

@test "the review asks the three questions read-only, gaps against the code at HEAD, and names the report fields fix reads" {
  grep -qF '1. **Spec.**' "$SKILL"
  grep -qF '2. **What breaks.**' "$SKILL"
  grep -qF '3. **Standards.**' "$SKILL"
  grep -qF 'never edit,' "$SKILL"
  grep -qF 'the spec require that the code at HEAD lacks' "$SKILL"
  grep -qF '"spec": "met|unmet|none"' "$SKILL"
  grep -qF '"gaps"' "$SKILL"
  grep -qF '"findings"' "$SKILL"
  grep -qF '<details><summary>Spec</summary>' "$SKILL"
}

@test "crew-review reports only: no review, comment or ready call, and a fresh read-only subagent unless it cannot start one" {
  ! grep -qE 'gh pr (review|comment|ready)' "$SKILL" || false
  grep -qF 'fresh, read-only subagent' "$SKILL"
  grep -qF 'When you cannot start a subagent' "$SKILL"
  grep -qF 'print it' "$SKILL"
}
