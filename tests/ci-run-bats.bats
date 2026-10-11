#!/usr/bin/env bats
# A fake bats binary records the order files start in; one job at a time makes that order the
# queue order ci-run-bats.sh built.

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export RUNNER="$SCRIPT_DIR/scripts/ci-run-bats.sh"
  export TEMP_DIR=$(mktemp -d)
  export STARTS="$TEMP_DIR/starts"
  : > "$STARTS"
  cat > "$TEMP_DIR/fake-bats" <<'SH'
#!/usr/bin/env bash
f="${!#}"
basename "$f" >> "$STARTS"
echo "ran $(basename "$f")"
SH
  chmod +x "$TEMP_DIR/fake-bats"
  export BATS="$TEMP_DIR/fake-bats"
  export CI_BATS_JOBS=1
  export CI_SHARD_WEIGHTS="$TEMP_DIR/weights.tsv"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# _stub <name> <@test count>
_stub() {
  local i
  : > "$TEMP_DIR/$1"
  for ((i = 0; i < $2; i++)); do echo "@test \"t$i\" { true; }" >> "$TEMP_DIR/$1"; done
}

@test "files start heaviest first by the weights file" {
  _stub a.bats 1; _stub b.bats 1; _stub c.bats 1
  printf '# comment\n5\ta.bats\n50\tb.bats\n20\tc.bats\n' > "$CI_SHARD_WEIGHTS"

  run bash "$RUNNER" "$TEMP_DIR/a.bats" "$TEMP_DIR/b.bats" "$TEMP_DIR/c.bats"
  [ "$status" -eq 0 ]
  [ "$(cat "$STARTS")" = "$(printf 'b.bats\nc.bats\na.bats')" ]
}

@test "output prints in the order the files were given, not the order they ran" {
  _stub a.bats 1; _stub b.bats 1; _stub c.bats 1
  printf '5\ta.bats\n50\tb.bats\n20\tc.bats\n' > "$CI_SHARD_WEIGHTS"

  run bash "$RUNNER" "$TEMP_DIR/a.bats" "$TEMP_DIR/b.bats" "$TEMP_DIR/c.bats"
  [ "$status" -eq 0 ]
  run grep -oE '^(::group::[^ ]*|ran .*)' <<< "$output"
  [ "$output" = "$(printf '::group::%s\nran a.bats\n::group::%s\nran b.bats\n::group::%s\nran c.bats' \
    "$TEMP_DIR/a.bats" "$TEMP_DIR/b.bats" "$TEMP_DIR/c.bats")" ]
}

@test "a file with no row is weighted 5 per @test" {
  _stub few.bats 2; _stub many.bats 9; _stub listed.bats 1
  printf '30\tlisted.bats\n' > "$CI_SHARD_WEIGHTS"

  run bash "$RUNNER" "$TEMP_DIR/few.bats" "$TEMP_DIR/listed.bats" "$TEMP_DIR/many.bats"
  [ "$status" -eq 0 ]
  [ "$(cat "$STARTS")" = "$(printf 'many.bats\nlisted.bats\nfew.bats')" ]
}

@test "a missing weights file falls back to @test counts without an error" {
  _stub one.bats 1; _stub three.bats 3; _stub none.bats 0
  rm -f "$CI_SHARD_WEIGHTS"

  run bash "$RUNNER" "$TEMP_DIR/none.bats" "$TEMP_DIR/one.bats" "$TEMP_DIR/three.bats"
  [ "$status" -eq 0 ]
  [[ "$output" != *"No such file"* ]]
  [ "$(cat "$STARTS")" = "$(printf 'three.bats\none.bats\nnone.bats')" ]
}

@test "a failing file still fails the run" {
  _stub a.bats 1
  printf '#!/usr/bin/env bash\nexit 1\n' > "$BATS"
  run bash "$RUNNER" "$TEMP_DIR/a.bats"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed files (1)"* ]]
}
