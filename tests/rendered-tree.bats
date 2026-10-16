#!/usr/bin/env bats

# The committed skills/ tree is the installed tree: every SKILL.md has its fragments expanded in place and
# every skill's scripts/<lib>/ is a copy of lib/<lib>/, both written by scripts/render-skill.sh. So any
# installer that copies skills/<name>/ — `npx skills add` included — installs working skills.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

# stale_files <root> — renders a copy of <root>'s render inputs and prints each file under skills/ that
# differs from <root>'s, in content or exec bit; exits 1 when any does.
stale_files() {
  local root="$1" copy="$BATS_TEST_TMPDIR/render-$RANDOM" out
  mkdir -p "$copy/scripts"
  cp "$root/scripts/render-skill.sh" "$copy/scripts/"
  cp "$root/registry.json" "$copy/"
  cp -Rp "$root/skills" "$root/lib" "$copy/"
  bash "$copy/scripts/render-skill.sh" || { echo "render-skill.sh failed"; return 1; }
  out=$(diff -rq "$root/skills" "$copy/skills" 2>&1)
  out+=$(diff <(cd "$root" && find skills -type f -perm -u+x | LC_ALL=C sort) \
    <(cd "$copy" && find skills -type f -perm -u+x | LC_ALL=C sort) | sed -n 's/^[<>] /exec bit differs: /p')
  [ -z "$out" ] || { printf '%s\n' "$out"; return 1; }
}

@test "the committed SKILL.md bodies and scripts/<lib> copies are what render-skill.sh writes" {
  run stale_files "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "stale — run bash scripts/render-skill.sh and commit the result:"; echo "$output"; return 1; }
}

@test "the staleness check fails on a planted change in a lib copy or between fragment markers, naming the file" {
  local T="$BATS_TEST_TMPDIR/planted"
  mkdir -p "$T/scripts"
  cp "$REPO_ROOT/scripts/render-skill.sh" "$T/scripts/"
  cp "$REPO_ROOT/registry.json" "$T/"
  cp -Rp "$REPO_ROOT/skills" "$REPO_ROOT/lib" "$T/"
  echo "// planted" >> "$T/skills/solve-issue/scripts/tracker/cli.mjs"
  run stale_files "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/solve-issue/scripts/tracker/cli.mjs"* ]] || { echo "$output"; return 1; }

  cp "$REPO_ROOT/skills/solve-issue/scripts/tracker/cli.mjs" "$T/skills/solve-issue/scripts/tracker/cli.mjs"
  sed -i.bak '/^<!-- fragment:tracker-configuration -->$/a\
planted line' "$T/skills/to-prd/SKILL.md" && rm "$T/skills/to-prd/SKILL.md.bak"
  run stale_files "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/to-prd/SKILL.md"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"cli.mjs"* ]] || { echo "$output"; return 1; }
}

@test "npx skills add <checkout> --all -g installs every skill working, into a temp HOME" {
  command -v npx >/dev/null 2>&1 || skip "npx is not on PATH: the npx skills route needs Node's npx"
  local home="$BATS_TEST_TMPDIR/home" n
  mkdir -p "$home"
  run env DISABLE_TELEMETRY=1 HOME="$home" npm_config_cache="$BATS_TEST_TMPDIR/npm-cache" \
    npx -y skills@1.7.2 add "$REPO_ROOT" --all -g -y
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  n=$(find "$home/.agents/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$n" -eq "$(jq '.skills | length' "$REPO_ROOT/registry.json")" ] || { ls "$home/.agents/skills"; return 1; }
  [ "$n" -eq 17 ]
  ! grep -l '{{' "$home"/.agents/skills/*/SKILL.md || false
  run env HOME="$home" bash -c "cd '$BATS_TEST_TMPDIR' && node '$home/.agents/skills/solve-issue/scripts/tracker/cli.mjs' config"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"tracker=local"* ]]
}
