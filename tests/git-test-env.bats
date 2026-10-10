#!/usr/bin/env bats

# setup_suite.bash turns off git's detached auto-maintenance for every test: one still writing
# .git/objects after its git command returned made teardowns' rm -rf fail in CI.

setup() { TEMP_DIR=$(mktemp -d); }
teardown() { rm -rf "$TEMP_DIR"; }

@test "a scratch repo has no background gc or maintenance, even with HOME swapped" {
  export HOME="$TEMP_DIR/home"; mkdir -p "$HOME"
  git init -q "$TEMP_DIR/repo"
  [ "$(git -C "$TEMP_DIR/repo" config gc.auto)" = 0 ]
  [ "$(git -C "$TEMP_DIR/repo" config maintenance.auto)" = false ]
}

@test "an inherited GIT_CONFIG_COUNT list is extended, not replaced" {
  run env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=crew.inherited GIT_CONFIG_VALUE_0=kept bash -c \
    '. "$1" && setup_suite && git config crew.inherited && git config maintenance.auto' _ \
    "$BATS_TEST_DIRNAME/setup_suite.bash"
  [ "$status" -eq 0 ]
  [ "$output" = "kept
false" ]
}
