#!/usr/bin/env bats

# Findings promotion threshold: afk.fixFindings (CREW_FIX_FINDINGS in sprint.env) names the
# lowest severity fixed automatically — critical | high (default) | medium | none.
#
# Every promoted branch costs a full coder + verify + review + merge cycle. HIGH carries a
# named failure scenario and a pre-report gate, so it is fixed by default; MEDIUM needs
# neither, so it is opt-in.
#
# These tests pin the compensating half too: a finding the sprint did not promote must still
# be *counted and named* for /crew-address-findings, and the reminder must say which threshold
# left it open. A silently dropped finding is the failure mode.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_SCRIPTS="$REPO_ROOT/skills/crew-afk/scripts"
PROMOTE="$AFK_SCRIPTS/promote-findings.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  git init -q -b main
  git config user.email "test@test.com"
  git config user.name "Test"
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m initial
  export MAIN_ROOT="$TEMP_DIR"

  # promote-findings.sh and crew-summary.sh read the aggregate review report through
  # review-rollup.mjs, not a hand-rolled awk — point it at the repo's own copy, since
  # these fixtures exercise the scripts alone, not a full install.
  export CREW_REVIEW_ROLLUP="$REPO_ROOT/orchestrator/review-rollup.mjs"

  mkdir -p .scratch/feat/issues/open .scratch/feat/reviews
  printf '# a\n\nStatus: ready-for-agent\n' > .scratch/feat/issues/open/01-a.md
  export REPORT=.scratch/feat/reviews/sprint-review-1.md
  json=$(jq -n '{
    branch: "crew/feat/a", slug: "a", verdict: "all-met",
    findings: [
      {severity: "CRITICAL", location: "src/x.ts:12", criterion: "unchecked input"},
      {severity: "HIGH", location: "src/y.ts:40", criterion: "trust boundary crossed"},
      {severity: "LOW", location: "z.ts:1", criterion: "a nit"}
    ]
  }')
  cat > "$REPORT" <<EOF
## Branch: crew/feat/a (a)

