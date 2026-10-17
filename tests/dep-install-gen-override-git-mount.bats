#!/usr/bin/env bats

# gen-override.sh: the git metadata mount and where the override is written.
#
# A *linked* worktree's `.git` is a file pointing at an absolute host path inside the repo's
# shared `.git` dir. A container never has that path, so any git command run inside one — most
# commonly a package manager's postinstall hook (lefthook/husky/simple-git-hooks) — fails
# with `fatal: not a git repository`. gen-override.sh fixes this in two parts:
#   - the override always mounts the shared `.git` dir (git's common dir) read-only at /git-common
#     (plus writable hooks/ and info/ overlays).
#   - for a linked worktree it also bakes that worktree's own GIT_DIR / GIT_COMMON_DIR *values*
#     into the file, which lives in the worktree's own git dir, so no other worktree reads it.
# A plain (non-worktree) checkout's `.git` is already a real, writable directory reachable
# through the project's normal bind mount, so no GIT_* entries apply there.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"
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

# _override <root> — writes <root>'s override and prints it.
_override() {
  bash "$SCRIPT" --project-root "$1" >/dev/null || return 1
  cat "$(git -C "$1" rev-parse --path-format=absolute --git-dir)/crew-compose.override.yml"
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

@test "the main checkout's override mounts its .git read-only" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  run _override "$MAIN"
  [ "$status" -eq 0 ]
  # Compare against git's own --path-format=absolute rendering of MAIN, not the bash
  # variable itself: on Windows those differ (MSYS "/c/..." vs git.exe's "C:/..."), and
  # the script's mount is built from the former, same as gen-override.sh does internally.
  local git_common_dir_abs
  git_common_dir_abs="$(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir)"
  [[ "$output" == *"${git_common_dir_abs}:/git-common:ro"* ]]
  [[ "$output" =~ wt_[A-Za-z0-9_]+_git_hooks:/git-common/hooks ]]
  [[ "$output" =~ wt_[A-Za-z0-9_]+_git_info:/git-common/info ]]
  # the main checkout is not a linked worktree: no GIT_* entry, valued or bare
  [[ "$output" != *"GIT_COMMON_DIR"* ]]
  [[ "$output" != *"GIT_DIR"* ]]
  # GIT_CONFIG_* is a numbered list the host may have set to any length — never passed through
  [[ "$output" != *"GIT_CONFIG"* ]]
}

@test "a worktree's override mounts the same shared .git, plus its own GIT_* entries" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  WORK="${MAIN}-wt"
  git -C "$MAIN" worktree add -q -b feature "$WORK" HEAD

  run _override "$MAIN"
  [ "$status" -eq 0 ]
  from_main="$output"

  run _override "$WORK"
  [ "$status" -eq 0 ]
  from_worktree="$output"

  mount="      - $(git -C "$MAIN" rev-parse --path-format=absolute --git-common-dir):/git-common:ro"
  grep -qxF -- "$mount" <<<"$from_main"
  grep -qxF -- "$mount" <<<"$from_worktree"
  [[ "$from_worktree" == *"      - GIT_COMMON_DIR=/git-common"* ]]
  [[ "$from_worktree" == *"      - GIT_DIR=/git-common/worktrees/$(basename "$WORK")"* ]]
}

@test "the git-info and git-hooks overlay volumes are each declared once as a service mount and once at top level" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  run _override "$MAIN"
  [ "$status" -eq 0 ]
  for suffix in git_info git_hooks; do
    volume_name=$(echo "$output" | grep -oE "wt_[A-Za-z0-9_]+_${suffix}" | head -1)
    [ -n "$volume_name" ]
    [ "$(echo "$output" | grep -c "$volume_name")" -eq 2 ]
  done
}

@test "writing the override creates the overlay mount points in the shared .git when missing" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init
  rm -r "$MAIN/.git/hooks" "$MAIN/.git/info"

  run bash "$SCRIPT" --project-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -d "$MAIN/.git/hooks" ]
  [ -d "$MAIN/.git/info" ]
}

