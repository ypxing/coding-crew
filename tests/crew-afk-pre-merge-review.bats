#!/usr/bin/env bats

# Tests for per-branch pre-merge code review positioning in crew-afk skill files
# Following the pattern in tests/crew-code-reviewer-structure.bats

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export COPILOT_SKILL="$(afk_variant copilot)"
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
# On a launcher platform the position of the review is not prose: it is the pipeline
# chain in orchestrator/lib/pipeline.mjs, asserted on a real (faked-dispatch) run in
# tests/orchestrator/sprint.test.mjs — "the gates run in order: verify → AC receipt →
# merge → close, and squash last" and "the review is written to the sprint's reviews dir,
# before the squash". The claude-body versions of the four tests below (review before
# merge, review before squash, no post-squash review, the report path) were deleted with
# that body; copilot keeps its prose, so it keeps its assertions.

@test "copilot SKILL.md invokes crew-code-reviewer before merge step" {
  # Anchor on the pipeline steps themselves, not on any line containing the word
  # "review" or "merge": this test once passed on a `crew-code-reviewer` mention in
  # the frontmatter description, which says nothing about where the step sits.
  REVIEW_LINE=$(grep -n 'Per-branch code review' "$COPILOT_SKILL" | head -1 | cut -d: -f1)
  MERGE_LINE=$(grep -n 'scripts/merge-branches\.sh"' "$COPILOT_SKILL" | head -1 | cut -d: -f1)

  [ -n "$REVIEW_LINE" ] || { echo "No per-branch review step found in COPILOT_SKILL"; return 1; }
  [ -n "$MERGE_LINE" ] || { echo "No merge-branches.sh invocation found in COPILOT_SKILL"; return 1; }

  # Review must come before merge
  [ "$REVIEW_LINE" -lt "$MERGE_LINE" ]
}

@test "copilot SKILL.md invokes review before squash step" {
  # Extract line numbers for review and squash script call
  REVIEW_LINE=$(grep -n 'crew-code-reviewer\|per.branch.*review\|dispatch.*review' "$COPILOT_SKILL" | grep -iv 'old\|redundant\|post.merge\|session.*review\|coverage' | head -1 | cut -d: -f1)
  SQUASH_LINE=$(grep -n 'squash-commits.sh\|squash.*commit' "$COPILOT_SKILL" | head -1 | cut -d: -f1)

  [ -n "$REVIEW_LINE" ] || { echo "No review invocation found in COPILOT_SKILL"; return 1; }
  [ -n "$SQUASH_LINE" ] || { echo "No squash step found in COPILOT_SKILL"; return 1; }

  # Review must come before squash
  [ "$REVIEW_LINE" -lt "$SQUASH_LINE" ]
}

# ─── Branch attribution in report ────────────────────────────────────────────

@test "reviewer protocol output format includes branch attribution" {
  # The output format should include Branch in each review block
  grep -q 'Branch:' "$REVIEWER_PROTOCOL"
}

# ─── Skipped review reporting ────────────────────────────────────────────────

@test "copilot SKILL.md handles no-branch case without failing" {
  # Must have explicit skip reporting when there are no branches to review
  grep -qiE 'skip|no.*branch|no.*review|review.*skip' "$COPILOT_SKILL"
}

# ─── Old post-merge review removed ──────────────────────────────────────────

@test "copilot SKILL.md does not have a redundant post-squash code review step" {
  # After squash, there should NOT be a separate crew-code-reviewer dispatch
  SQUASH_LINE=$(grep -n 'squash-commits.sh' "$COPILOT_SKILL" | head -1 | cut -d: -f1)
  [ -n "$SQUASH_LINE" ] || { echo "No squash step found"; return 1; }

  # Count reviewer references after the squash line
  POST_SQUASH_REVIEW=$(awk -v start="$SQUASH_LINE" 'NR > start' "$COPILOT_SKILL" | grep -c 'crew-code-reviewer' || true)

  # No reviewer invocation after squash
  [ "$POST_SQUASH_REVIEW" -eq 0 ]
}

# ─── Report path / format unchanged ─────────────────────────────────────────

# The path itself is no longer spelled out in prose: session-init.sh exports REVIEW_DIR
# in sprint.env, so the body names $REVIEW_DIR and the directory is defined in one place.
@test "copilot SKILL.md still writes review to the sprint's reviews path" {
  grep -qE '\$REVIEW_DIR/sprint-review|\.scratch.*reviews|reviews/sprint-review' "$COPILOT_SKILL"
}

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
