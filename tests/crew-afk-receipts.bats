#!/usr/bin/env bats

# Tests for the receipt gates that make crew-afk's pipeline self-enforcing.
#
# Two failures observed in a real sprint motivated these:
#   1. A branch whose VERIFY result was `fail` was merged anyway — the gate was
#      prose only, and merge-branches.sh would merge anything handed to it.
#   2. A second issue was closed off the *first* issue's branch, so `merged=2`
#      was reported after a single dispatch.
#
# The fix is mechanical: verify-worktree.sh writes a receipt naming the exact
# commit it verified, merge-branches.sh refuses to merge a crew branch without a
# matching receipt, and close-issue.sh refuses to close an issue without an
# acceptance-criteria receipt for that issue's own slug.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
RECEIPTS_SCRIPT="$REPO_ROOT/skills/crew-afk/scripts/receipts.sh"
MERGE_SCRIPT="$REPO_ROOT/skills/crew-afk/scripts/merge-branches.sh"
CLOSE_SCRIPT="$REPO_ROOT/skills/crew-afk/scripts/close-issue.sh"
VERIFY_SCRIPT="$REPO_ROOT/skills/crew-afk/scripts/verify-worktree.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  # macOS mktemp hands back /var/... which is a symlink to /private/var; git
  # reports the resolved path, so receipt paths would not match without this.
  TEMP_DIR=$(cd "$TEMP_DIR" && pwd -P)
  export TEMP_DIR
  export MAIN_ROOT="$TEMP_DIR/main"

  mkdir -p "$MAIN_ROOT"
  cd "$MAIN_ROOT"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git commit -q --allow-empty -m "initial"
  git checkout -q -b "feature/my-feature"

  export FEATURE_BRANCH="feature/my-feature"
  export DISPATCH_DIR="$MAIN_ROOT/.scratch/my-feature/dispatch"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# Create a worktree on branch crew/my-feature/<slug> with one commit.
_make_worktree() {
  local slug="$1"
  local wt="$MAIN_ROOT/.scratch/worktrees/crew/my-feature/$slug"
  mkdir -p "$(dirname "$wt")"
  git -C "$MAIN_ROOT" worktree add -q -b "crew/my-feature/$slug" "$wt" HEAD
  echo "$slug work" > "$wt/$slug.txt"
  git -C "$wt" add -A
  git -C "$wt" commit -q -m "$slug work"
  echo "$wt"
}

_write_issue() {
  local filename="$1"
  local dir="$MAIN_ROOT/.scratch/my-feature/issues/open"
  mkdir -p "$dir"
  cat > "$dir/$filename" <<'EOF'
# Test issue

Status: ready-for-agent

## Acceptance criteria
- something
EOF
  echo "$dir/$filename"
}

# ─── receipts.sh ─────────────────────────────────────────────────────────────

@test "receipts: write verify records the verified commit under the main root" {
  wt=$(_make_worktree "task-a")

  run bash "$RECEIPTS_SCRIPT" write verify --dir "$wt"
  [ "$status" -eq 0 ]

  [ -f "$DISPATCH_DIR/task-a.verify.ok" ]
  [ "$(cat "$DISPATCH_DIR/task-a.verify.ok")" = "$(git -C "$wt" rev-parse HEAD)" ]
}

@test "receipts: write ac records a receipt for the branch's own slug" {
  wt=$(_make_worktree "task-a")

  run bash "$RECEIPTS_SCRIPT" write ac --dir "$wt"
  [ "$status" -eq 0 ]
  [ -f "$DISPATCH_DIR/task-a.ac.ok" ]
}

@test "receipts: clear removes an existing receipt" {
  wt=$(_make_worktree "task-a")
  bash "$RECEIPTS_SCRIPT" write verify --dir "$wt"

  run bash "$RECEIPTS_SCRIPT" clear verify --dir "$wt"
  [ "$status" -eq 0 ]
  [ ! -f "$DISPATCH_DIR/task-a.verify.ok" ]
}

@test "receipts: write ac works from the main checkout after the worktree is gone" {
  wt=$(_make_worktree "task-a")
  git -C "$MAIN_ROOT" worktree remove --force "$wt"
  [ ! -d "$wt" ]

  cd "$MAIN_ROOT"
  run bash "$RECEIPTS_SCRIPT" write ac --branch "crew/my-feature/task-a"
  [ "$status" -eq 0 ]
  [ -f "$DISPATCH_DIR/task-a.ac.ok" ]
}

# ─── the ac receipt traces itself ────────────────────────────────────────────
#
# ACVERIFY was the one marker the orchestrator hand-wrote, as a second bash call
# beside `receipts.sh write ac`. Two calls for one event is one call too many, and a
# hand-written marker can be emitted for a gate that never ran. Writing the receipt
# *is* the event, so the script that writes it traces it — the same rule every other
# pipeline step already follows.

