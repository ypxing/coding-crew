#!/usr/bin/env bats

# The committed skills/ tree is the installed tree: every SKILL.md has its fragments expanded in place by
# scripts/render-skill.sh, and every skill's scripts/<lib> is a committed link to ../../../lib/<lib> that
# each installer copies through. So any installer that copies skills/<name>/ — `npx skills add` included —
# installs working skills, each library a real directory.

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
  # Regular files only: macOS diff -r follows the scripts/<lib> links into lib/ and reports a directory loop.
  out=$(diff <(cd "$root" && find skills -type f | LC_ALL=C sort) <(cd "$copy" && find skills -type f | LC_ALL=C sort) |
    sed -n 's/^[<>] /only on one side: /p')
  while IFS= read -r f; do
    [ ! -f "$copy/$f" ] || cmp -s "$root/$f" "$copy/$f" || out+=$'\n'"$f"
  done < <(cd "$root" && find skills -type f)
  out+=$(diff <(cd "$root" && find skills -type f -perm -u+x | LC_ALL=C sort) \
    <(cd "$copy" && find skills -type f -perm -u+x | LC_ALL=C sort) | sed -n 's/^[<>] /exec bit differs: /p')
  [ -z "$out" ] || { printf '%s\n' "$out"; return 1; }
}

@test "the committed SKILL.md bodies are what render-skill.sh writes" {
  run stale_files "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "stale — run bash scripts/render-skill.sh and commit the result:"; echo "$output"; return 1; }
}

@test "the staleness check fails on a planted line between fragment markers, naming the file" {
  local T="$BATS_TEST_TMPDIR/planted"
  mkdir -p "$T/scripts"
  cp "$REPO_ROOT/scripts/render-skill.sh" "$T/scripts/"
  cp "$REPO_ROOT/registry.json" "$T/"
  cp -Rp "$REPO_ROOT/skills" "$REPO_ROOT/lib" "$T/"
  sed -i.bak '/^<!-- fragment:tracker-configuration -->$/a\
planted line' "$T/skills/to-prd/SKILL.md" && rm "$T/skills/to-prd/SKILL.md.bak"
  run stale_files "$T"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skills/to-prd/SKILL.md"* ]] || { echo "$output"; return 1; }
  # The renderer leaves the links alone.
  [ "$(readlink "$T/skills/coding-crew-lib/scripts/tracker")" = "../../../lib/tracker" ]
}

