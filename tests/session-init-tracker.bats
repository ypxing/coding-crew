#!/usr/bin/env bats

# Issue 10: github-tracker-specific handling in session-init.sh.
#
# Under `tracker: github` there is nothing local to scan for a first issue, and
# cross-machine resume depends on the feature branch name being deterministic — so
# this repo's own copy of session-init.sh (asking the tracker CLI through tracker-cli.sh)
# closes two gaps that only matter for that backend:
#   1. omitting --feature-slug is a hard error (no local-scan fallback)
#   2. the feature branch is named from the slug alone, whichever branch the main checkout is on —
#      it is a ref session-init.sh makes, never a checkout
# `tracker: local` (or absent config) keeps every existing behavior unchanged. With no tracker
# CLI to ask, session-init.sh stops instead of guessing local.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_SCRIPTS="$REPO_ROOT/skills/crew-afk/scripts"

load helpers/isolate-env

setup() {
  isolate_project_env
  unset CREW_INSTALL_DIR CREW_TRACKER_CLI
  export TEMP_DIR=$(mktemp -d)
  export HOME="$TEMP_DIR/empty-home"   # no user-level install to find
  cd "$TEMP_DIR"
  git init -q -b main
  git config user.email "test@test.com"
  git config user.name "Test"
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m initial
  export MAIN_ROOT="$TEMP_DIR"
  mkdir -p "$HOME"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# session-init.sh calls trace.sh and tracker-cli.sh as siblings, as install.sh lays them out,
# and the tracker CLI installs to the repo's .coding-crew/tracker/.
installed_scripts() {
  local dir="$TEMP_DIR/installed-scripts"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    cp "$AFK_SCRIPTS"/*.sh "$dir/"
  fi
  echo "$dir"
}

write_tracker_config() {
  mkdir -p "$TEMP_DIR/.coding-crew/docs"
  [ -d "$TEMP_DIR/.coding-crew/tracker" ] || cp -R "$REPO_ROOT/tracker" "$TEMP_DIR/.coding-crew/tracker"
  printf -- '---\ntracker: %s\n---\n\n# Issue tracker\n' "$1" > "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
}

@test "github tracker: omitting --feature-slug is a hard error, no local-scan fallback" {
  write_tracker_config github
  mkdir -p .scratch/some-slug/issues/open
  echo "Status: ready-for-agent" > .scratch/some-slug/issues/open/01-first.md

  run bash "$(installed_scripts)/session-init.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--feature-slug"* ]]
}

@test "github tracker: --feature-slug creates feature/<slug> and leaves the checkout on the default branch" {
  write_tracker_config github

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  git rev-parse --verify -q refs/heads/feature/calc
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "github tracker: --feature-slug on any other branch still names feature/<slug>, leaving the checkout alone" {
  write_tracker_config github
  git checkout -q -b some-other-branch

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  git rev-parse --verify -q refs/heads/feature/calc
  [ "$(git rev-parse --abbrev-ref HEAD)" = "some-other-branch" ]
}

@test "local tracker: omitting --feature-slug still falls back to scanning .scratch (unchanged)" {
  write_tracker_config local
  mkdir -p .scratch/some-slug/issues/open
  echo "Status: ready-for-agent" > .scratch/some-slug/issues/open/01-first.md

  run bash "$(installed_scripts)/session-init.sh"
  [ "$status" -eq 0 ]
  # The branch is named after the directory the first issue lives in.
  git rev-parse --verify -q refs/heads/feature/some-slug
}

@test "local tracker: --feature-slug on another branch names feature/<slug> too, and does not adopt that branch" {
  write_tracker_config local
  git checkout -q -b some-other-branch

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  git rev-parse --verify -q refs/heads/feature/calc
  [ "$(git rev-parse --abbrev-ref HEAD)" = "some-other-branch" ]
}

@test "github tracker declared but no tracker CLI installed: hard error, no silent local fallback" {
  write_tracker_config github
  rm -r "$TEMP_DIR/.coding-crew/tracker"
  mkdir -p .scratch/some-slug/issues/open
  echo "Status: ready-for-agent" > .scratch/some-slug/issues/open/01-first.md

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -ne 0 ]
  [[ "$output" == *"tracker CLI (.coding-crew/tracker/cli.mjs) not found — re-run install.sh"* ]]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "config.json names github, no .coding-crew/scripts anywhere: behaves as github (a slug is required)" {
  mkdir -p "$TEMP_DIR/.coding-crew"
  cp -R "$REPO_ROOT/tracker" "$TEMP_DIR/.coding-crew/tracker"
  printf '{"tracker": {"kind": "github"}}\n' > "$TEMP_DIR/.coding-crew/config.json"
  git checkout -q -b some-other-branch

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  git rev-parse --verify -q refs/heads/feature/calc
  [ "$(git rev-parse --abbrev-ref HEAD)" = "some-other-branch" ]
}

@test "config.json's local wins over a github front matter" {
  write_tracker_config github
  printf '{"tracker": {"kind": "local"}}\n' > "$TEMP_DIR/.coding-crew/config.json"
  git checkout -q -b some-other-branch

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -eq 0 ]
}

@test "local tracker declared but no tracker CLI installed: exits non-zero rather than guessing" {
  write_tracker_config local
  rm -r "$TEMP_DIR/.coding-crew/tracker"
  git checkout -q -b some-other-branch

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -ne 0 ]
  [[ "$output" == *"re-run install.sh"* ]]
}

@test "absent tracker config (no .coding-crew doc at all): behaves like local, unchanged" {
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  git checkout -q -b some-other-branch

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "some-other-branch" ]
}
