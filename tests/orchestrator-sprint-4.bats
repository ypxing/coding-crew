#!/usr/bin/env bats
# Slice 4 of the orchestrator's sprint suite, in a bats file of its own so CI's shard split
# can put each slice on a different runner; orchestrator.bats runs the rest of the suite.

load helpers/orchestrator-suite

@test "orchestrator: sprint suite slice 4 passes" {
  run_node_tests tests/orchestrator/sprint-4.test.mjs
}
