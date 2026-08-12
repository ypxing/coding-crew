#!/usr/bin/env bats
# Sharding is only safe if it is a partition: a file that falls out of every shard is a
# test that stopped running, and CI would go green having never executed it. Assert the
# union and the disjointness, not the balance.

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export SHARD="$SCRIPT_DIR/scripts/ci-test-shard.sh"
  export TEMP_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TEMP_DIR"
}

_all_test_files() {
  ls "$SCRIPT_DIR"/tests/*.bats | sort
}

@test "shard script exists and is executable" {
  [ -f "$SHARD" ]
  [ -x "$SHARD" ]
}

@test "1/1 is every test file" {
  run bash "$SHARD" 1 1
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | sort > "$TEMP_DIR/got"
  _all_test_files > "$TEMP_DIR/want"
  run diff "$TEMP_DIR/want" "$TEMP_DIR/got"
  [ "$status" -eq 0 ]
}

@test "shards of 4 partition the suite: union is complete and nothing is duplicated" {
  local i
  : > "$TEMP_DIR/union"
  for i in 1 2 3 4; do
    run bash "$SHARD" "$i" 4
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    printf '%s\n' "$output" >> "$TEMP_DIR/union"
  done

  sort "$TEMP_DIR/union" > "$TEMP_DIR/got"
  _all_test_files > "$TEMP_DIR/want"
  run diff "$TEMP_DIR/want" "$TEMP_DIR/got"
  [ "$status" -eq 0 ]

  # No file in two shards: sorted union must equal sorted-unique union.
  run bash -c "sort '$TEMP_DIR/union' | uniq -d"
  [ -z "$output" ]
}

@test "sharding is deterministic across runs" {
  run bash "$SHARD" 2 4
  [ "$status" -eq 0 ]
  local first="$output"
  run bash "$SHARD" 2 4
  [ "$output" = "$first" ]
}

@test "no shard carries more than half the suite's tests at 4 shards" {
  local total_tests shard_tests i
  total_tests=$(grep -ch '^@test' "$SCRIPT_DIR"/tests/*.bats | awk '{s+=$1} END {print s}')
  for i in 1 2 3 4; do
    shard_tests=$(bash "$SHARD" "$i" 4 | xargs grep -ch '^@test' | awk '{s+=$1} END {print s+0}')
    [ "$shard_tests" -lt "$(( total_tests / 2 ))" ]
  done
}

@test "bad arguments are rejected rather than silently running nothing" {
  run bash "$SHARD"
  [ "$status" -eq 2 ]
  run bash "$SHARD" 5 4
  [ "$status" -eq 2 ]
  [[ "$output" == *"out of range"* ]]
  run bash "$SHARD" 0 4
  [ "$status" -eq 2 ]
  run bash "$SHARD" x 4
  [ "$status" -eq 2 ]
}

@test "CI declares a complete set of shards for every shard count it uses" {
  local ci="$SCRIPT_DIR/.github/workflows/ci.yml"
  [ -f "$ci" ]

  grep -oE 'shard: "[0-9]+/[0-9]+"' "$ci" | grep -oE '[0-9]+/[0-9]+' | sort -u > "$TEMP_DIR/shards"
  [ -s "$TEMP_DIR/shards" ]

  # For every declared total N, indices 1..N must all be present. A matrix that lists
  # 1/4, 2/4 and 4/4 would run three shards and silently never run shard 3's files.
  local total idx
  for total in $(cut -d/ -f2 "$TEMP_DIR/shards" | sort -u); do
    for idx in $(seq 1 "$total"); do
      run grep -qx "$idx/$total" "$TEMP_DIR/shards"
      [ "$status" -eq 0 ]
    done
  done
}
