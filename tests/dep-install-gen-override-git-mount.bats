#!/usr/bin/env bats

# gen-override.sh: the git metadata mount (CREW_GIT_MOUNT).
#
# A worktree's `.git` is a file pointing at an absolute host path inside MAIN_ROOT's real
# `.git` dir. A container never has that path, so any git command run inside one — most
# commonly a package manager's postinstall hook (lefthook/husky/simple-git-hooks) — fails
# with `fatal: not a git repository`. gen-override.sh fixes this by mounting MAIN_ROOT's
# `.git` read-only at a fixed container path and pointing GIT_DIR/GIT_COMMON_DIR at it, so
# git never needs to resolve the unmountable host path at all.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts"
SCRIPT="$SCRIPTS_DIR/gen-override.sh"

# fixture_compose <dir> — the minimal node-ecosystem fixture every test here needs.
fixture_compose() {
  local dir="$1"
  cat > "$dir/docker-compose.yml" <<'YML'
services:
  app:
    build: .
    volumes:
      - .:/opt/app
YML
  cat > "$dir/package.json" <<'JSON'
{"name":"fixture"}
JSON
  cat > "$dir/package-lock.json" <<'JSON'
{}
JSON
}

teardown() {
  if [ -n "${MAIN:-}" ] && [ -d "$MAIN" ] && [ -n "${WORK:-}" ]; then
    git -C "$MAIN" worktree remove --force "$WORK" 2>/dev/null || true
  fi
  [ -n "${MAIN:-}" ] && rm -rf "$MAIN"
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  [ -n "${NG_MAIN:-}" ] && rm -rf "$NG_MAIN"
  [ -n "${NG_WORK:-}" ] && rm -rf "$NG_WORK"
  return 0
}

@test "a real worktree gets GIT_COMMON_DIR/GIT_DIR env vars and a read-only bind mount of MAIN_ROOT's .git" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  WORK="${MAIN}-wt"
  git -C "$MAIN" worktree add -q -b feature "$WORK" HEAD

  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"GIT_COMMON_DIR=/git-common"* ]]
  [[ "$output" == *"GIT_DIR=/git-common/worktrees/$(basename "$WORK")"* ]]
  [[ "$output" == *"$MAIN/.git:/git-common:ro"* ]]
}

@test "PROJECT_ROOT equal to MAIN_ROOT (no worktree) mounts .git with GIT_DIR pointing at the mount root" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  run bash "$SCRIPT" --project-root "$MAIN" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"GIT_COMMON_DIR=/git-common"* ]]
  [[ "$output" == *"GIT_DIR=/git-common"* ]]
  [[ "$output" != *"GIT_DIR=/git-common/"* ]]
  [[ "$output" == *"$MAIN/.git:/git-common:ro"* ]]
}

@test "CREW_GIT_MOUNT=off skips the mount and env vars even for a real worktree" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  WORK="${MAIN}-wt"
  git -C "$MAIN" worktree add -q -b feature "$WORK" HEAD

  CREW_GIT_MOUNT=off run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"GIT_COMMON_DIR"* ]]
  [[ "$output" != *"GIT_DIR"* ]]
  [[ "$output" != *"/git-common"* ]]
}

@test "an unknown CREW_GIT_MOUNT value is a usage error, not a silent fallback" {
  MAIN=$(mktemp -d)
  WORK=$(mktemp -d)
  fixture_compose "$WORK"

  CREW_GIT_MOUNT=bogus run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"CREW_GIT_MOUNT"* ]]
}

@test "a PROJECT_ROOT that is not a git checkout emits no git mount, by default" {
  NG_MAIN=$(mktemp -d)
  NG_WORK=$(mktemp -d)
  fixture_compose "$NG_WORK"

  run bash "$SCRIPT" --project-root "$NG_WORK" --main-root "$NG_MAIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"GIT_COMMON_DIR"* ]]
  [[ "$output" != *"GIT_DIR"* ]]
  [[ "$output" != *"/git-common"* ]]
}

@test "the written override's summary reports the git mount status" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  WORK="${MAIN}-wt"
  git -C "$MAIN" worktree add -q -b feature "$WORK" HEAD

  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git:       mounted read-only at /git-common"* ]]
}
