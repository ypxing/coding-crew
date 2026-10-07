#!/usr/bin/env bats

# tracker-config.sh's read_tracker_config — the bash face of tracker/tracker-config.mjs's
# readTrackerConfig, which it runs through `cli.mjs config`. Every fixture runs both readers and
# checks they agree.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  SCRIPT="$REPO_ROOT/scripts/tracker/tracker-config.sh"
  CLI="$REPO_ROOT/tracker/cli.mjs"
  FIXTURES="$REPO_ROOT/tests/fixtures/tracker-config"
  TEMP_DIR="$(mktemp -d)"
  mkdir -p "$TEMP_DIR/.coding-crew/docs"
  unset CREW_TRACKER_CLI
}

teardown() {
  rm -rf "$TEMP_DIR"
}

legacy_fixture() { cp "$FIXTURES/$1" "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"; }
legacy_doc() { printf '%s' "$1" > "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"; }
config_json() { printf '%s' "$1" > "$TEMP_DIR/.coding-crew/config.json"; }
afk_only_config() { cp "$FIXTURES/config-afk-only.json" "$TEMP_DIR/.coding-crew/config.json"; }

# expect <tracker> <yes|no> — both readers resolve exactly this.
expect() {
  run node "$CLI" config --main-root "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "tracker=$1"$'\n'"configured=$2" ]
  source "$SCRIPT"
  read_tracker_config "$TEMP_DIR"
  [ "$TRACKER_CONFIG_TRACKER" = "$1" ]
  [ "$TRACKER_CONFIG_CONFIGURED" = "$2" ]
}

# expect_error <text> — both readers fail, naming <text>.
expect_error() {
  run node "$CLI" config --main-root "$TEMP_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"$1"* ]]
  run bash -c 'source "$1" && read_tracker_config "$2"' _ "$SCRIPT" "$TEMP_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$1"* ]]
}

@test "config.json's tracker section alone: github, configured" {
  config_json '{"tracker": {"kind": "github"}}'
  expect github yes
}

@test "config.json's tracker section wins over the legacy front matter" {
  config_json '{"tracker": {"kind": "local"}}'
  legacy_fixture issue-tracker-github.md
  expect local yes
}

@test "legacy issue-tracker.md with front matter tracker: github: github, configured" {
  afk_only_config
  legacy_fixture issue-tracker-github.md
  expect github yes
}

@test "legacy issue-tracker.md with no front matter: local, configured" {
  afk_only_config
  legacy_fixture issue-tracker-no-front-matter.md
  expect local yes
}

@test "neither: local, not configured" {
  expect local no
  afk_only_config
  expect local no
}

@test "config.json that is not valid JSON: both readers fail naming it" {
  config_json '{ tracker: github'
  expect_error ".coding-crew/config.json"
}

@test "an unknown tracker.kind: both readers fail naming config.json" {
  config_json '{"tracker": {"kind": "jira"}}'
  expect_error ".coding-crew/config.json"
}

@test "a legacy front matter naming repo: both readers fail with the path" {
  legacy_doc $'---\ntracker: github\nrepo: owner/name\n---\n'
  expect_error '`repo` is no longer supported'
  expect_error "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
}

@test "installed layout: .coding-crew/scripts/tracker-config.sh finds .coding-crew/tracker/cli.mjs beside it" {
  mkdir -p "$TEMP_DIR/i/scripts"
  cp "$SCRIPT" "$TEMP_DIR/i/scripts/"
  cp -R "$REPO_ROOT/tracker" "$TEMP_DIR/i/tracker"
  config_json '{"tracker": {"kind": "github"}}'
  run bash "$TEMP_DIR/i/scripts/tracker-config.sh" "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = $'tracker=github\nconfigured=yes' ]
}

@test "no cli.mjs to be found: fails rather than guessing local" {
  mkdir -p "$TEMP_DIR/i/scripts"
  cp "$SCRIPT" "$TEMP_DIR/i/scripts/"
  run env HOME="$TEMP_DIR/nohome" bash "$TEMP_DIR/i/scripts/tracker-config.sh" "$TEMP_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cli.mjs"* ]]
}
