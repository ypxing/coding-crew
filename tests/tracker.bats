#!/usr/bin/env bats
# The tracker CLI's node:test files (tests/tracker/*.test.mjs), one `node --test` per file, so a
# failure names its file.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

run_node_test() {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  cd "$REPO_ROOT"
  run node --test "$1"
  if [ "$status" -ne 0 ]; then
    echo "$output" >&3
  fi
  [ "$status" -eq 0 ]
}

@test "tracker: body-format.test.mjs passes" { run_node_test tests/tracker/body-format.test.mjs; }
@test "tracker: tracker-cli-write.test.mjs passes" { run_node_test tests/tracker/tracker-cli-write.test.mjs; }
@test "tracker: tracker-cli.test.mjs passes" { run_node_test tests/tracker/tracker-cli.test.mjs; }
@test "tracker: tracker-config.test.mjs passes" { run_node_test tests/tracker/tracker-config.test.mjs; }
@test "tracker: tracker-factory.test.mjs passes" { run_node_test tests/tracker/tracker-factory.test.mjs; }
@test "tracker: tracker-github.test.mjs passes" { run_node_test tests/tracker/tracker-github.test.mjs; }
@test "tracker: tracker.test.mjs passes" { run_node_test tests/tracker/tracker.test.mjs; }

@test "tracker: every tests/tracker/*.test.mjs has a test above" {
  local f
  for f in "$REPO_ROOT"/tests/tracker/*.test.mjs; do
    grep -qF "run_node_test tests/tracker/$(basename "$f")" "$BATS_TEST_FILENAME" || {
      echo "not run: tests/tracker/$(basename "$f")" >&3; return 1; }
  done
}
