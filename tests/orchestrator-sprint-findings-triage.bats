#!/usr/bin/env bats
# The orchestrator's sprint suite, topic "findings-triage" (tests/orchestrator/sprint-findings-triage.test.mjs), in a bats
# file of its own so CI's shard split can put each topic on a different runner; orchestrator.bats
# runs the rest of the suite.

load helpers/orchestrator-suite

@test "orchestrator: sprint suite topic findings-triage passes" {
  run_node_tests tests/orchestrator/sprint-findings-triage.test.mjs
}