@test "receipts: write ac emits the ACVERIFY trace line itself" {
  wt=$(_make_worktree "task-a")
  export TRACE_LOG="$MAIN_ROOT/.scratch/my-feature/trace.log"

  run bash "$RECEIPTS_SCRIPT" write ac --dir "$wt"
  [ "$status" -eq 0 ]
  [ -f "$TRACE_LOG" ]
  grep -q '\[ACVERIFY\]' "$TRACE_LOG"
  grep -q 'branch=crew/my-feature/task-a' "$TRACE_LOG"
  grep -q 'result=all-met' "$TRACE_LOG"
}

@test "receipts: write verify does not trace ACVERIFY (verify-worktree owns VERIFY)" {
  wt=$(_make_worktree "task-a")
  export TRACE_LOG="$MAIN_ROOT/.scratch/my-feature/trace.log"

  run bash "$RECEIPTS_SCRIPT" write verify --dir "$wt"
  [ "$status" -eq 0 ]
  if [ -f "$TRACE_LOG" ]; then
    ! grep -q '\[ACVERIFY\]' "$TRACE_LOG"
  fi
}

@test "receipts: write ac still succeeds when no trace log can be resolved" {
  # Tracing is observability: it must never fail the gate that is making progress.
  wt=$(_make_worktree "task-a")
  unset TRACE_LOG
  run env -u TRACE_LOG -u MAIN_ROOT bash "$RECEIPTS_SCRIPT" write ac --dir "$wt"
  [ "$status" -eq 0 ]
  [ -f "$DISPATCH_DIR/task-a.ac.ok" ]
}

