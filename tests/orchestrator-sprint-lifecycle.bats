#!/usr/bin/env bats
# The orchestrator's sprint suite, topic "lifecycle" (tests/orchestrator/sprint-lifecycle.test.mjs), in a bats
# file of its own so CI's shard split can put each topic on a different runner; orchestrator.bats
# runs the rest of the suite.

load helpers/orchestrator-suite

@test "orchestrator: sprint suite topic lifecycle passes" {
  run_node_tests tests/orchestrator/sprint-lifecycle.test.mjs
}
