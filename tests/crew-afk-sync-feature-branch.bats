#!/usr/bin/env bats

# sync-feature-branch.sh — merge origin/<default> into a resumed feature branch that lacks it.
# `origin` is a local bare repo; the "main checkout" is a clone with the feature branch checked out.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SYNC="$REPO_ROOT/skills/crew-afk/scripts/sync-feature-branch.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  export HOME="$TEMP_DIR/home"; mkdir -p "$HOME"
  export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@test GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@test
  unset TRACE_LOG
  git init -q --bare -b main "$TEMP_DIR/origin.git"
  git clone -q "$TEMP_DIR/origin.git" "$TEMP_DIR/w" 2>/dev/null
  cd "$TEMP_DIR/w"
  git checkout -q -b main 2>/dev/null || true
  echo one > a.txt
  printf '{\n  "skills": {\n    "x": {\n      "version": "1.0.0"\n    }\n  }\n}\n' > registry.json
  git add -A && git commit -q -m init && git push -q origin main
  git checkout -q -b feature/demo
}

teardown() { rm -rf "$TEMP_DIR"; }

advance_origin() { # <file> <content>
  git checkout -q main
  echo "$2" > "$1"; git add -A; git commit -q -m "main: $1"; git push -q origin main
  git checkout -q feature/demo
}

@test "squash-merged then resumed: origin/main is merged in and is an ancestor afterwards" {
  echo work > f.txt; git add -A; git commit -q -m "feature work"
  # squash-merge the feature to main: same tree, no feature history
  git checkout -q main; echo work > f.txt; git add -A; git commit -q -m "squash (#1)"; git push -q origin main
  git checkout -q feature/demo
  run bash "$SYNC" feature/demo
  [ "$status" -eq 0 ]
  [[ "$output" == "SYNC: merged origin/main (1 commit(s)) into feature/demo at "* ]]
  git merge-base --is-ancestor origin/main feature/demo
  [ -z "$(git status --porcelain)" ]
}

@test "already up to date: no merge commit and no SYNC line" {
  before=$(git rev-parse HEAD)
  run bash "$SYNC" feature/demo
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(git rev-parse HEAD)" = "$before" ]
}

@test "branch ahead of origin/main: nothing to do" {
  echo work > f.txt; git add -A; git commit -q -m work
  before=$(git rev-parse HEAD)
  run bash "$SYNC" feature/demo
  [ "$status" -eq 0 ]; [ -z "$output" ]
  [ "$(git rev-parse HEAD)" = "$before" ]
}

@test "registry.json version conflict is resolved and committed, versions are not bumped" {
  sed -i.bak 's/1.0.0/1.1.0/' registry.json; rm registry.json.bak; git commit -qam "feature bump"
  git checkout -q main; sed -i.bak 's/1.0.0/1.2.0/' registry.json; rm registry.json.bak
  git commit -qam "main bump"; git push -q origin main; git checkout -q feature/demo
  run bash "$SYNC" feature/demo
  [ "$status" -eq 0 ]
  [[ "$output" == "SYNC: merged origin/main"* ]]
  grep -q '"1.2.0"' registry.json
  ! grep -q '"1.1.0"' registry.json
  [ -z "$(git status --porcelain)" ]
  git merge-base --is-ancestor origin/main feature/demo
}

@test "any other conflict aborts, leaves the old tip and a clean tree, exits 1 naming the file" {
  echo mine > a.txt; git commit -qam "feature a"
  before=$(git rev-parse HEAD)
  advance_origin a.txt theirs
  run bash "$SYNC" feature/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"a.txt"* ]]
  [ "$(git rev-parse HEAD)" = "$before" ]
  [ -z "$(git status --porcelain)" ]
  [ ! -f .git/MERGE_HEAD ]
}

@test "no origin remote: silent skip" {
  git remote remove origin
  run bash "$SYNC" feature/demo
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "unreachable origin: silent skip" {
  git remote set-url origin "$TEMP_DIR/nope.git"
  run bash "$SYNC" feature/demo
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "missing origin/<default>: silent skip" {
  git -C "$TEMP_DIR/origin.git" branch -m main other
  git -C "$TEMP_DIR/origin.git" symbolic-ref HEAD refs/heads/other
  git update-ref -d refs/remotes/origin/main
  git symbolic-ref -q -d refs/remotes/origin/HEAD || true
  run bash "$SYNC" feature/demo
  [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "--dry-run reports the merge and does not perform it" {
  advance_origin b.txt two
  before=$(git rev-parse HEAD)
  run bash "$SYNC" --dry-run feature/demo
  [ "$status" -eq 0 ]
  [[ "$output" == "SYNC: would merge origin/main (1 commit(s)) into feature/demo" ]]
  [ "$(git rev-parse HEAD)" = "$before" ]
}
