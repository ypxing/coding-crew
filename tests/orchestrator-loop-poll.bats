#!/usr/bin/env bats
# The orchestrator's sprint suite, topic "loop-poll" (tests/orchestrator/loop-poll.test.mjs), in a bats
# file of its own so CI's shard split can put each topic on a different runner; orchestrator.bats
# runs the rest of the suite.

load helpers/orchestrator-suite

@test "orchestrator: sprint suite topic loop-poll passes" {
  run_node_tests tests/orchestrator/loop-poll.test.mjs
}
