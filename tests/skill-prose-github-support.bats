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

# ─── to-issues: publish under github ───────────────────────────────────────────

@test "to-issues/SKILL.md's publish step describes creating a github issue via gh issue create" {
  grep -q 'gh issue create' "$TO_ISSUES"
}

@test "to-issues/SKILL.md writes ## Blocked by entries as Issue #<n> under github" {
  grep -q 'Issue #<n>' "$TO_ISSUES"
}

@test "to-issues/SKILL.md cites the PRD issue as PRD: #<n> under github" {
  grep -q 'PRD: #<n>' "$TO_ISSUES"
}

@test "to-issues/SKILL.md's github Blocked-by convention matches body-format.mjs's extractBlockedByNumbers regex" {
  # extractBlockedByNumbers: /\bissue[\s-]*#?0*([0-9]+)\b/gi — confirm the literal string
  # to-issues instructs writing ("Issue #<n>") is one this regex actually matches once <n>
  # is a real number, so the reader issue 04 builds can parse what this issue writes.
  local sample="- Issue #7"
  [[ "$sample" =~ [Ii]ssue[[:space:]-]*\#?0*([0-9]+) ]]
  [ "${BASH_REMATCH[1]}" = "7" ]
}

@test "to-issues/SKILL.md milestones github issues to the feature slug" {
  grep -q -- '--milestone' "$TO_ISSUES"
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

@test "to-prd/SKILL.md's publish step best-effort pins the PRD issue without failing publish" {
  grep -q 'gh issue pin' "$TO_PRD"
  grep -qi 'pin failure' "$TO_PRD"
}

@test "to-prd/SKILL.md scopes the never-commit-PRD.md warning to the local tracker" {
  grep -q 'Local tracker only' "$TO_PRD"
}

# ─── upgrade-deps and crew-address-findings reuse to-issues's pattern ──────────

@test "upgrade-deps/SKILL.md's publish step reuses to-issues's github branch rather than inventing a second one" {
  grep -q 'to-issues' "$UPGRADE_DEPS"
  grep -q 'Issue #<n>' "$UPGRADE_DEPS"
}

@test "crew-address-findings/SKILL.md's promoted-fix-issue reference is backend-neutral" {
  grep -q 'fix issue reference' "$ADDRESS_FINDINGS"
  grep -q 'to-issues' "$ADDRESS_FINDINGS"
}

@test "crew-address-findings/SKILL.md loads the PRD from a github issue when configured" {
  grep -q 'PRD: <feature title>' "$ADDRESS_FINDINGS"
}
