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

# A PATH of every command but bats, and a local bats-core whose v1.13.0 tag ships the fake bats.
_no_bats_path() {
  local d f
  mkdir -p "$TEMP_DIR/nobats"
  IFS=: read -ra dirs <<< "$PATH"
  for d in "${dirs[@]}"; do
    for f in "$d"/*; do
      [[ -x "$f" && "${f##*/}" != bats && ! -e "$TEMP_DIR/nobats/${f##*/}" ]] && ln -s "$f" "$TEMP_DIR/nobats/${f##*/}"
    done
  done
  mkdir -p "$TEMP_DIR/bats-core/bin"
  cp "$BATS" "$TEMP_DIR/bats-core/bin/bats"
  git -C "$TEMP_DIR/bats-core" init -q
  git -C "$TEMP_DIR/bats-core" add -A
  git -C "$TEMP_DIR/bats-core" -c user.name=t -c user.email=t@t commit -q -m bats
  git -C "$TEMP_DIR/bats-core" tag v1.13.0
}

@test "with no bats on PATH it clones the pinned bats-core outside the tree, once" {
  _stub a.bats 1
  _no_bats_path
  export CI_BATS_REPO="file://$TEMP_DIR/bats-core" XDG_CACHE_HOME="$TEMP_DIR/cache"
  PATH="$TEMP_DIR/nobats" run env -u BATS bash "$RUNNER" "$TEMP_DIR/a.bats"
  [ "$status" -eq 0 ]
  [ "$(cat "$STARTS")" = a.bats ]
  [ -x "$TEMP_DIR/cache/coding-crew/bats-core-v1.13.0/bin/bats" ]
  rm -rf "$TEMP_DIR/bats-core"
  PATH="$TEMP_DIR/nobats" run env -u BATS bash "$RUNNER" "$TEMP_DIR/a.bats"
  [ "$status" -eq 0 ]
}

@test "with no bats on PATH a failed clone says so" {
  _stub a.bats 1
  _no_bats_path
  export CI_BATS_REPO="file://$TEMP_DIR/missing" XDG_CACHE_HOME="$TEMP_DIR/cache"
  PATH="$TEMP_DIR/nobats" run env -u BATS bash "$RUNNER" "$TEMP_DIR/a.bats"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no bats on PATH, and cloning bats-core v1.13.0 failed"* ]]
}
