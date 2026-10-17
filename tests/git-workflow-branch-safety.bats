#!/usr/bin/env bats

# lib/git-workflow/branch-safety-check.sh: refuses the default branch (origin/HEAD, else main) and
# allows any other, so a skill that commits never lands its work on the default branch.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  CHECK="$REPO_ROOT/lib/git-workflow/branch-safety-check.sh"
  WORK="$(mktemp -d)"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.email t@test
  git -C "$WORK" config user.name T
  git -C "$WORK" commit -q --allow-empty -m init
  cd "$WORK"
}
teardown() { cd /; rm -rf "$WORK"; }

@test "with no origin/HEAD, main is the default branch and is refused" {
  run bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: Cannot run on default branch (main)"* ]]
}

@test "a feature branch is allowed" {
  git checkout -q -b feature/test-pr
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "Branch: feature/test-pr" ]
}

@test "origin/HEAD names the default branch: master is refused, main is then allowed" {
  git update-ref refs/remotes/origin/master HEAD
  git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
  git checkout -q -b master
  run bash "$CHECK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: Cannot run on default branch (master)"* ]]

  git checkout -q main
  run bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "any argument is unknown: exit 2, before the branch is looked at" {
  run bash "$CHECK" --not-a-flag
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument: --not-a-flag"* ]]
}
