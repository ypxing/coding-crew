#!/usr/bin/env bats

# Tests for crew-afk coverage validation step

load helpers/render

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
COVERAGE_SCRIPT="$SCRIPT_DIR/skills/crew-afk/scripts/coverage-validation.sh"

# The claude body's structure assertions (a `### Coverage validation` section, its position
# between squash and cleanup, the `bash …coverage-validation.sh` call, who runs the prompt)
# lost their subject when claude became a launcher. Their code equivalent is
# tests/orchestrator/sprint.test.mjs, "coverage validation is opt-in, and runs between the
# squash and cleanup", which runs the step and asserts the order from the trace log. The
# copilot cutover retired the last of them — including "who runs the prompt", which was the
# `task` tool and is now `dispatchPlain()` in orchestrator/lib/dispatch.mjs.

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

@test "coverage-validation.sh script exists" {
  [ -f "$COVERAGE_SCRIPT" ]
}

# --- Opt-in Tests ---
#
# Coverage validation is a whole extra reasoning pass over the PRD, every closed issue and
# greps of the merged code, producing advisory output after every issue already passed its
# own acceptance-criteria gate. It cost 5–15k tokens a sprint for a report nothing acted on,
# so it now runs only when the sprint asked for it.

@test "coverage-validation.sh is opt-in: no --coverage, no validation" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature
  echo "# PRD" > .scratch/test-feature/PRD.md

  run bash "$COVERAGE_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]]
  [[ "$output" == *"--coverage"* ]]
  # The prompt must not be printed for a step that is not running.
  [[ "$output" != *"Extract all requirements"* ]]
}

@test "coverage-validation.sh honours CREW_COVERAGE from sprint.env" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature
  echo "# PRD" > .scratch/test-feature/PRD.md

  CREW_COVERAGE=1 run bash "$COVERAGE_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]]
}

@test "session-init records the --coverage flag in sprint.env" {
  # The flag is captured once, where the user's arguments arrive — not carried in the
  # orchestrator's head for the length of a sprint.
  scripts="$TEMP_DIR/scripts"
  mkdir -p "$scripts"
  cp "$SCRIPT_DIR/skills/crew-afk/scripts/"*.sh "$scripts/"
  cp "$SCRIPT_DIR/scripts/skill-utils/git-workflow/feature-branch-setup.sh" "$scripts/"
  mkdir -p .scratch/feat/issues/open
  echo "Status: ready-for-agent" > .scratch/feat/issues/open/01-a.md

  bash "$scripts/session-init.sh" --feature-slug feat >/dev/null
  grep -q 'export CREW_COVERAGE="0"' .scratch/feat/sprint.env

  bash "$scripts/session-init.sh" --feature-slug feat --coverage >/dev/null
  grep -q 'export CREW_COVERAGE="1"' .scratch/feat/sprint.env
}

@test "every crew-afk body states that coverage validation is opt-in" {
  for variant in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    grep -q -- '--coverage' "$(afk_variant "$variant")" || {
      echo "$variant does not mention the --coverage flag" >&2; return 1; }
  done
}

# --- Skip Behavior Tests ---

@test "coverage-validation.sh skips when no PRD.md exists" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature/issues

  run bash "$COVERAGE_SCRIPT" --coverage

  [ "$status" -eq 0 ]
  [[ "$output" == *"Coverage validation: skipped"* ]]
}

@test "coverage-validation.sh skip message includes reason" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature/issues

  run bash "$COVERAGE_SCRIPT" --coverage

  [ "$status" -eq 0 ]
  [[ "$output" == *"no PRD.md found"* ]]
}

@test "coverage-validation.sh outputs PRD path when PRD.md exists" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature
  echo "# PRD" > .scratch/test-feature/PRD.md

  run bash "$COVERAGE_SCRIPT" --coverage

  [ "$status" -eq 0 ]
  # Must NOT output a skip message
  [[ "$output" != *"skipped"* ]]
  # Must output the PRD path so the orchestrator knows what to read
  [[ "$output" == *"PRD.md"* ]]
}

# --- No Dead Stub Tests ---

@test "coverage-validation.sh does not contain 'not yet implemented'" {
  run grep -c "not yet implemented" "$COVERAGE_SCRIPT"
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
# "Coverage validation does not use haiku" policed a prose instruction to pick an agent
# tier. The step is `dispatchPlain()` on the sprint's own model now, so there is no tier for
# a body to get wrong — see tests/orchestrator/sprint.test.mjs.

# --- Documentation Format Tests ---
#
# The prompt lives in the script, not in the bodies: it is ~180 words that only matter once
# per sprint, and only when --coverage was passed. Printing it from the script is what keeps
# it out of every context window that never runs the step.

@test "the validation prompt is printed by the script, not carried in the bodies" {
  git checkout -q -b "feature/test-feature"
  mkdir -p .scratch/test-feature
  echo "# PRD" > .scratch/test-feature/PRD.md

  run bash "$COVERAGE_SCRIPT" --coverage
  [[ "$output" == *"Extract all requirements"* ]]
  [[ "$output" == *"✓ N covered"* ]]
  [[ "$output" == *"⚠ N partial"* ]]
  [[ "$output" == *"✗ N missing"* ]]

  for variant in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    if grep -q '✓ N covered' "$(afk_variant "$variant")"; then
      echo "$variant still inlines the validation prompt" >&2; return 1
    fi
  done
}

# --- Copilot Parity Tests ---
#
# "copilot.SKILL.md includes a Coverage validation section" was parity between prose bodies.
# The launcher forwards `--coverage` to the program (asserted above, for every launcher) and
# the program owns the step, so there is no section left to have.
