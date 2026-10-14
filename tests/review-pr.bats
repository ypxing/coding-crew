#!/usr/bin/env bats
# review-pr is a skill and one prompt file: no script. These pin what solve-feature's fix step and
# address-pr-comments read from them.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
PROMPT="$REPO_ROOT/skills/review-pr/reviewer-prompt.md"
SKILL="$REPO_ROOT/skills/review-pr/SKILL.md"

@test "the reviewer's prompt asks the three questions, read-only, and names the report fields fix reads" {
  grep -qF '1. **Spec.**' "$PROMPT" && grep -qF '2. **What breaks.**' "$PROMPT" && grep -qF '3. **Standards.**' "$PROMPT"
  grep -qF "never edit, commit or" "$PROMPT"
  grep -qF '"prd": "met|unmet"' "$PROMPT" && grep -qF '"gaps"' "$PROMPT" && grep -qF '"findings"' "$PROMPT"
  grep -qF '<details><summary>Spec</summary>' "$PROMPT"
}

@test "the skill runs the reviewer on the installed prompt, posts one review carrying the crew-finding marker, and has no script" {
  grep -qF '.coding-crew/review-pr/reviewer-prompt.md' "$SKILL"
  grep -qF 'gh pr review <n> --comment' "$SKILL"
  grep -qF '<!-- crew-finding: review-pr -->' "$SKILL"
  [ ! -e "$REPO_ROOT/skills/review-pr/scripts" ]
}
