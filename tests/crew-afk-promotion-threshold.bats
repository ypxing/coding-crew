#!/usr/bin/env bats

# Findings promotion rule: afk.fixFindings (CREW_FIX_FINDINGS in sprint.env) — actionable
# (default: every finding triage judges Actionable), or the lowest severity fixed
# automatically — critical | high | medium — or none.
#
# Every promoted branch costs a full coder + verify + review + merge cycle. A severity level
# below HIGH is opt-in: MEDIUM needs no failure scenario or pre-report gate.
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

@test "guard names the severities it is given, and keeps no level table of its own" {
  G=.scratch/feat/issues/open/01-a.md
  run bash "$PROMOTE" guard --issue $G --severities actionable
  [[ "$output" == "guard: eligible — threshold: actionable" ]]
  run bash "$PROMOTE" guard --issue $G --severities "CRITICAL, HIGH"
  [[ "$output" == "guard: eligible — threshold: CRITICAL, HIGH" ]]
  run bash "$PROMOTE" guard --issue $G --severities ""
  [[ "$output" == "guard: skip — fixFindings is none" ]]
  ! grep -qE 'critical\)|medium\)|CREW_PROMOTE|CREW_FIX_FINDINGS' "$PROMOTE"
}

@test "guard and defer without a severity list fail naming the missing argument" {
  run bash "$PROMOTE" guard --issue .scratch/feat/issues/open/01-a.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required argument --severities"* ]]
  run bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a \
    --title t --report "$REPORT" --criteria-file crit.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required argument --severities"* ]]
}

@test "CREW_PROMOTE and CREW_FIX_FINDINGS change nothing in the script" {
  CREW_PROMOTE=critical CREW_FIX_FINDINGS=none run bash "$PROMOTE" guard --issue .scratch/feat/issues/open/01-a.md --severities actionable
  [[ "$output" == "guard: eligible — threshold: actionable" ]]
}

@test "guard is still the depth bound regardless of threshold" {
  printf '# fix\n\nStatus: deferred-findings\nSource: r (b)\n' > .scratch/feat/issues/open/02-fix.md
  run bash "$PROMOTE" guard --issue .scratch/feat/issues/open/02-fix.md --severities actionable
  [[ "$output" == *"skip — source-guarded"* ]]
}

@test "defer marks actionable by default, CRITICAL, HIGH at fixFindings high, and CRITICAL alone at critical" {
  bash "$PROMOTE" defer --severities "actionable" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^- crew/feat/a: actionable → ' "$REPORT"

  rm .scratch/feat/issues/open/02-fix-findings-a.md
  bash "$PROMOTE" defer --severities "CRITICAL, HIGH" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^- crew/feat/a: CRITICAL, HIGH → ' "$REPORT"

  rm .scratch/feat/issues/open/02-fix-findings-a.md
  bash "$PROMOTE" defer --severities "CRITICAL" --feature-slug feat --branch crew/feat/a --slug a \
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

  run bash "$PROMOTE" guard --issue "$f" --severities actionable
  [[ "$output" == *"skip — source-guarded"* ]]

  run bash "$PROMOTE" defer-gaps --feature-slug feat --report .scratch/feat/prd-audit.md --criteria-file gaps.md
  [[ "$output" == "defer-gaps: skip — already queued: $f" ]]

  run bash "$PROMOTE" flush --feature-slug feat
  [[ "$output" == *"FLUSH: promoted=1"* ]]
}

# ─── the compensating half: nothing is dropped ───────────────────────────────

