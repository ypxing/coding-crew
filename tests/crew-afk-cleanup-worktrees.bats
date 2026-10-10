#!/usr/bin/env bats

# Tests for cleanup-worktrees.sh — sprint worktree/branch teardown.
# Pattern follows tests/verify-worktree.bats: a temp git repo per test.

load helpers/fake-docker

CLEANUP_SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/cleanup-worktrees.sh"
GEN_OVERRIDE="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/gen-override.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git commit -q --allow-empty -m "initial"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# Create a worktree on <branch> with a commit, then merge it into the current
# branch so the branch tip is contained in HEAD (the "merged" shape).
make_merged_worktree() {
  local branch="$1" path="$TEMP_DIR/.scratch/worktrees/$1"
  git worktree add -q -b "$branch" "$path" HEAD
  echo x > "$path/f-$(echo "$branch" | tr '/' '-')"
  git -C "$path" add -A
  git -C "$path" commit -q -m "work on $branch"
  git merge -q --no-ff -m "merge $branch" "$branch"
}

make_unmerged_worktree() {
  local branch="$1" path="$TEMP_DIR/.scratch/worktrees/$1"
  git worktree add -q -b "$branch" "$path" HEAD
  echo x > "$path/f-$(echo "$branch" | tr '/' '-')"
  git -C "$path" add -A
  git -C "$path" commit -q -m "wip on $branch"
}

# ─── merged branches ─────────────────────────────────────────────────────────

@test "cleanup: removes worktree and branch ref for a merged branch" {
  make_merged_worktree "crew/feat/01-a"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --merged "crew/feat/01-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed crew/feat/01-a"* ]]

  refute_branch() { ! git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/crew/feat/01-a"; }
  refute_branch
  [ ! -d "$TEMP_DIR/.scratch/worktrees/crew/feat/01-a" ]
  ! git -C "$TEMP_DIR" worktree list | grep -q "crew/feat/01-a"
}

@test "cleanup: accepts comma-separated and repeated --merged" {
  make_merged_worktree "crew/feat/01-a"
  make_merged_worktree "crew/feat/02-b"
  make_merged_worktree "crew/feat/03-c"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" \
    --merged "crew/feat/01-a,crew/feat/02-b" --merged "crew/feat/03-c"
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed=3"* ]]
}

@test "cleanup: deletes a merged branch ref that has no worktree left" {
  make_merged_worktree "crew/feat/01-a"
  git worktree remove --force "$TEMP_DIR/.scratch/worktrees/crew/feat/01-a"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --merged "crew/feat/01-a"
  [ "$status" -eq 0 ]
  ! git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/crew/feat/01-a"
}

# ─── safety ──────────────────────────────────────────────────────────────────

@test "cleanup: never touches a --retain branch" {
  make_merged_worktree "crew/feat/01-a"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" \
    --merged "crew/feat/01-a" --retain "crew/feat/01-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept crew/feat/01-a (retained)"* ]]
  git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/crew/feat/01-a"
  [ -d "$TEMP_DIR/.scratch/worktrees/crew/feat/01-a" ]
}

@test "cleanup: keeps a swept branch whose commits are not in HEAD" {
  make_unmerged_worktree "crew/feat/01-a"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --feature-slug feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge status unknown"* ]]
  git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/crew/feat/01-a"
}

@test "cleanup: removes an explicitly merged branch after a squash rewrote history" {
  # crew-afk squashes *after* merging, so by cleanup time the merged branch tip
  # is no longer an ancestor of HEAD. An ancestry requirement would keep every
  # merged branch forever — the exact leak this script exists to stop.
  local base=$(git rev-parse HEAD)
  make_merged_worktree "crew/feat/01-a"
  git reset -q --soft "$base"
  git commit -q -m "squashed sprint commit"
  run git merge-base --is-ancestor "crew/feat/01-a" HEAD
  [ "$status" -ne 0 ]   # precondition: ancestry is genuinely broken

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --merged "crew/feat/01-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed crew/feat/01-a"* ]]
  ! git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/crew/feat/01-a"
}

