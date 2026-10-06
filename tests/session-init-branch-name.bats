#!/usr/bin/env bats

# The feature branch's name: `<prefix><KEY>-<feature-slug>`, from --branch-prefix (config.json's
# afk.branchPrefix, default `feature/`) and --jira <KEY>. One function in session-init.sh builds
# it for every path that names a branch: create/switch, the `tracker: github` expected-branch
# check, and the no-slug path.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_SCRIPTS="$REPO_ROOT/skills/crew-afk/scripts"

load helpers/isolate-env

setup() {
  isolate_project_env
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  git init -q -b main
  git config user.email "test@test.com"
  git config user.name "Test"
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m initial
  mkdir -p .scratch/foo/issues/open
  echo "Status: ready-for-agent" > .scratch/foo/issues/open/01-first-issue.md
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

session_init() {
  bash "$AFK_SCRIPTS/session-init.sh" "$@"
}

write_tracker_config() {
  mkdir -p "$TEMP_DIR/.coding-crew/scripts" "$TEMP_DIR/.coding-crew/docs"
  cp "$REPO_ROOT/scripts/tracker/tracker-config.sh" "$TEMP_DIR/.coding-crew/scripts/tracker-config.sh"
  printf -- '---\ntracker: %s\n---\n\n# Issue tracker\n' "$1" > "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
}

branches() {
  git for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' '
}

@test "--jira puts the key between the prefix and the feature slug" {
  run session_init --feature-slug foo --jira PROJ-12
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/PROJ-12-foo" ]

  git checkout -q main
  rm .scratch/foo/sprint.env   # a fresh sprint, not a resume onto the first one's branch
  run session_init --feature-slug foo --jira AB2-7
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/AB2-7-foo" ]
}
