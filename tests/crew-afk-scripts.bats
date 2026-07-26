#!/usr/bin/env bats

# Tests for merge-branches.sh and close-issue.sh
# Following the pattern in tests/squash-commits.bats:
#   - temp git repo per test
#   - assert exit codes and repo state

MERGE_SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/merge-branches.sh"
CLOSE_SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/close-issue.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git commit --allow-empty -m "initial"

  # Create feature branch
  git checkout -q -b "feature/my-feature"

  export FEATURE_BRANCH="feature/my-feature"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# ─── merge-branches.sh ────────────────────────────────────────────────────────

@test "merge-branches: clean merge exits zero and reports success" {
  # Create a branch with a commit
  git checkout -q -b "crew/my-feature/task-a"
  echo "change" > work.txt && git add work.txt && git commit -q -m "task-a work"
  git checkout -q "$FEATURE_BRANCH"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"crew/my-feature/task-a"*"success"* ]] || [[ "$output" == *"merged"* ]]
}

@test "merge-branches: already-merged branch exits zero and reports success without re-merging" {
  # Create branch, merge it, then try to merge again
  git checkout -q -b "crew/my-feature/task-b"
  echo "change" > work2.txt && git add work2.txt && git commit -q -m "task-b work"
  git checkout -q "$FEATURE_BRANCH"
  git merge --no-ff "crew/my-feature/task-b" -m "merge task-b" -q

  # Verify branch is already merged (git log check)
  EMPTY=$(git log HEAD..crew/my-feature/task-b --oneline)
  [ -z "$EMPTY" ]

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-b"
  [ "$status" -eq 0 ]
}

@test "merge-branches: conflicting merge exits non-zero" {
  # Create conflicting branch
  git checkout -q -b "crew/my-feature/conflict-branch"
  echo "version A" > conflict.txt && git add conflict.txt && git commit -q -m "version A"
  git checkout -q "$FEATURE_BRANCH"

  # Create conflicting change on feature branch
  echo "version B" > conflict.txt && git add conflict.txt && git commit -q -m "version B"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/conflict-branch"
  [ "$status" -ne 0 ]
}

@test "merge-branches: conflicting merge leaves no conflict markers" {
  git checkout -q -b "crew/my-feature/conflict-branch2"
  echo "version A" > conflict2.txt && git add conflict2.txt && git commit -q -m "version A"
  git checkout -q "$FEATURE_BRANCH"
  echo "version B" > conflict2.txt && git add conflict2.txt && git commit -q -m "version B"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/conflict-branch2"
  [ "$status" -ne 0 ]

  # No conflict markers in the repo
  run grep -r "<<<<<<" "$TEMP_DIR" --include="*.txt"
  [ "$status" -ne 0 ]  # grep exits non-zero when no matches found

  # No unmerged paths
  run git status --short
  [[ "$output" != *"UU "* ]]
  [[ "$output" != *"AA "* ]]
}

@test "merge-branches: failing branch does not abort processing of remaining branches" {
  # Create a good branch
  git checkout -q -b "crew/my-feature/good-branch"
  echo "good change" > good.txt && git add good.txt && git commit -q -m "good work"
  git checkout -q "$FEATURE_BRANCH"

  # Create conflicting branch
  git checkout -q -b "crew/my-feature/bad-branch"
  echo "conflict A" > conflict3.txt && git add conflict3.txt && git commit -q -m "conflict A"
  git checkout -q "$FEATURE_BRANCH"
  echo "conflict B" > conflict3.txt && git add conflict3.txt && git commit -q -m "conflict B on feature"

  # Run: bad branch first, then good branch
  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/bad-branch" "crew/my-feature/good-branch"
  # Exit non-zero because at least one failed
  [ "$status" -ne 0 ]

  # But the good branch was processed — its file should exist in HEAD
  run git show HEAD:good.txt
  [ "$status" -eq 0 ]
  [[ "$output" == "good change" ]]
}

@test "merge-branches: multiple clean merges all succeed" {
  git checkout -q -b "crew/my-feature/branch-c"
  echo "c" > c.txt && git add c.txt && git commit -q -m "c work"
  git checkout -q "$FEATURE_BRANCH"

  git checkout -q -b "crew/my-feature/branch-d"
  echo "d" > d.txt && git add d.txt && git commit -q -m "d work"
  git checkout -q "$FEATURE_BRANCH"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/branch-c" "crew/my-feature/branch-d"
  [ "$status" -eq 0 ]
}

