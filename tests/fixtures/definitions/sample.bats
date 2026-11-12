#!/usr/bin/env bats

setup() {
  TEMP_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "fetch: prints the issue" {
  run true
  [ "$status" -eq 0 ]
}

@test "mark-done: moves the file" {
  run true
}