# lib_link_problems <root> — prints each problem with coding-crew-lib/scripts/<lib>, for every library under
# <root>/lib, that is not a link to ../../../lib/<lib> resolving to a directory, and each other skill that has a
# scripts/<lib> of its own; exits 1 when any does.
lib_link_problems() {
  local root="$1" dir lib p link out=""
  for p in "$root/lib"/*/; do
    lib=$(basename "$p")
    link="$root/skills/coding-crew-lib/scripts/$lib"
    if [ ! -L "$link" ]; then out+="coding-crew-lib: scripts/$lib is not a symlink"$'\n'
    elif [ "$(readlink "$link")" != "../../../lib/$lib" ]; then
      out+="coding-crew-lib: scripts/$lib links to $(readlink "$link"), not ../../../lib/$lib"$'\n'
    elif [ ! -d "$link" ]; then out+="coding-crew-lib: scripts/$lib does not resolve to a directory"$'\n'
    fi
  done
  for p in "$root/skills"/*/; do
    dir=$(basename "$p")
    [ "$dir" != coding-crew-lib ] || continue
    for link in "$p"scripts/*; do
      lib=$(basename "$link")
      if [ -d "$root/lib/$lib" ] || { [ -L "$link" ] && [[ "$(readlink "$link")" == *lib/* ]]; }; then
        out+="$dir: scripts/$lib exists, but libraries live only in coding-crew-lib"$'\n'
      fi
    done
  done
  [ -z "$out" ] || { printf '%s' "$out"; return 1; }
}

@test "coding-crew-lib's scripts/<lib> is a link to ../../../lib/<lib> for every library, and no other skill has one" {
  run lib_link_problems "$REPO_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "the link-shape check fails, naming the skill, on a missing, real or retargeted library link, or a per-skill one" {
  local T="$BATS_TEST_TMPDIR/links" link
  mkdir -p "$T"
  cp -Rp "$REPO_ROOT/skills" "$REPO_ROOT/lib" "$T/"
  link="$T/skills/coding-crew-lib/scripts/tracker"

  rm "$link"
  run lib_link_problems "$T"
  [ "$status" -eq 1 ] && [[ "$output" == *"coding-crew-lib: scripts/tracker is not a symlink"* ]] || { echo "$output"; return 1; }

  cp -R "$T/lib/tracker" "$link"
  run lib_link_problems "$T"
  [ "$status" -eq 1 ] && [[ "$output" == *"coding-crew-lib: scripts/tracker is not a symlink"* ]] || { echo "$output"; return 1; }

  rm -r "$link" && ln -s ../../../lib/checks "$link"
  run lib_link_problems "$T"
  [ "$status" -eq 1 ] && [[ "$output" == *"coding-crew-lib: scripts/tracker links to ../../../lib/checks"* ]] || { echo "$output"; return 1; }

  rm "$link" && ln -s ../../../lib/tracker "$link"
  run lib_link_problems "$T"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  mkdir -p "$T/skills/to-prd/scripts" && ln -s ../../../lib/checks "$T/skills/to-prd/scripts/checks"
  run lib_link_problems "$T"
  [ "$status" -eq 1 ] && [[ "$output" == *"to-prd: scripts/checks exists, but libraries live only in coding-crew-lib"* ]] || { echo "$output"; return 1; }
}

@test "npx skills add <checkout> --all -g installs every skill working, into a temp HOME" {
  command -v npx >/dev/null 2>&1 || skip "npx is not on PATH: the npx skills route needs Node's npx"
  local home="$BATS_TEST_TMPDIR/home" n
  mkdir -p "$home"
  # env -i: skills builds some global dirs from XDG_CONFIG_HOME, CLAUDE_CONFIG_DIR and the like, not HOME,
  # so any of them inherited would link skills into the developer's real config, dangling after the test.
  run env -i PATH="$PATH" HOME="$home" DISABLE_TELEMETRY=1 npm_config_cache="$BATS_TEST_TMPDIR/npm-cache" \
    npx -y skills@1.7.2 add "$REPO_ROOT" --all -g -y
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  n=$(find "$home/.agents/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  [ "$n" -eq "$(jq '.skills | length' "$REPO_ROOT/registry.json")" ] || { ls "$home/.agents/skills"; return 1; }
  [ "$n" -eq 17 ]
  ! grep -l '{{' "$home"/.agents/skills/*/SKILL.md || false
  git init -q "$BATS_TEST_TMPDIR/project"
  run env HOME="$home" bash -c "cd '$BATS_TEST_TMPDIR/project' && node '$home/.agents/skills/solve-issue/scripts/tracker/cli.mjs' config"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"tracker=local"* ]]
  # The committed scripts/tracker is a link; the installed one is the directory it points to.
  [ -d "$home/.agents/skills/solve-issue/scripts/tracker" ] && [ ! -L "$home/.agents/skills/solve-issue/scripts/tracker" ]
}

@test "the ready-for-human block is written out only in to-issues" {
  run grep -lE '^(## For a human|### Why a person)$' "$REPO_ROOT"/skills/*/SKILL.md
  [ "$output" = "$REPO_ROOT/skills/to-issues/SKILL.md" ] || { echo "$output"; return 1; }
}

@test "the tracker-configuration fragment renders to at most 10 non-blank lines in every consumer" {
  local body n consumers=0
  for body in "$REPO_ROOT"/skills/*/SKILL.md; do
    grep -qxF '<!-- fragment:tracker-configuration -->' "$body" || continue
    consumers=$((consumers + 1))
    n=$(awk '/^<!-- fragment:tracker-configuration -->$/ { f = 1; next }
             /^<!-- \/fragment:tracker-configuration -->$/ { f = 0 }
             f && NF' "$body" | wc -l | tr -d ' ')
    [ "$n" -le 10 ] || { echo "$body: $n lines"; return 1; }
  done
  [ "$consumers" -gt 0 ]
}
