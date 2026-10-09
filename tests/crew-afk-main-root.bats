#!/usr/bin/env bats

# main-root.sh's main_root — the same root main.mjs's gitRoot() picks, for every repo layout a
# hand run of a crew-afk script can start in.

SCRIPTS="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts"

setup() {
  TEMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
  unset MAIN_ROOT TRACE_LOG CREW_ORCHESTRATED
  export GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=t@test \
    GIT_CONFIG_KEY_1=user.name GIT_CONFIG_VALUE_1=T GIT_CONFIG_KEY_2=protocol.file.allow GIT_CONFIG_VALUE_2=always
  git init -q -b main "$TEMP_DIR/repo"
  git -C "$TEMP_DIR/repo" commit -q --allow-empty -m init
}

teardown() { rm -rf "$TEMP_DIR"; }

root_in() { (cd "$1" && . "$SCRIPTS/main-root.sh" && main_root); }

@test "the main checkout, from itself and from a linked worktree" {
  git -C "$TEMP_DIR/repo" worktree add -q -b side "$TEMP_DIR/linked"
  [ "$(root_in "$TEMP_DIR/repo")" = "$TEMP_DIR/repo" ]
  [ "$(root_in "$TEMP_DIR/linked")" = "$TEMP_DIR/repo" ]
}

@test "a submodule is its own root, never the outer repo's .git/modules" {
  git init -q -b main "$TEMP_DIR/outer"
  git -C "$TEMP_DIR/outer" submodule add -q "$TEMP_DIR/repo" sub
  [ "$(root_in "$TEMP_DIR/outer/sub")" = "$TEMP_DIR/outer/sub" ]
}

@test "a submodule's linked worktree (an issue worktree) resolves to the submodule's checkout" {
  git init -q -b main "$TEMP_DIR/outer"
  git -C "$TEMP_DIR/outer" submodule add -q "$TEMP_DIR/repo" sub
  git -C "$TEMP_DIR/outer/sub" worktree add -q -b side "$TEMP_DIR/subwt"
  [ "$(root_in "$TEMP_DIR/subwt")" = "$TEMP_DIR/outer/sub" ]
}

@test "a bare repo's worktree is its own root, never the bare repo's parent" {
  git clone -q --bare "$TEMP_DIR/repo" "$TEMP_DIR/b.git"
  git -C "$TEMP_DIR/b.git" worktree add -q "$TEMP_DIR/wt" main
  [ "$(root_in "$TEMP_DIR/wt")" = "$TEMP_DIR/wt" ]
}

@test "outside a repo: non-zero, nothing printed" {
  mkdir "$TEMP_DIR/plain"
  run root_in "$TEMP_DIR/plain"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "trace.sh --feature-slug in a submodule writes the submodule's own log" {
  git init -q -b main "$TEMP_DIR/outer"
  git -C "$TEMP_DIR/outer" submodule add -q "$TEMP_DIR/repo" sub
  (cd "$TEMP_DIR/outer/sub" && bash "$SCRIPTS/trace.sh" --feature-slug x STEP "hello")
  grep -q hello "$TEMP_DIR/outer/sub/.scratch/x/traces/orchestrator.log"
  [ ! -e "$TEMP_DIR/outer/.git/modules/.scratch" ]
}
