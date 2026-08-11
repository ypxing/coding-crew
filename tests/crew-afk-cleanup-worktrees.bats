#!/usr/bin/env bats

# Tests for cleanup-worktrees.sh — sprint worktree/branch teardown.
# Pattern follows tests/verify-worktree.bats: a temp git repo per test.

CLEANUP_SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/cleanup-worktrees.sh"

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

@test "cleanup: sweeps runtime-managed worktree-agent-* worktrees" {
  local path="$TEMP_DIR/.claude/worktrees/agent-deadbeef"
  git worktree add -q -b "worktree-agent-deadbeef" "$path" HEAD

  run bash "$CLEANUP_SCRIPT" --main-root "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed worktree-agent-deadbeef"* ]]
  ! git -C "$TEMP_DIR" rev-parse --verify --quiet "refs/heads/worktree-agent-deadbeef"
  [ ! -d "$path" ]
}

@test "cleanup: is idempotent — a second run is a clean no-op" {
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
