#!/usr/bin/env bats

# Structural checks on the crew-rework workflow: the gate precedes every use of the API key,
# and runs are serialised per PR.

WF="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/docs/templates/workflows/crew-rework.yml"

line_of() { grep -n -m1 -E "$1" "$WF" | cut -d: -f1; }

@test "workflow: the gate checks permission, same-repo and label" {
  gate=$(line_of 'id: gate')
  [ -n "$gate" ]
  sed -n "$gate,\$p" "$WF" | grep -q 'collaborators/.*permission'
  sed -n "$gate,\$p" "$WF" | grep -q 'headRepository'
  sed -n "$gate,\$p" "$WF" | grep -q 'crew-rework'
}

@test "workflow: the gate step comes before any step that uses the API key" {
  gate=$(line_of 'id: gate')
  first_key=$(line_of 'secrets\.ANTHROPIC_API_KEY')
  [ -n "$first_key" ]
  [ "$gate" -lt "$first_key" ]
}

@test "workflow: every step after the gate is conditional on it" {
  gate=$(line_of 'id: gate')
  total=$(tail -n +"$gate" "$WF" | grep -c '^      - name:')
  cond=$(tail -n +"$gate" "$WF" | grep -c "if: steps.gate.outputs.ok == 'true'")
  [ "$cond" -eq "$total" ]
}

@test "workflow: the API key is only referenced in a gated step" {
  n=$(grep -n 'secrets\.ANTHROPIC_API_KEY' "$WF" | wc -l)
  [ "$n" -eq 1 ]
  key=$(line_of 'secrets\.ANTHROPIC_API_KEY')
  step=$(head -n "$key" "$WF" | grep -n '^      - name:' | tail -1 | cut -d: -f1)
  sed -n "$step,${key}p" "$WF" | grep -q "steps.gate.outputs.ok == 'true'"
}

@test "workflow: has per-PR concurrency" {
  grep -q '^concurrency:' "$WF"
  grep -A2 '^concurrency:' "$WF" | grep -q 'group: crew-rework-.*\(pull_request.number\|issue.number\)'
}
