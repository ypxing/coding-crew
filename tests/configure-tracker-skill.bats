#!/usr/bin/env bats

# Tests for the configure-tracker skill

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export TEMP_DIR=$(mktemp -d)
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# --- Registry entry ---

@test "registry.json has configure-tracker entry under skills" {
  run jq -r '.skills["configure-tracker"] // empty' "$SCRIPT_DIR/registry.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# --- Installation ---

@test "install.sh claude --skill configure-tracker installs SKILL.md to target repo" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill configure-tracker

  [ -f "$TEMP_DIR/.claude/skills/configure-tracker/SKILL.md" ]
}

@test "configure-tracker-auto.sh no longer ships" {
  [ ! -e "$SCRIPT_DIR/lib/git-workflow/configure-tracker-auto.sh" ]
  run jq -r '.skills["configure-tracker"].scripts // empty' "$SCRIPT_DIR/registry.json"
  [ -z "$output" ]
}

# --- the project or user level ---

SKILL_MD() { echo "$SCRIPT_DIR/skills/configure-tracker/SKILL.md"; }
# step <n> <kind> <level> — the bash block under "## Step <n>", its placeholders filled.
step() {
  awk -v h="^## Step $1" '$0 ~ h { s = 1; next } /^## / { s = 0 } s && /^```bash/ { c = 1; next } s && c && /^```/ { exit } c' "$(SKILL_MD)" |
    sed -e "s#<local|github>#$2#" -e "s#<project|user>#$3#"
}
# project — $REPO, a git repo, and HOME a fresh temp directory.
project() {
  export HOME="$TEMP_DIR/home" REPO="$TEMP_DIR/repo"
  mkdir -p "$HOME" && git init -q -b main "$REPO" && cd "$REPO"
}

@test "Step 2 asks project (default) or user level after the tracker number" {
  grep -qF 'Save for (1) this project (default) or (2) all your projects (user level)?' "$(SKILL_MD)"
}

@test "Step 1 shows the project and the user file's tracker, none where unset" {
  project
  mkdir -p .coding-crew "$HOME/.coding-crew" && echo '{"tracker":{"kind":"github"}}' > "$HOME/.coding-crew/config.json"
  run bash -c "$(step 1)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"project ($REPO/.coding-crew/config.json): none"* ]]
  [[ "$output" == *"user ($HOME/.coding-crew/config.json): github"* ]]
}

@test "Step 4 at user level creates ~/.coding-crew, writes tracker only there keeping its other sections, and leaves the project alone" {
  project
  run bash -c "$(step 4 github user)"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(jq -c . "$HOME/.coding-crew/config.json")" = '{"tracker":{"kind":"github"}}' ]
  [ ! -e .coding-crew ]
  [ -z "$output" ]

  echo '{"solveFeature":{"models":{"coder":"sonnet"}},"tracker":{"kind":"github"}}' > "$HOME/.coding-crew/config.json"
  mkdir -p .coding-crew/docs && echo '{"tracker":{"kind":"local"}}' > .coding-crew/config.json
  echo '---' > .coding-crew/docs/issue-tracker.md
  run bash -c "$(step 4 local user)"
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$HOME/.coding-crew/config.json")" = '{"solveFeature":{"models":{"coder":"sonnet"}},"tracker":{"kind":"local"}}' ]
  [ "$(jq -c . .coding-crew/config.json)" = '{"tracker":{"kind":"local"}}' ]
  [ -f .coding-crew/docs/issue-tracker.md ]
  [[ "$output" == *"This project keeps local from $REPO/.coding-crew/config.json"* ]]

  echo '{}' > .coding-crew/config.json
  run bash -c "$(step 4 github user)"
  [[ "$output" == *"This project keeps its tracker from $REPO/.coding-crew/docs/issue-tracker.md"* ]]
}

@test "Step 4 at project level writes the project file, keeps its other sections, never the user file, and drops the legacy doc" {
  project
  mkdir -p .coding-crew/docs && echo '{"solveFeature":{}}' > .coding-crew/config.json && echo '---' > .coding-crew/docs/issue-tracker.md
  run bash -c "$(step 4 github project)"
  [ "$status" -eq 0 ]
  [ "$(jq -c . .coding-crew/config.json)" = '{"solveFeature":{},"tracker":{"kind":"github"}}' ]
  [ ! -e .coding-crew/docs/issue-tracker.md ]
  [ ! -e "$HOME/.coding-crew" ]
}

@test "Step 4 never replaces a file it could not parse" {
  project
  mkdir -p "$HOME/.coding-crew" && echo '{ broken' > "$HOME/.coding-crew/config.json"
  run bash -c "$(step 4 github user)"
  [ "$status" -ne 0 ]
  [ "$(cat "$HOME/.coding-crew/config.json")" = '{ broken' ]
  [ -z "$(ls "$HOME/.coding-crew" | grep -v '^config.json$')" ]
}

@test "Step 3 checks gh auth and creates no labels; Step 5 names the file written" {
  local s3; s3=$(awk '/^## Step 3/ { s = 1; next } /^## / { s = 0 } s' "$(SKILL_MD)")
  [[ "$s3" == *"gh auth status"* ]]
  [[ "$s3" != *"gh label create"* ]]
  awk '/^## Step 5/ { s = 1 } s' "$(SKILL_MD)" | grep -qF '<file written>'
}
