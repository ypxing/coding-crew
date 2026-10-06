#!/usr/bin/env bats

# The feature branch's name: `<prefix><KEY>-<feature-slug>`, from --branch-prefix (config.json's
# afk.branchPrefix, default `feature/`) and --jira <KEY>. One function in session-init.sh builds
# it for every path that names a branch: create/switch, the `tracker: github` expected-branch
# check, and the no-slug path.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_SCRIPTS="$REPO_ROOT/skills/crew-afk/scripts"

bats_require_minimum_version 1.5.0
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

@test "--branch-prefix replaces feature/, and an empty prefix leaves the bare slug" {
  run session_init --feature-slug foo --branch-prefix feat/
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feat/foo" ]

  git checkout -q main
  rm .scratch/foo/sprint.env
  run session_init --feature-slug foo --branch-prefix ""
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "foo" ]
}

@test "no --jira and no --branch-prefix: feature/<slug>" {
  run session_init --feature-slug foo
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/foo" ]
}

@test "a malformed --jira key exits before any branch is created, naming the value and the format" {
  before=$(branches)
  run --separate-stderr session_init --feature-slug foo --jira proj-12
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"proj-12"* ]]
  [[ "$stderr" == *"PROJ-123"* ]]
  [ "$(branches)" = "$before" ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "a prefix that makes an invalid ref exits before any branch is created, naming the branch" {
  before=$(branches)
  run --separate-stderr session_init --feature-slug foo --branch-prefix "a..b/"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"a..b/foo"* ]]
  [ "$(branches)" = "$before" ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "github tracker, no sprint.env: the expected branch is built from the prefix and --jira" {
  write_tracker_config github
  git checkout -q -b feat/PROJ-12-foo
  run session_init --feature-slug foo --branch-prefix feat/ --jira PROJ-12
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feat/PROJ-12-foo" ]
}

@test "github tracker, no sprint.env: any other non-default branch is refused, naming the expected one" {
  write_tracker_config github
  git checkout -q -b feature/foo
  run --separate-stderr session_init --feature-slug foo --branch-prefix feat/ --jira PROJ-12
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"feat/PROJ-12-foo"* ]]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/foo" ]
}

@test "a sprint.env pinning feature/foo resumes there, warning that --jira was ignored" {
  run session_init --feature-slug foo
  [ "$status" -eq 0 ]
  git checkout -q main
  run --separate-stderr session_init --feature-slug foo --jira PROJ-12
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/foo" ]
  [[ "$stderr" == *"--jira"*"ignored"* ]]
  ! git rev-parse --verify -q feature/PROJ-12-foo
}

@test "local tracker off the default branch with no sprint.env keeps the branch, warning that --jira was ignored" {
  write_tracker_config local
  git checkout -q -b some-other-branch
  run --separate-stderr session_init --feature-slug foo --jira PROJ-12
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "some-other-branch" ]
  [[ "$stderr" == *"--jira"*"ignored"* ]]
}

@test "no --feature-slug: the branch is named from the feature dir, not the first issue" {
  run session_init --jira PROJ-12
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/PROJ-12-foo" ]
}
