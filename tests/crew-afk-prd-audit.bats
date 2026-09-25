#!/usr/bin/env bats

# Tests for crew-afk PRD audit step (prd-audit.sh)

load helpers/render

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/skills/crew-afk/scripts/prd-audit.sh"

# Where the step runs (after Phase 1, before the flush and the squash) and what `fix` does
# with its gaps is asserted by tests/orchestrator/sprint.test.mjs, from the trace log. This
# file covers the script alone: when it skips, and the prompt it prints.

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git commit --allow-empty -m "initial"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# --- Script Existence Tests ---

@test "prd-audit.sh script exists" {
  [ -f "$AUDIT_SCRIPT" ]
}

# --- Mode Tests ---

@test "prd-audit.sh with nothing set is off: no audit, and says how to turn it on" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature
  echo "# PRD" > .scratch/test-feature/PRD.md

  run bash "$AUDIT_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == "PRD audit: skipped"* ]]
  [[ "$output" == *"afk.PRDAudit"* ]]
  # The prompt must not be printed for a step that is not running.
  [[ "$output" != *"Extract all requirements"* ]]
}

@test "prd-audit.sh honours CREW_PRD_AUDIT from sprint.env" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature
  echo "# PRD" > .scratch/test-feature/PRD.md

  CREW_PRD_AUDIT=fix run bash "$AUDIT_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]]
  [[ "$output" == *"(mode: fix)"* ]]
}

@test "prd-audit.sh rejects an unknown mode" {
  run bash "$AUDIT_SCRIPT" --mode sometimes
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be off, report or fix"* ]]
}

@test "session-init records the PRD audit mode and the fix threshold in sprint.env" {
  # Captured once, where the arguments arrive — not carried in the orchestrator's head for
  # the length of a sprint. --coverage and --promote are the old names.
  scripts="$TEMP_DIR/scripts"
  mkdir -p "$scripts"
  cp "$SCRIPT_DIR/skills/crew-afk/scripts/"*.sh "$scripts/"
  cp "$SCRIPT_DIR/scripts/skill-utils/git-workflow/feature-branch-setup.sh" "$scripts/"
  mkdir -p .scratch/feat/issues/open
  echo "Status: ready-for-agent" > .scratch/feat/issues/open/01-a.md

  bash "$scripts/session-init.sh" --feature-slug feat >/dev/null
  grep -q 'export CREW_PRD_AUDIT="off"' .scratch/feat/sprint.env
  grep -q 'export CREW_FIX_FINDINGS="high"' .scratch/feat/sprint.env

  bash "$scripts/session-init.sh" --feature-slug feat --prd-audit fix --fix-findings medium >/dev/null
  grep -q 'export CREW_PRD_AUDIT="fix"' .scratch/feat/sprint.env
  grep -q 'export CREW_FIX_FINDINGS="medium"' .scratch/feat/sprint.env

  bash "$scripts/session-init.sh" --feature-slug feat --coverage --promote critical-high >/dev/null
  grep -q 'export CREW_PRD_AUDIT="report"' .scratch/feat/sprint.env
  grep -q 'export CREW_FIX_FINDINGS="high"' .scratch/feat/sprint.env
}

@test "every crew-afk body names the PRD audit setting" {
  for variant in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    grep -q -- '--prd-audit' "$(afk_variant "$variant")" || {
      echo "$variant does not mention the --prd-audit flag" >&2; return 1; }
  done
}

# --- Skip Behavior Tests ---

@test "prd-audit.sh skips when no PRD.md exists" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature/issues

  run bash "$AUDIT_SCRIPT" --mode report

  [ "$status" -eq 0 ]
  [[ "$output" == *"PRD audit: skipped"* ]]
}

@test "prd-audit.sh skip message includes reason" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature/issues

  run bash "$AUDIT_SCRIPT" --mode report

  [ "$status" -eq 0 ]
  [[ "$output" == *"no PRD.md found"* ]]
}

@test "prd-audit.sh outputs PRD path when PRD.md exists" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature
  echo "# PRD" > .scratch/test-feature/PRD.md

  run bash "$AUDIT_SCRIPT" --mode report

  [ "$status" -eq 0 ]
  # Must NOT output a skip message
  [[ "$output" != *"skipped"* ]]
  # Must output the PRD path so the orchestrator knows what to read
  [[ "$output" == *"PRD.md"* ]]
}

# --- No Dead Stub Tests ---

@test "prd-audit.sh does not contain 'not yet implemented'" {
  run grep -c "not yet implemented" "$AUDIT_SCRIPT"
  [ "$output" -eq 0 ]
}

@test "No script file body only reports 'not yet implemented'" {
  # Scan all scripts in skills/crew-afk/scripts/ for stub bodies
  for f in "$SCRIPT_DIR/skills/crew-afk/scripts/"*.sh; do
    count=$(grep -c "not yet implemented" "$f" 2>/dev/null || echo 0)
    if [ "$count" -gt 0 ]; then
      echo "Dead stub found in: $f"
      return 1
    fi
  done
}

# --- Model Tier Tests ---
#
# "The audit does not use haiku" policed a prose instruction to pick an agent tier. The step
# is `dispatchPlain()` on the prdAuditor's configured model now, so there is no tier for a
# body to get wrong — see tests/orchestrator/sprint.test.mjs.

# --- Documentation Format Tests ---
#
# The prompt lives in the script, not in the bodies: it is ~180 words that only matter once
# per sprint, and only when the audit runs. Printing it from the script is what keeps
# it out of every context window that never runs the step.
#
# `fix` reads only the closing fenced json, so the prompt must ask for one.

@test "the validation prompt is printed by the script, not carried in the bodies" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature
  echo "# PRD" > .scratch/test-feature/PRD.md

  run bash "$AUDIT_SCRIPT" --mode report
  [[ "$output" == *"Extract all requirements"* ]]
  [[ "$output" == *"✓ N covered"* ]]
  [[ "$output" == *"⚠ N partial"* ]]
  [[ "$output" == *"✗ N missing"* ]]
  [[ "$output" == *'"missing": [{"requirement"'* ]]

  for variant in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    if grep -q '✓ N covered' "$(afk_variant "$variant")"; then
      echo "$variant still inlines the validation prompt" >&2; return 1
    fi
  done
}

# --- Copilot Parity Tests ---
#
# "copilot.SKILL.md includes a Coverage validation section" was parity between prose bodies.
# The launcher forwards `--prd-audit` to the program (asserted above, for every launcher) and
# the program owns the step, so there is no section left to have.