@test "cleanup: keeps a worktree with uncommitted changes" {
  make_merged_worktree "crew/feat/01-a"
  echo dirty > "$TEMP_DIR/.scratch/worktrees/crew/feat/01-a/dirty.txt"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --merged "crew/feat/01-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
  [ -d "$TEMP_DIR/.scratch/worktrees/crew/feat/01-a" ]
}

@test "cleanup: --dry-run changes nothing" {
  make_merged_worktree "crew/feat/01-a"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --merged "crew/feat/01-a" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would remove crew/feat/01-a"* ]]
  git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/crew/feat/01-a"
  [ -d "$TEMP_DIR/.scratch/worktrees/crew/feat/01-a" ]
}

@test "cleanup: --force deletes an unmerged swept branch" {
  make_unmerged_worktree "crew/feat/01-a"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --feature-slug feat --force
  [ "$status" -eq 0 ]
  ! git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/crew/feat/01-a"
}

@test "cleanup: never removes the main worktree or its branch" {
  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --feature-slug feat
  [ "$status" -eq 0 ]
  [ -d "$TEMP_DIR/.git" ]
  git -C "$TEMP_DIR" rev-parse --verify --quiet HEAD
}

# ─── sweep ───────────────────────────────────────────────────────────────────

@test "cleanup: sweeps leftover crew/<feature-slug>/* worktrees not passed in" {
  make_merged_worktree "crew/feat/01-a"
  make_merged_worktree "crew/feat/02-b"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --feature-slug feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed=2"* ]]
}

@test "cleanup: leaves worktrees from another feature alone" {
  make_merged_worktree "crew/other/01-a"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --feature-slug feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed=0"* ]]
  git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/crew/other/01-a"
}

@test "cleanup: sweeps runtime-managed worktree-agent-* worktrees inside its own sprint's directory" {
  local path="$TEMP_DIR/.scratch/worktrees/crew/feat/01-a/.claude/worktrees/agent-deadbeef"
  git worktree add -q -b "worktree-agent-deadbeef" "$path" HEAD

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --feature-slug feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed worktree-agent-deadbeef"* ]]
  ! git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/worktree-agent-deadbeef"
  [ ! -d "$path" ]
}

@test "cleanup: leaves clean agent worktrees of another sprint or the main checkout alone" {
  local mine="$TEMP_DIR/.claude/worktrees/agent-user"
  local other="$TEMP_DIR/.scratch/worktrees/crew/other/01-a/.claude/worktrees/agent-x"
  git worktree add -q -b "worktree-agent-user" "$mine" HEAD
  git worktree add -q -b "worktree-agent-x" "$other" HEAD

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --feature-slug feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed=0"* ]]
  [ -d "$mine" ] && [ -d "$other" ]
  git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/worktree-agent-user"
  git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/worktree-agent-x"
}

@test "cleanup: honours CREW_WORKTREE_ROOT when matching its own sprint's agent worktrees" {
  local path="$TEMP_DIR/wt/crew/feat/01-a/.claude/worktrees/agent-cafe"
  git worktree add -q -b "worktree-agent-cafe" "$path" HEAD

  CREW_WORKTREE_ROOT=wt run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --feature-slug feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed worktree-agent-cafe"* ]]
}

@test "cleanup: is idempotent - a second run is a clean no-op" {
  make_merged_worktree "crew/feat/01-a"

  bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --feature-slug feat >/dev/null
  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --feature-slug feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed=0 kept=0 failed=0"* ]]
}

# ─── arguments ───────────────────────────────────────────────────────────────

@test "cleanup: rejects unknown arguments" {
  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "cleanup: errors when main root is not a git repository" {
  run bash "$CLEANUP_SCRIPT" --main-root "$(mktemp -d)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git repository"* ]]
}

# ─── dependency volumes no worktree maps to ──────────────────────────────────
#
# docker is a fake that keeps each named volume as a temp dir (helpers/fake-docker.bash).

# _volumes_setup — the fake docker first on PATH, and this repo's owner prefix in $PREFIX
_volumes_setup() {
  FAKE="$TEMP_DIR/.fake-docker"
  STUB="$TEMP_DIR/.fake-stub"
  export FAKE STUB
  install_fake_docker "$STUB" "$FAKE"
  export PATH="$STUB:$PATH"
  PREFIX="$(bash "$GEN_OVERRIDE" --project-root "$TEMP_DIR" --main-root "$TEMP_DIR" --query owner-prefix)"
}