@test "parity: nothing outside receipts.sh writes the ACVERIFY trace marker" {
  # Writing the receipt *is* the event, so the script traces it. A second writer — a body,
  # or the orchestrator beside its own receipt call — is a marker that can be emitted for a
  # gate that never wrote a receipt.
  for f in "$REPO_ROOT"/skills/crew-afk/*.SKILL.md "$REPO_ROOT"/orchestrator/lib/*.mjs; do
    if grep -q 'ACVERIFY' "$f"; then
      echo "$(basename "$f") emits ACVERIFY by hand beside the receipt write" >&2
      return 1
    fi
  done
  grep -q 'ACVERIFY' "$RECEIPTS_SCRIPT"
}

@test "receipts: write refuses a directory whose branch is not a crew branch" {
  run bash "$RECEIPTS_SCRIPT" write verify --dir "$MAIN_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"crew/"* ]]
}

# ─── merge gate ──────────────────────────────────────────────────────────────

@test "merge gate: crew branch without a verify receipt is not merged" {
  _make_worktree "task-a" >/dev/null

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a"
  [ "$status" -ne 0 ]
  [[ "$output" == *"verification receipt"* ]]

  # The branch's work must not be on the feature branch.
  run git -C "$MAIN_ROOT" log "$FEATURE_BRANCH" --oneline
  [[ "$output" != *"task-a work"* ]]
}

@test "merge gate: crew branch with a matching verify receipt merges" {
  wt=$(_make_worktree "task-a")
  bash "$RECEIPTS_SCRIPT" write verify --dir "$wt"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"success"* ]]

  run git -C "$MAIN_ROOT" log "$FEATURE_BRANCH" --oneline
  [[ "$output" == *"task-a work"* ]]
}

@test "merge gate: receipt for an older commit is rejected as stale" {
  wt=$(_make_worktree "task-a")
  bash "$RECEIPTS_SCRIPT" write verify --dir "$wt"

  # Worker pushes another commit after verification — the receipt no longer
  # vouches for what is about to merge.
  echo "more" >> "$wt/task-a.txt"
  git -C "$wt" commit -q -am "unverified extra work"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stale"* ]]
}

@test "merge gate: non-crew branches are unaffected by the gate" {
  git -C "$MAIN_ROOT" checkout -q -b "some/other-branch"
  echo "x" > "$MAIN_ROOT/other.txt"
  git -C "$MAIN_ROOT" add -A
  git -C "$MAIN_ROOT" commit -q -m "other work"
  git -C "$MAIN_ROOT" checkout -q "$FEATURE_BRANCH"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "some/other-branch"
  [ "$status" -eq 0 ]
}

@test "merge gate: CREW_RECEIPTS=off bypasses the gate" {
  _make_worktree "task-a" >/dev/null

  CREW_RECEIPTS=off run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a"
  [ "$status" -eq 0 ]
}

@test "merge gate: an ungated branch still merges when a sibling is gated out" {
  _make_worktree "task-a" >/dev/null
  wt_b=$(_make_worktree "task-b")
  bash "$RECEIPTS_SCRIPT" write verify --dir "$wt_b"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a" "crew/my-feature/task-b"
  [ "$status" -ne 0 ]

  run git -C "$MAIN_ROOT" log "$FEATURE_BRANCH" --oneline
  [[ "$output" == *"task-b work"* ]]
  [[ "$output" != *"task-a work"* ]]
}

# ─── verify-worktree.sh receipt emission ─────────────────────────────────────

@test "verify-worktree: writes a receipt when all checks pass" {
  wt=$(_make_worktree "task-a")
  cat > "$wt/Makefile" <<'EOF'
test:
	@true
EOF
  git -C "$wt" add -A && git -C "$wt" commit -q -m "add makefile"

  run bash "$VERIFY_SCRIPT" --dir "$wt"
  [ "$status" -eq 0 ]
  [ -f "$DISPATCH_DIR/task-a.verify.ok" ]
  [ "$(cat "$DISPATCH_DIR/task-a.verify.ok")" = "$(git -C "$wt" rev-parse HEAD)" ]
}

@test "verify-worktree: writes no receipt when a check fails" {
  wt=$(_make_worktree "task-a")
  cat > "$wt/Makefile" <<'EOF'
test:
	@false
EOF
  git -C "$wt" add -A && git -C "$wt" commit -q -m "add failing makefile"

  run bash "$VERIFY_SCRIPT" --dir "$wt"
  [ "$status" -ne 0 ]
  [ ! -f "$DISPATCH_DIR/task-a.verify.ok" ]
}

@test "verify-worktree: a failing run clears a receipt from an earlier pass" {
  wt=$(_make_worktree "task-a")
  bash "$RECEIPTS_SCRIPT" write verify --dir "$wt"
  [ -f "$DISPATCH_DIR/task-a.verify.ok" ]

  cat > "$wt/Makefile" <<'EOF'
test:
	@false
EOF
  git -C "$wt" add -A && git -C "$wt" commit -q -m "add failing makefile"

  run bash "$VERIFY_SCRIPT" --dir "$wt"
  [ "$status" -ne 0 ]
  [ ! -f "$DISPATCH_DIR/task-a.verify.ok" ]
}

# ─── close gate ──────────────────────────────────────────────────────────────

@test "close gate: issue without an ac receipt is not closed" {
  issue=$(_write_issue "01-task-a.md")

  run bash "$CLOSE_SCRIPT" "$issue"
  [ "$status" -ne 0 ]
  [[ "$output" == *"acceptance-criteria receipt"* ]]
  [ -f "$issue" ]
  grep -q "Status: ready-for-agent" "$issue"
}

@test "close gate: issue with an ac receipt for its own slug is closed" {
  issue=$(_write_issue "01-task-a.md")
  mkdir -p "$DISPATCH_DIR"
  echo "ok" > "$DISPATCH_DIR/task-a.ac.ok"

  run bash "$CLOSE_SCRIPT" "$issue"
  [ "$status" -eq 0 ]
  [ ! -f "$issue" ]
  grep -q "Status: done" "$MAIN_ROOT/.scratch/my-feature/issues/done/01-task-a.md"
}

@test "close gate: a sibling's ac receipt does not close this issue" {
  # The exact bug: issue 02 closed off issue 01's verified branch.
  _write_issue "01-task-a.md" >/dev/null
  issue_b=$(_write_issue "02-task-b.md")
  mkdir -p "$DISPATCH_DIR"
  echo "ok" > "$DISPATCH_DIR/task-a.ac.ok"

  run bash "$CLOSE_SCRIPT" "$issue_b"
  [ "$status" -ne 0 ]
  [ -f "$issue_b" ]
}

@test "close gate: CREW_RECEIPTS=off bypasses the gate" {
  issue=$(_write_issue "01-task-a.md")

  CREW_RECEIPTS=off run bash "$CLOSE_SCRIPT" "$issue"
  [ "$status" -eq 0 ]
}

@test "close gate: an already-closed issue still reconciles without a receipt" {
  # Re-run idempotency must not regress: the end state is already correct.
  done_dir="$MAIN_ROOT/.scratch/my-feature/issues/done"
  mkdir -p "$done_dir" "$MAIN_ROOT/.scratch/my-feature/issues/open"
  printf 'Status: complete\n' > "$done_dir/01-task-a.md"

  run bash "$CLOSE_SCRIPT" "$MAIN_ROOT/.scratch/my-feature/issues/open/01-task-a.md"
  [ "$status" -eq 0 ]
  grep -q "Status: done" "$done_dir/01-task-a.md"
}

# ─── one writer, for every platform ──────────────────────────────────────────
#
# The gates only hold if the receipts are actually written. That used to be a promise each
# platform body made ("record an ac receipt after all-met", "the merge gate is mechanical")
# and four promises are four things to drift; it is one call site now, in the pipeline every
# platform runs, and the end-to-end assertion that it happens is
# tests/orchestrator/sprint.test.mjs ("the gates run in order: verify → AC receipt → merge →
# close") plus the ac.ok / verify.ok existence checks in the clean-merge and criteria-unmet
# cases.

@test "parity: the pipeline writes both receipts, from one place, for every platform" {
  pipeline="$REPO_ROOT/orchestrator/lib/pipeline.mjs"
  grep -q 'receipts.sh' "$pipeline"
  grep -q '"write", "ac"' "$pipeline"
  # And the verify receipt stays with the script that ran the checks.
  grep -q 'write verify' "$REPO_ROOT/skills/crew-afk/scripts/verify-worktree.sh"
}
