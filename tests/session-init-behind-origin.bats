#!/usr/bin/env bats

# Issue 131: session-init.sh warns (stderr only) when it creates a new feature branch
# while the local default branch is behind origin. Uses a local bare repo as origin.

bats_require_minimum_version 1.5.0

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
  export MAIN_ROOT="$TEMP_DIR"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

installed_scripts() {
  local dir="$TEMP_DIR/installed-scripts"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    cp "$AFK_SCRIPTS"/*.sh "$dir/"
  fi
  echo "$dir"
}

# origin = local bare repo seeded from main; "other" is a second clone used to advance it.
make_origin() {
  git init -q --bare -b main "$TEMP_DIR/origin.git"
  git remote add origin "$TEMP_DIR/origin.git"
  git push -q origin HEAD:refs/heads/main
  git clone -q "$TEMP_DIR/origin.git" "$TEMP_DIR/other"
}

advance_origin() {
  git -C "$TEMP_DIR/other" -c user.email=t@t -c user.name=T commit -q --allow-empty -m one
  git -C "$TEMP_DIR/other" -c user.email=t@t -c user.name=T commit -q --allow-empty -m two
  git -C "$TEMP_DIR/other" push -q origin HEAD:refs/heads/main
}

@test "behind origin: warns with count, branch still created from local main" {
  make_origin
  advance_origin
  before=$(git rev-parse main)
  run --separate-stderr bash "$(installed_scripts)/session-init.sh" --feature-slug behind
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"WARNING: local main is 2 commit(s) behind origin/main"* ]]
  [ "$(git rev-parse feature/behind)" = "$before" ]
}

@test "up to date with origin: no warning" {
  make_origin
  run --separate-stderr bash "$(installed_scripts)/session-init.sh" --feature-slug fresh
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"behind origin"* ]]
}

@test "ahead of origin: no warning" {
  make_origin
  git commit -q --allow-empty -m local
  run --separate-stderr bash "$(installed_scripts)/session-init.sh" --feature-slug ahead
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"behind origin"* ]]
}

@test "no origin: no warning, normal sprint.env" {
  run --separate-stderr bash "$(installed_scripts)/session-init.sh" --feature-slug noorigin
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"behind origin"* ]]
  grep -q 'FEATURE_BRANCH="feature/noorigin"' .scratch/noorigin/sprint.env
}

@test "unreachable origin: no warning, normal sprint.env" {
  git remote add origin "$TEMP_DIR/does-not-exist.git"
  run --separate-stderr bash "$(installed_scripts)/session-init.sh" --feature-slug unreachable
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"behind origin"* ]]
  grep -q 'FEATURE_BRANCH="feature/unreachable"' .scratch/unreachable/sprint.env
}

@test "existing feature branch: no fetch, no warning" {
  make_origin
  git branch feature/existing
  advance_origin
  run --separate-stderr bash "$(installed_scripts)/session-init.sh" --feature-slug existing
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"behind origin"* ]]
  # no fetch ran: origin/main is still the pre-advance commit
  [ "$(git rev-parse refs/remotes/origin/main)" = "$(git rev-parse main)" ]
}

@test "resume from sprint.env: no fetch, no warning" {
  make_origin
  run bash "$(installed_scripts)/session-init.sh" --feature-slug resume
  [ "$status" -eq 0 ]
  git checkout -q main
  advance_origin
  run --separate-stderr bash "$(installed_scripts)/session-init.sh" --feature-slug resume
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"behind origin"* ]]
  [ "$(git rev-parse refs/remotes/origin/main)" = "$(git rev-parse main)" ]
}