# _vol <name> — a volume the fake docker knows
_vol() { mkdir -p "$FAKE/vols/$1"; }
_has_vol() { [ -d "$FAKE/vols/$1" ]; }

# _name_in_override <git-dir> <volume> — a live override that maps the volume
_name_in_override() {
  printf 'services:\n  app:\n    volumes:\n      - %s:/opt/app/node_modules\nvolumes:\n  %s:\n    name: %s\n' "$2" "$2" "$2" > "$1/crew-compose.override.yml"
}

@test "cleanup: removes this owner's volumes no live override names, and keeps the referenced ones" {
  _volumes_setup
  make_merged_worktree "crew/feat/01-a"
  make_unmerged_worktree "crew/other/02-b"
  _vol "${PREFIX}nm_root_00000001"   # the main checkout's override names it
  _vol "${PREFIX}nm_root_00000002"   # a live worktree's override names it
  _vol "${PREFIX}nm_root_00000003"   # the removed worktree's: nothing names it any more
  _vol "${PREFIX}nm_root_00000004"   # nobody's
  _name_in_override "$TEMP_DIR/.git" "${PREFIX}nm_root_00000001"
  _name_in_override "$(git -C "$TEMP_DIR/.scratch/worktrees/crew/other/02-b" rev-parse --path-format=absolute --git-dir)" "${PREFIX}nm_root_00000002"
  _name_in_override "$(git -C "$TEMP_DIR/.scratch/worktrees/crew/feat/01-a" rev-parse --path-format=absolute --git-dir)" "${PREFIX}nm_root_00000003"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --merged "crew/feat/01-a"
  [ "$status" -eq 0 ]
  _has_vol "${PREFIX}nm_root_00000001"
  _has_vol "${PREFIX}nm_root_00000002"
  ! _has_vol "${PREFIX}nm_root_00000003"
  ! _has_vol "${PREFIX}nm_root_00000004"
  [[ "$output" == *"removed volume ${PREFIX}nm_root_00000004"* ]]
  # the summary stays the last line
  [ "$(printf '%s\n' "$output" | tail -n 1)" = "CLEANUP: removed=1 kept=0 failed=0" ]
}

@test "cleanup: never touches a volume with another owner prefix (B7)" {
  _volumes_setup
  proj="${PREFIX%_????_}"               # wt_<proj>
  _vol "${proj}_ffff_nm_root_00000001"  # same project, another owner (another clone or host)
  _vol "wt_somebody_else_nm_root_00000001"
  _vol "${proj}_nm_root"                # an older install's volume, no owner component
  _vol "${PREFIX}nm_root_00000009"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR"
  [ "$status" -eq 0 ]
  _has_vol "${proj}_ffff_nm_root_00000001"
  _has_vol "wt_somebody_else_nm_root_00000001"
  _has_vol "${proj}_nm_root"
  ! _has_vol "${PREFIX}nm_root_00000009"
}

@test "cleanup: skips silently when docker volume rm fails" {
  _volumes_setup
  _vol "${PREFIX}nm_root_00000001"
  export FAKE_DOCKER_RM_FAIL=1

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR"
  [ "$status" -eq 0 ]
  _has_vol "${PREFIX}nm_root_00000001"
  [[ "$output" != *"volume"* ]]
  [[ "$output" != *"in use"* ]]
}

@test "cleanup: skips silently when no docker is on PATH" {
  _vol_dir="$TEMP_DIR/.nodocker-bin"
  mkdir -p "$_vol_dir"
  for t in bash git dirname basename cat rm mkdir date tr sort env uname hostname grep awk cut head tail sed mktemp mv ls find readlink; do
    command -v "$t" >/dev/null 2>&1 && ln -s "$(command -v "$t")" "$_vol_dir/$t"
  done
  run env PATH="$_vol_dir" bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed=0 kept=0 failed=0"* ]]
}

@test "cleanup: --dry-run leaves the volumes alone" {
  _volumes_setup
  _vol "${PREFIX}nm_root_00000001"

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR" --dry-run
  [ "$status" -eq 0 ]
  _has_vol "${PREFIX}nm_root_00000001"
}
