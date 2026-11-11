#!/usr/bin/env bats

# lib/git-workflow/commit-changes.sh: stages only the named files and commits them, printing the
# one-line log; named files that leave nothing staged exit 3, so a chained caller can accept that case.

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

@test "named files that leave nothing staged exit 3 with a nothing to commit line" {
  echo a > "$WORK/a.txt"
  git -C "$WORK" add a.txt && git -C "$WORK" commit -q -m a
  echo b > "$WORK/b.txt"
  PROJECT_ROOT="$WORK" run bash "$COMMIT" --message "Again" --files "a.txt"
  [ "$status" -eq 3 ]
  [[ "$output" == *"nothing to commit"* ]]
  [ "$(git -C "$WORK" log -1 --format=%s)" = "a" ]
}

@test "a commit git refuses for another reason exits 1" {
  echo a > "$WORK/a.txt"
  printf '#!/bin/sh\nexit 1\n' > "$WORK/.git/hooks/pre-commit"
  chmod +x "$WORK/.git/hooks/pre-commit"
  PROJECT_ROOT="$WORK" run bash "$COMMIT" --message "Add a" --files "a.txt"
  [ "$status" -eq 1 ]
  [ "$(git -C "$WORK" log -1 --format=%s)" = "init" ]
}

@test "a missing --message exits 1" {
  echo a > "$WORK/a.txt"
  PROJECT_ROOT="$WORK" run bash "$COMMIT" --files "a.txt"
  [ "$status" -eq 1 ]
}

@test "a --files value naming one path with a space stages that path, not its words" {
  mkdir -p "$WORK/src/My App"
  echo a > "$WORK/src/My App/main.py"
  echo b > "$WORK/b.txt"
  PROJECT_ROOT="$WORK" run bash "$COMMIT" --message "Rewrites" --files "src/My App/main.py" --files "b.txt"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$WORK" status --porcelain)" ]
  [ "$(git -C "$WORK" show --name-only --format= HEAD | sort)" = "$(printf 'b.txt\nsrc/My App/main.py')" ]
}

@test "a space-separated --files list still stages each path" {
  echo a > "$WORK/a.txt"
  echo b > "$WORK/b.txt"
  PROJECT_ROOT="$WORK" run bash "$COMMIT" --message "Both" --files "a.txt b.txt"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$WORK" status --porcelain)" ]
}

@test "a named path whose deletion is already committed is skipped, so nothing staged exits 3" {
  echo a > "$WORK/a.txt"
  git -C "$WORK" add a.txt && git -C "$WORK" commit -q -m a
  git -C "$WORK" rm -q a.txt && git -C "$WORK" commit -q -m "drop a"
  PROJECT_ROOT="$WORK" run bash "$COMMIT" --message "Work" --files "a.txt"
  [ "$status" -eq 3 ]
  [[ "$output" == *"nothing to commit"* ]]
}

@test "a named path git has never seen exits 1, not git's 128" {
  PROJECT_ROOT="$WORK" run bash "$COMMIT" --message "Work" --files "typo.txt"
  [ "$status" -eq 1 ]
  PROJECT_ROOT="$WORK" run bash "$COMMIT" --message "Work" --files ""
  [ "$status" -eq 1 ]
}
