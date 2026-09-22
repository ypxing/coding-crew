#!/usr/bin/env bats

# Issue 10: github-tracker-specific handling in session-init.sh.
#
# Under `tracker: github` there is nothing local to scan for a first issue, and
# cross-machine resume depends on the feature branch name being deterministic — so
# this repo's own copy of session-init.sh (via tracker-config.sh, from issue 01)
# closes two gaps that only matter for that backend:
#   1. omitting --feature-slug is a hard error (no local-scan fallback)
#   2. off the default branch with no sprint.env to resume from, the current branch
#      must equal feature/<slug> — no silent-adopt of whatever is checked out
# `tracker: local` (or absent config) keeps every existing behavior unchanged.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_SCRIPTS="$REPO_ROOT/skills/crew-afk/scripts"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  git init -q -b main
  git config user.email "test@test.com"
  git config user.name "Test"
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m initial
  export MAIN_ROOT="$TEMP_DIR"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# session-init.sh calls feature-branch-setup.sh, trace.sh and tracker-config.sh as
# siblings/fixed-path helpers only after install.sh copies them into place. Reproduce
# both: the skill's own scripts/ dir, and tracker-config.sh's fixed install
# location (.coding-crew/scripts/, per registry.json's docs.scripts entry).
installed_scripts() {
  local dir="$TEMP_DIR/installed-scripts"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    cp "$AFK_SCRIPTS"/*.sh "$dir/"
    cp "$REPO_ROOT/scripts/skill-utils/git-workflow/feature-branch-setup.sh" "$dir/"
  fi
  echo "$dir"
}

write_tracker_config() {
  mkdir -p "$TEMP_DIR/.coding-crew/scripts" "$TEMP_DIR/.coding-crew/docs"
  cp "$REPO_ROOT/scripts/tracker/tracker-config.sh" "$TEMP_DIR/.coding-crew/scripts/tracker-config.sh"
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

@test "github tracker: --feature-slug on the default branch creates feature/<slug>" {
  write_tracker_config github

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/calc" ]
}

@test "github tracker: --feature-slug on a mismatched non-default branch with no sprint.env errors" {
  write_tracker_config github
  git checkout -q -b some-other-branch

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -ne 0 ]
  [[ "$output" == *"feature/calc"* ]]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "some-other-branch" ]
}

@test "local tracker: omitting --feature-slug still falls back to scanning .scratch (unchanged)" {
  write_tracker_config local
  mkdir -p .scratch/some-slug/issues/open
  echo "Status: ready-for-agent" > .scratch/some-slug/issues/open/01-first.md

  run bash "$(installed_scripts)/session-init.sh"
  [ "$status" -eq 0 ]
  # feature-branch-setup.sh names the branch after the first issue file, not the
  # directory slug — this test only asserts the (unrelated) local-scan fallback ran.
  [[ "$(git rev-parse --abbrev-ref HEAD)" == feature/* ]]
}

@test "local tracker: --feature-slug on a mismatched non-default branch with no sprint.env still silently adopts it (unchanged)" {
  write_tracker_config local
  git checkout -q -b some-other-branch

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "some-other-branch" ]
}

@test "absent tracker config (no .coding-crew doc at all): behaves like local, unchanged" {
  git checkout -q -b some-other-branch

  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "some-other-branch" ]
}