# ─── close-issue.sh ──────────────────────────────────────────────────────────

_make_issue() {
  local slug="$1"
  mkdir -p "$TEMP_DIR/.scratch/my-feature/issues/open"
  mkdir -p "$TEMP_DIR/.scratch/my-feature/issues/done"
  cat > "$TEMP_DIR/.scratch/my-feature/issues/open/${slug}.md" <<EOF
Status: ready-for-agent

## What to build

Some task

## Acceptance criteria

- [x] Done
EOF
  echo "$TEMP_DIR/.scratch/my-feature/issues/open/${slug}.md"
}

@test "close-issue: updates Status line to done" {
  ISSUE_PATH=$(_make_issue "01-my-task")

  run bash "$CLOSE_SCRIPT" "$ISSUE_PATH"
  [ "$status" -eq 0 ]

  run grep "^Status:" "$TEMP_DIR/.scratch/my-feature/issues/done/01-my-task.md"
  [ "$status" -eq 0 ]
  [[ "$output" == "Status: done" ]]
}

@test "close-issue: moves file to sibling done directory" {
  ISSUE_PATH=$(_make_issue "02-another-task")

  run bash "$CLOSE_SCRIPT" "$ISSUE_PATH"
  [ "$status" -eq 0 ]

  # File no longer in open
  [ ! -f "$TEMP_DIR/.scratch/my-feature/issues/open/02-another-task.md" ]

  # File exists in done
  [ -f "$TEMP_DIR/.scratch/my-feature/issues/done/02-another-task.md" ]
}

@test "close-issue: done directory is created if it does not exist" {
  # Remove done dir to ensure it gets created
  ISSUE_PATH=$(_make_issue "03-new-task")
  rmdir "$TEMP_DIR/.scratch/my-feature/issues/done"

  run bash "$CLOSE_SCRIPT" "$ISSUE_PATH"
  [ "$status" -eq 0 ]

  [ -f "$TEMP_DIR/.scratch/my-feature/issues/done/03-new-task.md" ]
}

@test "close-issue: exits non-zero when issue file does not exist" {
  run bash "$CLOSE_SCRIPT" "/nonexistent/path/to/issue.md"
  [ "$status" -ne 0 ]
}

# ─── portability: no non-portable in-place sed (macOS/BSD) ───────────────────
# GNU sed accepts a bare `-i`; BSD/macOS sed reads the NEXT argument as a backup
# suffix and then finds no script, so the command fails and set -e aborts.
# `-i''` is not a fix — the shell strips the empty quotes, yielding a bare `-i`.

@test "crew-afk scripts use no non-portable in-place sed" {
  SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts"
  # Matches `sed -i` and `sed -i''`/`sed -i""`, both of which reach sed as bare -i.
  # Strip comment lines first so explanatory prose does not trip the check.
  ! cat "$SCRIPTS_DIR"/*.sh | grep -vE '^\s*#' | grep -qE "sed +-i( |'')"
}

@test "close-issue: rewrites Status without relying on in-place sed" {
  # Ignore comment lines — the explanation of why in-place sed is avoided
  # legitimately mentions it.
  ! grep -vE '^\s*#' "$CLOSE_SCRIPT" | grep -qE "sed +-i"
}

@test "close-issue: leaves no temp or backup file behind" {
  ISSUE_PATH=$(_make_issue "07-portable")

  run bash "$CLOSE_SCRIPT" "$ISSUE_PATH"
  [ "$status" -eq 0 ]

  # Only the moved file should exist — no .tmp/.bak siblings in either directory.
  run bash -c "find '$TEMP_DIR/.scratch/my-feature/issues' -type f | sort"
  [ "$status" -eq 0 ]
  [[ "$output" == *"done/07-portable.md" ]]
  [[ "$output" != *".tmp"* ]]
  [[ "$output" != *".bak"* ]]
}

@test "tracker template documents no non-portable in-place sed" {
  TEMPLATE="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/docs/templates/trackers/local.md"
  ! grep -vE '^\s*(#|>)' "$TEMPLATE" | grep -qE "sed +-i( |'')"
}
