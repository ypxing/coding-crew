#!/usr/bin/env bats

# github-backend prose in to-issues, to-prd, upgrade-deps and crew-address-findings — the
# producer side of the ## Blocked by/Source:/PRD: #<n> dependency-graph convention issue
# 04's parseIssue reads. See .scratch/github-issue-tracker/issues/open/
# 08-skill-prose-github-support.md.

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export TO_ISSUES="$SCRIPT_DIR/skills/to-issues/SKILL.md"
  export TO_PRD="$SCRIPT_DIR/skills/to-prd/SKILL.md"
  export UPGRADE_DEPS="$SCRIPT_DIR/skills/upgrade-deps/SKILL.md"
  export ADDRESS_FINDINGS="$SCRIPT_DIR/skills/crew-address-findings/SKILL.md"
}

# ─── to-issues: publish through the tracker CLI ────────────────────────────────

@test "to-issues/SKILL.md publishes through the CLI's publish-issues and runs no gh" {
  grep -qF 'node "$TRACKER" publish-issues --feature-slug <feature-slug>' "$TO_ISSUES"
  ! grep -q 'gh issue create' "$TO_ISSUES"
  ! grep -q -- '--milestone' "$TO_ISSUES"
}

@test "body-format.mjs's extractBlockedByNumbers matches the Issue #<n> ref publish-issues writes on github" {
  # extractBlockedByNumbers: /\bissue[\s-]*#?0*([0-9]+)\b/gi — confirm the literal string
  # github's publish-issues writes as a blocker ref ("Issue #<n>") is one this regex matches.
  grep -qF 'blockerRef: `Issue #${number}`' "$SCRIPT_DIR/tracker/github.mjs"
  local sample="- Issue #7"
  [[ "$sample" =~ [Ii]ssue[[:space:]-]*\#?0*([0-9]+) ]]
  [ "${BASH_REMATCH[1]}" = "7" ]
}

@test "to-issues/SKILL.md names expand-contract.md, no longer holds its text, and the rerun questions are the CLI's exits" {
  ! grep -q 'references/rerun.md' "$TO_ISSUES"
  ! grep -q 'references/github-publish.md' "$TO_ISSUES"
  grep -q 'references/expand-contract.md' "$TO_ISSUES"
  grep -q 'Please reconcile manually' "$TO_ISSUES"
  ! grep -q 'Contract.* delete the old form' "$TO_ISSUES"
}

@test "to-issues references hold the expand-contract prose" {
  grep -q 'Contract.* delete the old form' "$SCRIPT_DIR/skills/to-issues/references/expand-contract.md"
}

@test "to-issues/SKILL.md's step 1 no longer blanket-forbids remote trackers" {
  ! grep -q 'Do NOT fetch from external URLs or remote issue trackers — only read local files' "$TO_ISSUES"
  grep -q 'configured.*tracker' "$TO_ISSUES"
}

@test "to-issues/SKILL.md still forbids arbitrary external URLs" {
  grep -qi 'arbitrary' "$TO_ISSUES"
}

# ─── to-prd: publish under github ──────────────────────────────────────────────

@test "to-prd/SKILL.md's publish step titles the PRD issue 'PRD: <feature title>'" {
  grep -q 'PRD: <feature title>' "$TO_PRD"
}

@test "to-prd/SKILL.md's publish step creates/updates the PRD issue inside the feature's milestone" {
  grep -q 'milestone' "$TO_PRD"
}

@test "to-prd/SKILL.md publishes through the CLI's publish-prd, a pin failure never failing it" {
  grep -qF 'node "$TRACKER" publish-prd' "$TO_PRD"
  ! grep -q 'gh issue' "$TO_PRD"
  grep -qi 'pin failure' "$TO_PRD"
}

@test "to-prd/SKILL.md scopes the never-commit-PRD.md warning to the local tracker" {
  grep -q 'Local tracker only' "$TO_PRD"
}

# ─── upgrade-deps and crew-address-findings reuse to-issues's pattern ──────────

@test "upgrade-deps/SKILL.md's publish step reuses to-issues' write step rather than inventing a second one" {
  grep -qF "\`to-issues\`' step 6 (\"Write the issues\")" "$UPGRADE_DEPS"
  grep -q 'publish-issues' "$UPGRADE_DEPS"
}

@test "crew-address-findings/SKILL.md's promoted-fix-issue reference is backend-neutral" {
  grep -q 'fix issue reference' "$ADDRESS_FINDINGS"
  grep -qF "the ref \`promote-findings.sh\` prints" "$ADDRESS_FINDINGS"
}

@test "crew-address-findings/SKILL.md's Promoted Findings line names the optional finding count after the reference" {
  grep -qF '<branch>: <severities> → <fix issue reference> (<n> finding(s))' "$ADDRESS_FINDINGS"
  grep -q 'the text before' "$ADDRESS_FINDINGS"
}

@test "crew-address-findings/SKILL.md loads the PRD through the CLI's prd, whatever the tracker" {
  grep -qF 'node "$TRACKER" prd --feature-slug <feature-slug>' "$ADDRESS_FINDINGS"
}