\`\`\`json
$json
\`\`\`
EOF
  printf -- '- [ ] validate input at src/x.ts:12\n' > crit.md
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# ─── the default ─────────────────────────────────────────────────────────────

@test "policy defaults to CRITICAL and HIGH" {
  run bash "$PROMOTE" policy
  [ "$status" -eq 0 ]
  [ "$output" = "promote: CRITICAL, HIGH" ]
}

@test "each fixFindings level names its severities" {
  CREW_FIX_FINDINGS=critical run bash "$PROMOTE" policy
  [ "$output" = "promote: CRITICAL" ]
  CREW_FIX_FINDINGS=medium run bash "$PROMOTE" policy
  [ "$output" = "promote: CRITICAL, HIGH, MEDIUM" ]
  CREW_FIX_FINDINGS=none run bash "$PROMOTE" policy
  [ "$output" = "promote: " ]
}

@test "CREW_PROMOTE, the old name, is still read when CREW_FIX_FINDINGS is absent" {
  CREW_PROMOTE=critical run bash "$PROMOTE" policy
  [ "$output" = "promote: CRITICAL" ]
  CREW_PROMOTE=critical-high run bash "$PROMOTE" policy
  [ "$output" = "promote: CRITICAL, HIGH" ]
}

@test "guard names the severities to promote, so no caller carries the threshold in prose" {
  run bash "$PROMOTE" guard --issue .scratch/feat/issues/open/01-a.md
  [[ "$output" == "guard: promotable — severities: CRITICAL, HIGH" ]]

  CREW_FIX_FINDINGS=critical run bash "$PROMOTE" guard --issue .scratch/feat/issues/open/01-a.md
  [[ "$output" == "guard: promotable — severities: CRITICAL" ]]
}

@test "guard skips every branch when fixFindings is none" {
  CREW_FIX_FINDINGS=none run bash "$PROMOTE" guard --issue .scratch/feat/issues/open/01-a.md
  [[ "$output" == "guard: skip — fixFindings is none" ]]
}

@test "guard is still the depth bound regardless of threshold" {
  printf '# fix\n\nStatus: deferred-findings\nSource: r (b)\n' > .scratch/feat/issues/open/02-fix.md
  run bash "$PROMOTE" guard --issue .scratch/feat/issues/open/02-fix.md
  [[ "$output" == *"skip — source-guarded"* ]]
}

@test "defer marks CRITICAL, HIGH by default, and CRITICAL alone at fixFindings critical" {
  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^- crew/feat/a: CRITICAL, HIGH → ' "$REPORT"

  rm .scratch/feat/issues/open/02-fix-findings-a.md
  CREW_FIX_FINDINGS=critical bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^- crew/feat/a: CRITICAL → ' "$REPORT"
}

# ─── defer-gaps: the PRD audit's missing requirements ────────────────────────

@test "defer-gaps parks one source-guarded fix issue, and never a second while it is open" {
  printf -- '- [ ] Users can export to CSV\n' > gaps.md
  : > .scratch/feat/prd-audit.md
  run bash "$PROMOTE" defer-gaps --feature-slug feat --report .scratch/feat/prd-audit.md --criteria-file gaps.md
  [ "$status" -eq 0 ]
  [[ "$output" == "defer-gaps: .scratch/feat/issues/open/02-fix-prd-gaps.md" ]]
  f=.scratch/feat/issues/open/02-fix-prd-gaps.md
  grep -q '^Status: deferred-findings$' "$f"
  grep -q '^Source: .scratch/feat/prd-audit.md (prd-audit)$' "$f"
  grep -q '^- \[ \] Users can export to CSV$' "$f"

  run bash "$PROMOTE" guard --issue "$f"
  [[ "$output" == *"skip — source-guarded"* ]]

  run bash "$PROMOTE" defer-gaps --feature-slug feat --report .scratch/feat/prd-audit.md --criteria-file gaps.md
  [[ "$output" == "defer-gaps: skip — already queued: $f" ]]

  run bash "$PROMOTE" flush --feature-slug feat
  [[ "$output" == *"FLUSH: promoted=1"* ]]
}

# ─── the compensating half: nothing is dropped ───────────────────────────────

@test "an unpromoted HIGH is counted for a human, not silently dropped" {
  CREW_FIX_FINDINGS=critical bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null

  run bash "$PROMOTE" remind --feature-slug feat
  [[ "$output" == *"FINDINGS: open=2 (HIGH=1, LOW=1)"* ]]
  [[ "$output" == *"report: $REPORT"* ]]
}

@test "every finding in the report's json block is counted exactly once" {
  # The reviewer's `findings` array is the only representation now — no separate machine
  # line and prose block to reconcile, so nothing can double-count or under-count.
  json=$(jq -n '{
    branch: "crew/feat/a", slug: "a", verdict: "all-met",
    findings: [
      {severity: "CRITICAL", location: "src/x.ts:12", criterion: "Validate input before use"},
      {severity: "HIGH", location: "src/y.ts:40", criterion: "Move the trust boundary check"}
    ]
  }')
  cat > "$REPORT" <<EOF
## Branch: crew/feat/a (a)

\`\`\`json
$json
\`\`\`
EOF
  run bash "$PROMOTE" remind --feature-slug feat
  [[ "$output" == *"FINDINGS: open=2 (CRITICAL=1, HIGH=1)"* ]]
}

@test "at the default, a promoted HIGH is subtracted again" {
  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null

  run bash "$PROMOTE" remind --feature-slug feat
  [[ "$output" == *"FINDINGS: open=1 (LOW=1)"* ]]
}

@test "the summary names the threshold that left a HIGH finding open" {
  # Risk accepted with the reduced default: the user must be able to see *why* a HIGH is
  # still on the queue, or the reduction reads as the sprint having missed it.
  scripts="$TEMP_DIR/installed"
  mkdir -p "$scripts"
  cp "$AFK_SCRIPTS"/*.sh "$scripts/"
  cp "$REPO_ROOT/scripts/skill-utils/git-workflow/feature-branch-setup.sh" "$scripts/"
  bash "$scripts/session-init.sh" --feature-slug feat --fix-findings critical >/dev/null
  bash "$scripts/state.sh" complete --slug a --branch crew/feat/a --feature-slug feat >/dev/null
  CREW_FIX_FINDINGS=critical bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null

  run bash "$scripts/crew-summary.sh" --feature-slug feat
  [[ "$output" == *"## Next Step"* ]]
  [[ "$output" == *"promotion covered CRITICAL on Phase 1 branches only"* ]]
  [[ "$output" == *"afk.fixFindings, or --fix-findings"* ]]
}

# ─── one source for the threshold ────────────────────────────────────────────

@test "nothing outside this script and sprint.env states the promotion threshold" {
  # The threshold is printed by guard and read from CREW_FIX_FINDINGS. A second statement of
  # it — in a launcher, or hard-coded in the pipeline — is a source that can disagree with the
  # script the moment the default changes again. The wiring end to end (the default promotes
  # a HIGH into a Phase 2 fix issue, `medium` a MEDIUM) is asserted in
  # tests/orchestrator/sprint.test.mjs.
  for f in "$REPO_ROOT"/skills/crew-afk/*.SKILL.md; do
    if grep -qiE 'Never promote MEDIUM or LOW|severities: CRITICAL' "$f"; then
      echo "$(basename "$f") states the threshold itself" >&2; return 1
    fi
  done
  grep -q 'CREW_FIX_FINDINGS' "$REPO_ROOT/orchestrator/lib/sprint.mjs"
  ! grep -qE '"CRITICAL"\s*,\s*"HIGH"' "$REPO_ROOT/orchestrator/lib/pipeline.mjs" "$REPO_ROOT"/orchestrator/lib/pipeline/*.mjs
}
