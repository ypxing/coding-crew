#!/usr/bin/env bats
# Slice 2 of the orchestrator's sprint suite, in a bats file of its own so CI's shard split
# can put each slice on a different runner; orchestrator.bats runs the rest of the suite.

load helpers/orchestrator-suite

@test "orchestrator: sprint suite slice 2 passes" {
  run_node_tests tests/orchestrator/sprint-2.test.mjs
}
