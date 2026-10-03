#!/usr/bin/env bats
# The orchestrator's sprint suite, topic "feature-areas" (tests/orchestrator/sprint-feature-areas.test.mjs), in a bats
# file of its own so CI's shard split can put each topic on a different runner; orchestrator.bats
# runs the rest of the suite.

load helpers/orchestrator-suite

@test "orchestrator: sprint suite topic feature-areas passes" {
  run_node_tests tests/orchestrator/sprint-feature-areas.test.mjs
}
