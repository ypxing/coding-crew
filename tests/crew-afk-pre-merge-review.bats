#!/usr/bin/env bats

# Tests for per-branch pre-merge code review positioning in crew-afk skill files
# Following the pattern in tests/crew-code-reviewer-structure.bats

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export REVIEWER_PROTOCOL="$SCRIPT_DIR/agents/crew-code-reviewer/protocol.md"
  export REVIEWER_CLAUDE="$SCRIPT_DIR/agents/crew-code-reviewer/claude.agent.md"
  export REVIEWER_COPILOT="$SCRIPT_DIR/agents/crew-code-reviewer/copilot.agent.md"
}

# Extract YAML frontmatter (between first pair of --- delimiters)
frontmatter() {
  awk 'BEGIN{f=0} /^---/{f++; next} f==1{print}' "$1"
}

# ─── Agent descriptions match per-branch pre-merge invocation ────────────────

@test "reviewer claude.agent.md description does not claim end-of-session invocation" {
  # The reviewer is now dispatched per-branch before merge, not once at the end.
  # grep -E for alternation: `\|` is a GNU BRE extension, not portable to BSD/macOS.
  ! frontmatter "$REVIEWER_CLAUDE" | grep -qiE 'once at the end|end of the session'
}

@test "reviewer copilot.agent.md description does not claim batch review of all branches" {
  ! frontmatter "$REVIEWER_COPILOT" | grep -qi 'all branches'
}

@test "reviewer agent descriptions state per-branch review on both platforms" {
  frontmatter "$REVIEWER_CLAUDE" | grep -qiE 'one branch|per-branch|single branch'
  frontmatter "$REVIEWER_COPILOT" | grep -qiE 'one branch|per-branch|single branch'
}

@test "reviewer agent descriptions still state findings are advisory on both platforms" {
  frontmatter "$REVIEWER_CLAUDE" | grep -qi 'advisory'
  frontmatter "$REVIEWER_COPILOT" | grep -qi 'advisory'
}

# ─── Snippet requirement at all severities ───────────────────────────────────

@test "reviewer protocol requires snippets at all severities (CRITICAL, HIGH, MEDIUM, LOW)" {
  # Protocol must mention snippets/code for MEDIUM and LOW (already has it for CRITICAL/HIGH)
  grep -q 'snippet\|Snippet' "$REVIEWER_PROTOCOL"
  # Must apply snippet requirement to MEDIUM and LOW
  grep -A20 'MEDIUM\|LOW' "$REVIEWER_PROTOCOL" | grep -q 'snippet\|Snippet\|code.*line\|line.*code'
}

@test "reviewer protocol snippet requirement extends to every severity" {
  # Look for phrasing that applies snippet to all severities, not just HIGH/CRITICAL
  grep -qiE 'every.*severity|all.*severity|every.*finding|each.*finding.*snippet|snippet.*every' "$REVIEWER_PROTOCOL"
}

# ─── Review positioned before merge ──────────────────────────────────────────
#
# Every platform is a launcher now, so the position of the review is not prose anywhere:
# it is the pipeline chain in orchestrator/lib/pipeline.mjs, asserted on a real
# (faked-dispatch) run in tests/orchestrator/sprint.test.mjs — "the gates run in order:
# verify → AC receipt → merge → close, and squash last" and "the review is written to the
# sprint's reviews dir, before the squash". The body versions of five tests lived here
# (review before merge, review before squash, no post-squash review, the no-branch skip,
# the report path) and were deleted with the bodies that carried them. The one that is not
# a body claim — where session-init.sh puts REVIEW_DIR — stays below.

# ─── Branch attribution in report ────────────────────────────────────────────

@test "reviewer protocol output format includes branch attribution" {
  # The output format should include Branch in each review block
  grep -q 'Branch:' "$REVIEWER_PROTOCOL"
}

# ─── Report path / format unchanged ─────────────────────────────────────────

@test "REVIEW_DIR resolves to .scratch/<feature-slug>/reviews" {
  grep -q 'REVIEW_DIR="$MAIN_ROOT/.scratch/$FEATURE_SLUG/reviews"' \
    "$SCRIPT_DIR/skills/crew-afk/scripts/session-init.sh"
}

# ─── Read-only reviewer ──────────────────────────────────────────────────────

@test "crew-code-reviewer claude.agent.md does not include Edit tool" {
  AGENT="$SCRIPT_DIR/agents/crew-code-reviewer/claude.agent.md"
  # tools list must not include Edit
  ! grep -qE '"Edit"|Edit.*tool|tools.*Edit' "$AGENT"
}

@test "crew-code-reviewer copilot.agent.md does not include edit tool" {
  AGENT="$SCRIPT_DIR/agents/crew-code-reviewer/copilot.agent.md"
  # tools list must not include edit
  ! grep -qE '"edit"\b' "$AGENT"
}