@test "an unpromoted HIGH is counted for a human, not silently dropped" {
  bash "$PROMOTE" defer --severities "CRITICAL" --feature-slug feat --branch crew/feat/a --slug a \
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

@test "at fixFindings high, a promoted HIGH is subtracted again" {
  bash "$PROMOTE" defer --severities "CRITICAL, HIGH" --feature-slug feat --branch crew/feat/a --slug a \
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
  bash "$PROMOTE" defer --severities "CRITICAL" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null

  run bash "$scripts/crew-summary.sh" --feature-slug feat --promoted CRITICAL
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
  # tests/orchestrator/sprint-settings.test.mjs.
  for f in "$REPO_ROOT"/skills/crew-afk/SKILL.md; do
    if grep -qiE 'Never promote MEDIUM or LOW|severities: CRITICAL' "$f"; then
      echo "$(basename "$f") states the threshold itself" >&2; return 1
    fi
  done
  grep -q 'CREW_FIX_FINDINGS' "$REPO_ROOT/orchestrator/lib/sprint.mjs"
  ! grep -qE '"CRITICAL"\s*,\s*"HIGH"' "$REPO_ROOT/orchestrator/lib/pipeline.mjs" "$REPO_ROOT"/orchestrator/lib/pipeline/*.mjs
}

# ─── actionable: triage's verdicts sit beside each finding ───────────────────

# A review whose findings carry the verdict and rationale crew-afk's triage wrote.
verdict_report() {
  jq -n '{
    branch: "crew/feat/a", slug: "a", verdict: "all-met",
    findings: [
      {severity: "HIGH", location: "src/y.ts:40", criterion: "Rename the exported helper", verdict: "debatable", rationale: "public contract change"},
      {severity: "LOW", location: "z.ts:1", criterion: "a nit", verdict: "actionable", rationale: "one local line"},
      {severity: "MEDIUM", location: "w.ts:2", criterion: "extra guard", verdict: "dismiss", rationale: "already guarded"},
      {severity: "LOW", location: "v.ts:3", criterion: "never triaged"}
    ]
  }' > verdicts.json
  { printf '## Branch: crew/feat/a (a)\n\n```json\n'; cat verdicts.json; printf '\n```\n'; } > "$REPORT"
}

@test "remind leads with Debatable, then Dismissed collapsed with its rationale" {
  verdict_report
  run bash "$PROMOTE" remind --feature-slug feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"FINDINGS: open=3 (HIGH=1, LOW=2)"* ]]
  [[ "$output" == *"DEBATABLE: 1 (decide these first)"* ]]
  [[ "$output" == *"debatable: crew/feat/a [HIGH] src/y.ts:40 — Rename the exported helper — why: public contract change"* ]]
  [[ "$output" == *"ACTIONABLE: 1 (not promoted)"* ]]
  [[ "$output" == *"DISMISSED: 1 (triage's rationale, collapsed)"* ]]
  [[ "$output" == *"dismissed: crew/feat/a [MEDIUM] w.ts:2 — extra guard — why: already guarded"* ]]
  # an untriaged finding is counted but listed under no verdict
  [[ "$output" != *"never triaged"* ]]
  # Debatable first, then the Actionable that was not promoted, then Dismissed, then the reports
  d=${output%%DEBATABLE:*}; a=${output%%ACTIONABLE:*}; x=${output%%DISMISSED:*}; r=${output%%report:*}
  [ ${#d} -lt ${#a} ]; [ ${#a} -lt ${#x} ]; [ ${#x} -lt ${#r} ]
}

@test "remind prints no verdict lines for findings triage never judged" {
  run bash "$PROMOTE" remind --feature-slug feat
  [[ "$output" == *"FINDINGS: open=3 (CRITICAL=1, HIGH=1, LOW=1)"* ]]
  [[ "$output" != *"DEBATABLE"* && "$output" != *"DISMISSED"* && "$output" != *"ACTIONABLE"* ]]
}

@test "a promoted Actionable is handled; Debatable and Dismissed stay open" {
  verdict_report
  bash "$PROMOTE" defer --feature-slug feat --branch crew/feat/a --slug a --severities actionable \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  grep -q '^- crew/feat/a: actionable → ' "$REPORT"
  run bash "$PROMOTE" remind --feature-slug feat
  [[ "$output" == *"FINDINGS: open=2 (HIGH=1, LOW=1)"* ]]
  [[ "$output" != *"ACTIONABLE"* ]]
  [[ "$output" == *"DEBATABLE: 1"* && "$output" == *"DISMISSED: 1"* ]]
  run bash "$PROMOTE" open --feature-slug feat
  [ "$(jq 'length' <<< "$output")" -eq 3 ]
  [ "$(jq -r '[.[].verdict] | sort | join(",")' <<< "$output")" = ",debatable,dismiss" ]
}

@test "a severity-level promotion still subtracts by (branch, severity), verdicts or not" {
  verdict_report
  bash "$PROMOTE" defer --severities "CRITICAL, HIGH" --feature-slug feat --branch crew/feat/a --slug a \
    --title "Fix review findings: a" --report "$REPORT" --criteria-file crit.md >/dev/null
  run bash "$PROMOTE" remind --feature-slug feat
  [[ "$output" == *"FINDINGS: open=2 (LOW=2)"* ]]
}

@test "the summary leads its next step with the Debatable findings" {
  scripts="$TEMP_DIR/installed"
  mkdir -p "$scripts"
  cp "$AFK_SCRIPTS"/*.sh "$scripts/"
  cp "$REPO_ROOT/scripts/skill-utils/git-workflow/feature-branch-setup.sh" "$scripts/"
  bash "$scripts/session-init.sh" --feature-slug feat >/dev/null
  bash "$scripts/state.sh" complete --slug a --branch crew/feat/a --feature-slug feat >/dev/null
  verdict_report
  run bash "$scripts/crew-summary.sh" --feature-slug feat --promoted actionable
  [[ "$output" == *"## Next Step"* ]]
  [[ "$output" == *"1 Debatable — decide these first"* ]]
  [[ "$output" == *"- crew/feat/a [HIGH] src/y.ts:40 — Rename the exported helper — why: public contract change"* ]]
  [[ "$output" == *"triage judged them Debatable or Dismissed"* ]]
}

# Fixture set shared with tests/orchestrator/body-format.test.mjs (isSourceGuarded).
@test "guard counts Source: only at column 0 outside a code fence" {
  g() { printf '%b' "$1" > .scratch/feat/issues/open/03-fx.md; bash "$PROMOTE" guard --issue .scratch/feat/issues/open/03-fx.md --severities actionable; }
  run g '# t\n\nSource: r (b)\n';                       [[ "$output" == *"source-guarded"* ]]
  run g '# t\n\n```\nSource: r (b)\n```\n';             [[ "$output" == *"eligible"* ]]
  run g '# t\n\n~~~\nSource: r (b)\n~~~\n';             [[ "$output" == *"eligible"* ]]
  run g '# t\n\n```\nx\n```\n\nSource: r (b)\n';        [[ "$output" == *"source-guarded"* ]]
  run g '# t\n\n  Source: r (b)\n';                     [[ "$output" == *"eligible"* ]]
  run g '# t\n\n**Source:** r (b)\n';                   [[ "$output" == *"eligible"* ]]
}
