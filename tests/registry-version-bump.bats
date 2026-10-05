#!/usr/bin/env bats

# install.sh --update reinstalls an agent/skill only when registry.json's version differs from the
# installed one. Rule D4: an entry this branch changed (its registry fields, or any file it ships)
# must carry a version strictly above origin/main's — otherwise two branches bumping the same entry
# to the same number both pass and the second merge ships new files under an old version.
# "Changed" is measured against the merge-base with origin/main, so an entry main bumped and the
# branch never touched is fine.

load helpers/version-gate

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIX="$BATS_TEST_DIRNAME/fixtures/version-gate"
}

@test "fixture: #100 (crew-afk 2.7.1) over a97bf5c (2.6.0) passes" {
  run version_gate_failures "$FIX/bump-ok/base.json" "$FIX/bump-ok/branch.json" "$FIX/bump-ok/main.json" "$FIX/bump-ok/changed.txt"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fixture: crew-afk 2.6.2 against main's 2.7.1 fails, naming entry and both versions" {
  run version_gate_failures "$FIX/stale/base.json" "$FIX/stale/branch.json" "$FIX/stale/main.json" "$FIX/stale/changed.txt"
  [[ "$output" == *"skills.crew-afk"* ]]
  [[ "$output" == *"2.6.2"* ]]
  [[ "$output" == *"2.7.1"* ]]
}

@test "shipped-file change with version equal to main's fails" {
  cp "$FIX/bump-ok/base.json" "$BATS_TEST_TMPDIR/r.json"
  echo "skills/crew-afk/scripts/x.sh" > "$BATS_TEST_TMPDIR/c.txt"
  run version_gate_failures "$BATS_TEST_TMPDIR/r.json" "$BATS_TEST_TMPDIR/r.json" "$BATS_TEST_TMPDIR/r.json" "$BATS_TEST_TMPDIR/c.txt"
  [[ "$output" == *"skills.crew-afk"* ]]
  [[ "$output" == *"2.6.0"* ]]
}

@test "registry-field-only change with unchanged version fails" {
  jq '.skills["crew-afk"].description = "changed"' "$FIX/bump-ok/base.json" > "$BATS_TEST_TMPDIR/b.json"
  : > "$BATS_TEST_TMPDIR/c.txt"
  run version_gate_failures "$FIX/bump-ok/base.json" "$BATS_TEST_TMPDIR/b.json" "$FIX/bump-ok/base.json" "$BATS_TEST_TMPDIR/c.txt"
  [[ "$output" == *"skills.crew-afk"* ]]
}

@test "entry absent on main, or unchanged by the branch while main bumped it, passes" {
  jq 'del(.skills["crew-afk"])' "$FIX/bump-ok/base.json" > "$BATS_TEST_TMPDIR/m.json"
  echo "skills/crew-afk/scripts/x.sh" > "$BATS_TEST_TMPDIR/c.txt"
  run version_gate_failures "$FIX/bump-ok/base.json" "$FIX/bump-ok/base.json" "$BATS_TEST_TMPDIR/m.json" "$BATS_TEST_TMPDIR/c.txt"
  [ -z "$output" ]
  jq '.skills["crew-afk"].version = "9.9.9"' "$FIX/bump-ok/base.json" > "$BATS_TEST_TMPDIR/m.json"
  : > "$BATS_TEST_TMPDIR/c.txt"
  run version_gate_failures "$FIX/bump-ok/base.json" "$FIX/bump-ok/base.json" "$BATS_TEST_TMPDIR/m.json" "$BATS_TEST_TMPDIR/c.txt"
  [ -z "$output" ]
}

@test "a path that only contains a shipped directory's name further down is not a change to it" {
  cp "$FIX/bump-ok/base.json" "$BATS_TEST_TMPDIR/r.json"
  echo "tests/skills/crew-afk/scripts/x.sh" > "$BATS_TEST_TMPDIR/c.txt"
  run version_gate_failures "$BATS_TEST_TMPDIR/r.json" "$BATS_TEST_TMPDIR/r.json" "$BATS_TEST_TMPDIR/r.json" "$BATS_TEST_TMPDIR/c.txt"
  [ -z "$output" ]
}

@test "registry.json versions sit strictly above origin/main's for every entry this branch changed" {
  git -C "$REPO_ROOT" rev-parse --verify -q origin/main >/dev/null || skip "origin/main was not found"
  local mb
  mb=$(git -C "$REPO_ROOT" merge-base HEAD origin/main) || skip "origin/main was not found (no merge-base)"
  git -C "$REPO_ROOT" show "$mb:registry.json" > "$BATS_TEST_TMPDIR/base.json"
  git -C "$REPO_ROOT" show "origin/main:registry.json" > "$BATS_TEST_TMPDIR/main.json"
  git -C "$REPO_ROOT" diff --name-only "$mb" > "$BATS_TEST_TMPDIR/changed.txt"
  run version_gate_failures "$BATS_TEST_TMPDIR/base.json" "$REPO_ROOT/registry.json" "$BATS_TEST_TMPDIR/main.json" "$BATS_TEST_TMPDIR/changed.txt"
  if [ -n "$output" ]; then
    printf 'install.sh --update would skip these (version not above origin/main):\n%s\n' "$output" >&2
    return 1
  fi
}
