#!/usr/bin/env bats

# crew-grill Phase 1 question quality: the two-gate filter.
#
# Observed failure: the grill asked the user things a staff engineer would have
# looked up — repo facts, library behaviour, ecosystem convention. The routing
# table could not catch those, because routing only decides *who owns a fork*;
# it never asks whether the node is a fork at all. Gate 1 (competence) is that
# missing question, and it must run before Gate 2 (consequence).

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export GRILL="$SCRIPT_DIR/skills/crew-grill/SKILL.md"
}

@test "G1: crew-grill declares both question gates" {
  grep -q 'Gate 1' "$GRILL"
  grep -q 'Gate 2' "$GRILL"
}

@test "G1: the competence gate precedes the consequence gate" {
  local g1 g2
  g1=$(grep -n '^### Gate 1' "$GRILL" | head -1 | cut -d: -f1)
  g2=$(grep -n '^### Gate 2' "$GRILL" | head -1 | cut -d: -f1)
  [ -n "$g1" ]
  [ -n "$g2" ]
  [ "$g1" -lt "$g2" ]
}

@test "G1: the competence gate names every disqualifier class" {
  # Each bullet kills a category of question the user should never have seen.
  for class in Discoverable 'Already answered' Testable Conventional Analysis Deferrable Rubber-stamp; do
    grep -qi -- "$class" "$GRILL" || {
      echo "missing disqualifier class: $class"
      return 1
    }
  done
}

@test "G1: homework is not scoped to the codebase alone" {
  # The original text said "look up anything discoverable in the codebase",
  # which licensed "the repo is silent, so I'll ask the user" for anything
  # external. Vendor docs and the open web must be in scope.
  grep -qi 'open web' "$GRILL"
  grep -qi "vendor's documentation\|vendor documentation" "$GRILL"
  ! grep -qi 'discoverable in the codebase' "$GRILL"
}

@test "G1: third-party behaviour is never routed to the user" {
  grep -qi 'third-party behaviour' "$GRILL"
  grep -qi 'never the user' "$GRILL"
}

@test "G1: the question template carries a checked: receipt" {
  # The receipt is what makes Gate 1 auditable from the transcript: a question
  # with nothing to cite is research that has not happened yet.
  grep -q 'checked:' "$GRILL"
  grep -qi "isn't ready to be asked" "$GRILL"
}

@test "G1: escalation cannot resurrect a node that failed Gate 1" {
  # "Escalation is cheap" trades between Silent/Notify/Ask only. Left unscoped
  # it reads as a licence to ask anything borderline, undoing Gate 1.
  grep -qi 'never resurrects a node that failed Gate 1' "$GRILL"
}

@test "G1: a legitimate zero-question round is not treated as a smell" {
  # With Gate 1 working, quiet rounds become normal; the old smell rule would
  # otherwise push the model back toward asking to prove it was grilling.
  grep -qi 'legitimate zero' "$GRILL"
}

@test "G1: Phase 1 hands established facts and citations to the PRD" {
  # Gate 1 research is expensive; if the summary drops it, the implementing
  # agent re-derives or re-asks it.
  grep -qi 'facts you established' "$GRILL"
  grep -qi 'established facts and their citations' "$GRILL"
}

@test "G1: the question budget is a ceiling, not a target" {
  grep -qi 'budget, not a target' "$GRILL"
  grep -qi 'drop its weakest question' "$GRILL"
}