@test "the written override's summary reports the git mount status" {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init

  run bash "$SCRIPT" --project-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git:       the shared .git mounted read-only at /git-common"* ]]
}

@test "writing the override for a PROJECT_ROOT that is not a git checkout fails: there is no git dir to put it in" {
  NG_MAIN=$(mktemp -d)
  fixture_compose "$NG_MAIN"

  run bash "$SCRIPT" --project-root "$NG_MAIN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git checkout"* ]]
  [ ! -e "$NG_MAIN/docker-compose.override.yml" ]
}

# _git_fixture — a git MAIN with the node fixture committed, in $MAIN.
_git_fixture() {
  MAIN=$(mktemp -d)
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email t@test
  git -C "$MAIN" config user.name T
  fixture_compose "$MAIN"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m init
}

@test "a linked worktree's override is written to its own git dir with its own GIT_* values" {
  _git_fixture
  WORK="${MAIN}-wt"
  git -C "$MAIN" worktree add -q -b feature "$WORK" HEAD

  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  gitdir="$(git -C "$WORK" rev-parse --path-format=absolute --git-dir)"
  [ -f "$gitdir/crew-compose.override.yml" ]
  grep -qx '      - GIT_COMMON_DIR=/git-common' "$gitdir/crew-compose.override.yml"
  grep -qx "      - GIT_DIR=/git-common/worktrees/$(basename "$WORK")" "$gitdir/crew-compose.override.yml"
  ! grep -q 'GIT_CONFIG' "$gitdir/crew-compose.override.yml" || false
  # nothing was written into the repo trees, and MAIN's own git dir got no copy
  [ ! -e "$WORK/docker-compose.override.yml" ]
  [ ! -e "$MAIN/docker-compose.override.yml" ]
  [ ! -e "$MAIN/.git/crew-compose.override.yml" ]
}

@test "two worktrees each get their own file with their own GIT_DIR" {
  _git_fixture
  WORK="${MAIN}-wt"
  WORK2="${MAIN}-wt2"
  git -C "$MAIN" worktree add -q -b feature "$WORK" HEAD
  git -C "$MAIN" worktree add -q -b feature2 "$WORK2" HEAD

  bash "$SCRIPT" --project-root "$WORK" >/dev/null
  bash "$SCRIPT" --project-root "$WORK2" >/dev/null
  grep -qx "      - GIT_DIR=/git-common/worktrees/$(basename "$WORK")" "$MAIN/.git/worktrees/$(basename "$WORK")/crew-compose.override.yml"
  grep -qx "      - GIT_DIR=/git-common/worktrees/$(basename "$WORK2")" "$MAIN/.git/worktrees/$(basename "$WORK2")/crew-compose.override.yml"
  git -C "$MAIN" worktree remove --force "$WORK2"
}

@test "the main checkout's override lands in .git/ and has no GIT_* entries" {
  _git_fixture
  run bash "$SCRIPT" --project-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -f "$MAIN/.git/crew-compose.override.yml" ]
  ! grep -q 'GIT_' "$MAIN/.git/crew-compose.override.yml" || false
  [ ! -e "$MAIN/docker-compose.override.yml" ]
}

@test "a project's own committed docker-compose.override.yml is left byte-identical" {
  _git_fixture
  printf 'services:\n  app:\n    environment:\n      - MINE=1\n' > "$MAIN/docker-compose.override.yml"
  git -C "$MAIN" add -A && git -C "$MAIN" commit -q -m own-override
  before="$(cksum < "$MAIN/docker-compose.override.yml")"
  WORK="${MAIN}-wt"
  git -C "$MAIN" worktree add -q -b feature "$WORK" HEAD

  bash "$SCRIPT" --project-root "$MAIN" >/dev/null
  bash "$SCRIPT" --project-root "$WORK" >/dev/null
  [ "$(cksum < "$MAIN/docker-compose.override.yml")" = "$before" ]
  [ "$(cksum < "$WORK/docker-compose.override.yml")" = "$before" ]
  [ ! -L "$WORK/docker-compose.override.yml" ]
}
