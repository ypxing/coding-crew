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

@test "P2: the do-least option is scoped to build-size questions, not fact questions" {
  # A question like "which GitLab tier are you on?" has no do-least option.
  grep -qi 'decides how much to build' "$GRILL"
}

@test "P4: crew-grill carries the cut list into the PRD's Out of Scope" {
  grep -qi "cut list goes to Out of Scope" "$GRILL"
}

@test "P1: the root section sits before the rounds, and the gates keep their own heading" {
  local root rounds
  root=$(grep -n '^### Root' "$GRILL" | head -1 | cut -d: -f1)
  rounds=$(grep -n '^### Rounds and gates' "$GRILL" | head -1 | cut -d: -f1)
  [ -n "$rounds" ]
  [ "$root" -lt "$rounds" ]
  # The gates' intro paragraph belongs under the rounds heading, not under Root.
  [ "$(awk '/^### Root/{f=1;next} /^### /{f=0} f' "$GRILL" | grep -c 'Every frontier node passes two gates')" -eq 0 ]
}

@test "P4: the subtraction pass follows dependency chains to the problem, not to a parent component" {
  # Eval: with a user-approved Action, every follow-on "broke" its parent, so the
  # pass kept the whole chain. A dependency on another component is not a reason.
  grep -qi '"Another component needs it" is not an answer' "$GRILL"
  grep -qi '"Another component needs it" is not an answer' "$BRAINSTORM"
  grep -qi 'total price' "$GRILL"
}

@test "P4: a cut's 'nothing breaks' is a checked, cited fact" {
  # Eval: a run cut a needed re-bump on the false claim that an existing test caught it.
  grep -qi '"Nothing breaks" is a claim of fact' "$GRILL"
  grep -qi '"Nothing breaks" is a claim to check' "$BRAINSTORM"
}

@test "P5: size is justified by the problem or by structure, not minimised for its own sake" {
  # Intent: well-architected, not overengineered. A shared helper that removes
  # duplication must survive the subtraction pass; a hypothetical need must not.
  grep -qi 'unjustified\*\* size is not' "$GRILL"
  grep -qi 'unjustified\*\* size is not' "$BRAINSTORM"
  grep -qi 'no duplicated logic' "$GRILL"
  grep -qi 'need nobody has yet' "$GRILL"
  grep -qi 'structural property of what is built now' "$GRILL"
  grep -qi 'structural property of what is built now' "$BRAINSTORM"
}
