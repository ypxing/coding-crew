#!/usr/bin/env bats

# The feature branch's name: `<prefix><KEY>-<feature-slug>`, from --branch-prefix (config.json's
# afk.branchPrefix, default `feature/`) and --jira <KEY>. One function in session-init.sh builds
# it for every path that names a branch. session-init.sh only names the branch and creates the ref:
# it never checks it out, so the main checkout stays on `main` throughout.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_SCRIPTS="$REPO_ROOT/skills/crew-afk/scripts"

bats_require_minimum_version 1.5.0
load helpers/isolate-env

setup() {
  isolate_project_env
  # session-init.sh asks this repo's own tracker CLI, not a full install.
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  unset CREW_INSTALL_DIR
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
  mkdir -p "$TEMP_DIR/.coding-crew/docs"
  printf -- '---\ntracker: %s\n---\n\n# Issue tracker\n' "$1" > "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
}

has_branch() {
  git rev-parse --verify -q "refs/heads/$1" >/dev/null
}

branches() {
  git for-each-ref --format='%(refname:short)' refs/heads | tr '\n' ' '
}

@test "--jira puts the key between the prefix and the feature slug" {
  run session_init --feature-slug foo --jira PROJ-12
  [ "$status" -eq 0 ]
  has_branch feature/PROJ-12-foo

  rm .scratch/foo/sprint.env   # a fresh sprint, not a resume onto the first one's branch
  run session_init --feature-slug foo --jira AB2-7
  [ "$status" -eq 0 ]
  has_branch feature/AB2-7-foo
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "--branch-prefix replaces feature/, and an empty prefix leaves the bare slug" {
  run session_init --feature-slug foo --branch-prefix feat/
  [ "$status" -eq 0 ]
  has_branch feat/foo

  rm .scratch/foo/sprint.env
  run session_init --feature-slug foo --branch-prefix ""
  [ "$status" -eq 0 ]
  has_branch foo
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "no --jira and no --branch-prefix: feature/<slug>" {
  run session_init --feature-slug foo
  [ "$status" -eq 0 ]
  has_branch feature/foo
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
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
  run session_init --feature-slug foo --branch-prefix feat/ --jira PROJ-12
  [ "$status" -eq 0 ]
  has_branch feat/PROJ-12-foo
}

@test "github tracker, no sprint.env: the main checkout's own branch is irrelevant and stays checked out" {
  write_tracker_config github
  git checkout -q -b feature/foo
  run --separate-stderr session_init --feature-slug foo --branch-prefix feat/ --jira PROJ-12
  [ "$status" -eq 0 ]
  has_branch feat/PROJ-12-foo
  [ "$(git rev-parse --abbrev-ref HEAD)" = "feature/foo" ]
}

@test "a sprint.env pinning feature/foo resumes there, warning that --jira was ignored" {
  run session_init --feature-slug foo
  [ "$status" -eq 0 ]
  run --separate-stderr session_init --feature-slug foo --jira PROJ-12
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"--jira"*"ignored"* ]]
  ! git rev-parse --verify -q feature/PROJ-12-foo
  grep -q '^export FEATURE_BRANCH="feature/foo"' .scratch/foo/sprint.env
}

@test "a sprint.env pinning feature/PROJ-12-foo, resumed with --jira PROJ-12, prints no warning" {
  run session_init --feature-slug foo --jira PROJ-12
  [ "$status" -eq 0 ]
  run --separate-stderr session_init --feature-slug foo --jira PROJ-12
  [ "$status" -eq 0 ]
  has_branch feature/PROJ-12-foo
  [[ "$stderr" != *"WARNING"* ]]
}

@test "local tracker, no sprint.env: --jira names the branch with no warning, whatever the main checkout is on" {
  write_tracker_config local
  git checkout -q -b some-other-branch
  run --separate-stderr session_init --feature-slug foo --jira PROJ-12
  [ "$status" -eq 0 ]
  has_branch feature/PROJ-12-foo
  [ "$(git rev-parse --abbrev-ref HEAD)" = "some-other-branch" ]
  [[ "$stderr" != *"WARNING"* ]]
}

@test "no --feature-slug: the branch is named from the feature dir, not the first issue" {
  run session_init --jira PROJ-12
  [ "$status" -eq 0 ]
  has_branch feature/PROJ-12-foo
}
