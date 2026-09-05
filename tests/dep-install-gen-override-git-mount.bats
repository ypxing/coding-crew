#!/usr/bin/env bats

# gen-override.sh: the git metadata mount (CREW_GIT_MOUNT).
#
# A *linked* worktree's `.git` is a file pointing at an absolute host path inside MAIN_ROOT's
# real `.git` dir. A container never has that path, so any git command run inside one — most
# commonly a package manager's postinstall hook (lefthook/husky/simple-git-hooks) — fails
# with `fatal: not a git repository`. gen-override.sh fixes this in two parts:
#   - the shared override file always mounts MAIN_ROOT's real `.git` dir read-only at
#     /git-common (plus a writable info/ overlay), regardless of which worktree's own
#     gen-override.sh call happens to (re)generate that shared file — the mount itself is
#     identical for every worktree, since it only ever depends on MAIN_ROOT.
#   - the env vars that point a *specific* worktree's container at its own subdirectory under
#     that mount (GIT_DIR, plus the hooksPath redirect) are never written to the shared file —
#     a caller resolves them per invocation via `--query git-env` and passes them as
#     `docker compose run -e KEY=VALUE` flags instead. Baking one worktree's GIT_DIR into the
#     file every worktree shares would be wrong for every other worktree reading it, and racy
#     under concurrent worktrees regenerating it.
# A plain (non-worktree) checkout's `.git` is already a real, writable directory reachable
# through the project's normal bind mount, so none of this applies there.

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

@test "the shared override always mounts MAIN_ROOT's .git read-only, generated from MAIN_ROOT itself" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  run bash "$SCRIPT" --project-root "$MAIN" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"$MAIN/.git:/git-common:ro"* ]]
  [[ "$output" =~ wt_[A-Za-z0-9_]+_git_info:/git-common/info ]]
  # never written to the shared file — these are per-invocation, via --query git-env
  [[ "$output" != *"GIT_COMMON_DIR"* ]]
  [[ "$output" != *"GIT_DIR"* ]]
  [[ "$output" != *"GIT_CONFIG"* ]]
}

@test "the shared override's mount content is identical whether generated from MAIN_ROOT or from a worktree" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  WORK="${MAIN}-wt"
  git -C "$MAIN" worktree add -q -b feature "$WORK" HEAD

  run bash "$SCRIPT" --project-root "$MAIN" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  from_main="$output"

  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  from_worktree="$output"

  [ "$from_main" = "$from_worktree" ]
}

@test "the git-info overlay volume is declared once as a service mount and once at top level" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  run bash "$SCRIPT" --project-root "$MAIN" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  volume_name=$(echo "$output" | grep -oE 'wt_[A-Za-z0-9_]+_git_info' | head -1)
  [ -n "$volume_name" ]
  [ "$(echo "$output" | grep -c "$volume_name")" -eq 2 ]
}

@test "CREW_GIT_MOUNT=off skips the mount in the shared file" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  CREW_GIT_MOUNT=off run bash "$SCRIPT" --project-root "$MAIN" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
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

@test "a MAIN_ROOT that is not a git checkout emits no git mount, by default" {
  NG_MAIN=$(mktemp -d)
  NG_WORK=$(mktemp -d)
  fixture_compose "$NG_WORK"

  run bash "$SCRIPT" --project-root "$NG_WORK" --main-root "$NG_MAIN" --dry-run
  [ "$status" -eq 0 ]
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

  run bash "$SCRIPT" --project-root "$MAIN" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git:       MAIN_ROOT's .git mounted read-only at /git-common"* ]]
}

@test "the written override's summary reports no mount when MAIN_ROOT is not a git checkout" {
  NG_MAIN=$(mktemp -d)
  fixture_compose "$NG_MAIN"

  run bash "$SCRIPT" --project-root "$NG_MAIN" --main-root "$NG_MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git:       not mounted (no git checkout detected at MAIN_ROOT)"* ]]
}

@test "--query git-env prints GIT_DIR/GIT_COMMON_DIR/hooksPath vars for a real worktree" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  WORK="${MAIN}-wt"
  git -C "$MAIN" worktree add -q -b feature "$WORK" HEAD

  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --query git-env
  [ "$status" -eq 0 ]
  [[ "$output" == *"GIT_COMMON_DIR=/git-common"* ]]
  [[ "$output" == *"GIT_DIR=/git-common/worktrees/$(basename "$WORK")"* ]]
  [[ "$output" == *"GIT_CONFIG_COUNT=1"* ]]
  [[ "$output" == *"GIT_CONFIG_KEY_0=core.hooksPath"* ]]
  [[ "$output" == *"GIT_CONFIG_VALUE_0=/tmp/git-hooks-container"* ]]
}

@test "--query git-env prints nothing for PROJECT_ROOT equal to MAIN_ROOT (no worktree)" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  run bash "$SCRIPT" --project-root "$MAIN" --main-root "$MAIN" --query git-env
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--query git-env prints nothing when CREW_GIT_MOUNT=off, even for a real worktree" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  WORK="${MAIN}-wt"
  git -C "$MAIN" worktree add -q -b feature "$WORK" HEAD

  CREW_GIT_MOUNT=off run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --query git-env
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--query git-env prints nothing for a PROJECT_ROOT that is not a git checkout" {
  NG_MAIN=$(mktemp -d)
  NG_WORK=$(mktemp -d)
  fixture_compose "$NG_WORK"

  run bash "$SCRIPT" --project-root "$NG_WORK" --main-root "$NG_MAIN" --query git-env
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
