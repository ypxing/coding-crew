#!/usr/bin/env bats

# lib/git-workflow/commit-changes.sh: stages only the named files and commits them, printing the
# one-line log; git's own refusal surfaces when there is nothing to commit.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  COMMIT="$REPO_ROOT/lib/git-workflow/commit-changes.sh"
  WORK="$(mktemp -d)"
  git -C "$WORK" init -q -b feature
  git -C "$WORK" config user.email t@test
  git -C "$WORK" config user.name T
  git -C "$WORK" commit -q --allow-empty -m init
}
teardown() { rm -rf "$WORK"; }

@test "staged changes are committed with the prefix, and the one-line log is printed" {
  echo a > "$WORK/a.txt"
  echo b > "$WORK/b.txt"
  PROJECT_ROOT="$WORK" run bash "$COMMIT" --prefix "[01-x]" --message "Add a" --files "a.txt"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$(git -C "$WORK" log -1 --oneline)" ]
  [ "$(git -C "$WORK" log -1 --format=%s)" = "[01-x] Add a" ]
  [ "$(git -C "$WORK" status --porcelain)" = "?? b.txt" ]
}

@test "nothing to commit exits non-zero with git's message" {
  echo a > "$WORK/a.txt"
  git -C "$WORK" add a.txt && git -C "$WORK" commit -q -m a
  PROJECT_ROOT="$WORK" run bash "$COMMIT" --message "Again" --files "a.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to commit"* ]]
  [ "$(git -C "$WORK" log -1 --format=%s)" = "a" ]
}
