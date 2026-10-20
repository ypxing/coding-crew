#!/usr/bin/env bats
# write-pr is one SKILL.md. This pins that a title follows the repo's documented title rule, which a review flags
# when the PR breaks it and which no later step can fix.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
SKILL="$REPO_ROOT/skills/write-pr/SKILL.md"

@test "write-pr gathers the repo's PR-title rule and lets it win, never inventing a ticket ID" {
  grep -qF '**The title rule.** A PR-title format the repo documents' "$SKILL"
  grep -qF "The repo's title rule, when it documents one, wins where it differs" "$SKILL"
  grep -qF 'never an invented one' "$SKILL"
}
