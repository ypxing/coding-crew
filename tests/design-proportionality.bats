#!/usr/bin/env bats

# crew-grill / crew-brainstorm: keep the design proportionate to the problem.
#
# Observed failure: a grill handed a menu of candidate solutions chose among them
# without ever sizing the problem (a few mechanical merge conflicts a month, ~5
# minutes each by hand). Recommendations rested on completeness ("(a) can't fix
# #99"), one choice spawned six Silent follow-on decisions the user never saw,
# and nothing pruned the tree — the PRD came out an Action, a selector, a label
# protocol and a CI re-trigger where a CI check and a hand-run script sufficed.

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export GRILL="$SCRIPT_DIR/skills/crew-grill/SKILL.md"
  export BRAINSTORM="$SCRIPT_DIR/skills/crew-brainstorm/SKILL.md"
}

@test "P1: both skills size the problem before any solution" {
  grep -qi 'problem size\|size the problem' "$GRILL"
  grep -qi 'size the problem' "$BRAINSTORM"
}

@test "P1: crew-grill sizes the problem before its question gates" {
  local root g1
  root=$(grep -n '^### Root' "$GRILL" | head -1 | cut -d: -f1)
  g1=$(grep -n '^### Gate 1' "$GRILL" | head -1 | cut -d: -f1)
  [ -n "$root" ]
  [ "$root" -lt "$g1" ]
}

@test "P1: candidate solutions are inputs, not the menu" {
  grep -qi 'inputs to this tree, not its frontier' "$GRILL"
  grep -qi 'inputs, not the menu' "$BRAINSTORM"
}

@test "P2: every option set includes the do-least option" {
  grep -qi 'do-least option' "$GRILL"
  grep -qi 'do-least option' "$BRAINSTORM"
}

@test "P2: completeness alone does not justify a larger option" {
  grep -qi "doesn't cover every case" "$GRILL"
  grep -qi "doesn't cover every case" "$BRAINSTORM"
}

@test "P3: an option names the follow-on components it drags in" {
  grep -qi 'follow-on components' "$GRILL"
  grep -qi 'follow-on components' "$BRAINSTORM"
}

@test "P4: both skills run a subtraction pass and show what was cut" {
  grep -qi 'subtraction pass' "$GRILL"
  grep -qi 'subtraction pass' "$BRAINSTORM"
  grep -qi 'cut list' "$GRILL"
}

@test "P4: crew-grill's subtraction pass runs before the Phase 1 summary" {
  local sub summ
  sub=$(grep -n 'subtraction pass' "$GRILL" | head -1 | cut -d: -f1)
  summ=$(grep -n 'Summarize all implementation decisions' "$GRILL" | head -1 | cut -d: -f1)
  [ "$sub" -lt "$summ" ]
}
