#!/usr/bin/env bats

# Tests for the receipt gates that make crew-afk's pipeline self-enforcing.
#
# Two failures observed in a real sprint motivated these:
#   1. A branch whose VERIFY result was `fail` was merged anyway — the gate was
#      prose only, and merge-branches.sh would merge anything handed to it.
#   2. A second issue was closed off the *first* issue's branch, so `merged=2`
#      was reported after a single dispatch.
#
# The fix is mechanical: verify-worktree.sh writes a record naming the exact
# commit it verified and its verdict, merge-branches.sh refuses to merge a crew branch without a
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

# _write_record <worktree> [verdict] [file-stem] — a verify-worktree.sh record by hand.
_write_record() {
  local wt="$1" verdict="${2:-pass}" slug
  slug=$(basename "$wt")
  mkdir -p "$DISPATCH_DIR"
  printf '{"branch": "crew/my-feature/%s", "commit": "%s", "verdict": "%s", "checks": [], "not_configured": []}\n' \
    "$slug" "$(git -C "$wt" rev-parse HEAD)" "$verdict" > "$DISPATCH_DIR/${3:-$slug}.verify.json"
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

@test "receipts: write verify is refused — the record is verify-worktree.sh's own" {
  wt=$(_make_worktree "task-a")

  run bash "$RECEIPTS_SCRIPT" write verify --dir "$wt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"verify-worktree.sh"* ]]
}

@test "receipts: path verify names the record by stem when given, the bare slug otherwise" {
  wt=$(_make_worktree "task-a")

  run bash "$RECEIPTS_SCRIPT" path verify --dir "$wt" --stem 03-task-a
  [ "$output" = "$DISPATCH_DIR/03-task-a.verify.json" ]
  run bash "$RECEIPTS_SCRIPT" path verify --dir "$wt"
  [ "$output" = "$DISPATCH_DIR/task-a.verify.json" ]
}

@test "receipts: write ac records a receipt for the branch's own slug" {
  wt=$(_make_worktree "task-a")

  run bash "$RECEIPTS_SCRIPT" write ac --dir "$wt"
  [ "$status" -eq 0 ]
  [ -f "$DISPATCH_DIR/task-a.ac.ok" ]
}

@test "receipts: clear removes an existing receipt" {
  wt=$(_make_worktree "task-a")
  _write_record "$wt"

  run bash "$RECEIPTS_SCRIPT" clear verify --dir "$wt"
  [ "$status" -eq 0 ]
  [ ! -f "$DISPATCH_DIR/task-a.verify.json" ]
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

# A receipt that was never written must not be reported as written: the pipeline treats
# exit 0 as "the gate passed", and close-issue.sh would later refuse the close for a
# reason that points nowhere near the real one. A directory at the receipt path makes the
# write fail even as root, where a chmod would not.
@test "receipts: write fails, and claims nothing, when the receipt file cannot be written" {
  wt=$(_make_worktree "task-a")
  mkdir -p "$DISPATCH_DIR/task-a.ac.ok"

  run bash "$RECEIPTS_SCRIPT" write ac --dir "$wt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot write"* ]]
  [[ "$output" != *"RECEIPT: wrote"* ]]
}

@test "receipts: write fails when the dispatch directory cannot be created" {
  wt=$(_make_worktree "task-a")
  mkdir -p "$(dirname "$DISPATCH_DIR")"
  : > "$DISPATCH_DIR"

  run bash "$RECEIPTS_SCRIPT" write ac --dir "$wt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot write"* ]]
  [[ "$output" != *"RECEIPT: wrote"* ]]
}

# A write that fails partway (a full disk) must not leave a receipt behind: `check ac`
# tests only for the file, so an empty one would pass a later hand-run close-issue.sh.
# /dev/full at the receipt path is a full disk on demand.
@test "receipts: a write that fails partway leaves no receipt the gate accepts" {
  [ -e /dev/full ] || skip "no /dev/full on this platform"
  wt=$(_make_worktree "task-a")
  mkdir -p "$DISPATCH_DIR"
  ln -s /dev/full "$DISPATCH_DIR/task-a.ac.ok"

  run bash "$RECEIPTS_SCRIPT" write ac --dir "$wt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot write"* ]]
  [ ! -e "$DISPATCH_DIR/task-a.ac.ok" ]
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
  run bash "$RECEIPTS_SCRIPT" write ac --dir "$MAIN_ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"crew/"* ]]
}

# ─── merge gate ──────────────────────────────────────────────────────────────

@test "receipts: check ac --at-tip passes only for a receipt of the branch's current tip" {
  wt=$(_make_worktree "task-a")
  cd "$MAIN_ROOT"
  bash "$RECEIPTS_SCRIPT" write ac --branch "crew/my-feature/task-a" >/dev/null

  run bash "$RECEIPTS_SCRIPT" check ac --branch "crew/my-feature/task-a" --at-tip
  [ "$status" -eq 0 ]
  [[ "$output" == *"criteria-verified at $(git rev-parse crew/my-feature/task-a)"* ]]

  # A commit after the review: the receipt still exists, but no longer vouches for the tip.
  echo more > "$wt/more.txt"; git -C "$wt" add -A; git -C "$wt" commit -q -m more
  run bash "$RECEIPTS_SCRIPT" check ac --branch "crew/my-feature/task-a" --at-tip
  [ "$status" -ne 0 ]
  [[ "$output" == *"not at its tip"* ]]
  # Existence-only (the close gate's question) is unchanged.
  run bash "$RECEIPTS_SCRIPT" check ac --branch "crew/my-feature/task-a"
  [ "$status" -eq 0 ]
}

@test "receipts: check ac --at-tip rejects a receipt that names no commit" {
  _make_worktree "task-a" >/dev/null
  mkdir -p "$DISPATCH_DIR"; echo ok > "$DISPATCH_DIR/task-a.ac.ok"
  cd "$MAIN_ROOT"
  run bash "$RECEIPTS_SCRIPT" check ac --branch "crew/my-feature/task-a" --at-tip
  [ "$status" -ne 0 ]
}

@test "merge gate: uncommitted changes the merge would overwrite are main-tree-dirty, not a conflict" {
  echo base > "$MAIN_ROOT/shared.txt"; git -C "$MAIN_ROOT" add -A; git -C "$MAIN_ROOT" commit -q -m base
  wt=$(_make_worktree "task-a")
  echo branch > "$wt/shared.txt"; git -C "$wt" commit -q -am "edit shared"
  _write_record "$wt"
  echo local > "$MAIN_ROOT/shared.txt"

  cd "$MAIN_ROOT"
  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a"
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed (main-tree-dirty — uncommitted changes in $MAIN_ROOT would be overwritten: shared.txt)"* ]]
  [[ "$output" != *"conflict — aborted"* ]]
  # Nothing was touched: the local edit is still there, and nothing merged.
  [ "$(cat "$MAIN_ROOT/shared.txt")" = "local" ]
  run git -C "$MAIN_ROOT" log "$FEATURE_BRANCH" --oneline
  [[ "$output" != *"edit shared"* ]]
}

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
  _write_record "$wt"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"success"* ]]

  run git -C "$MAIN_ROOT" log "$FEATURE_BRANCH" --oneline
  [[ "$output" == *"task-a work"* ]]
}

@test "merge gate: a record named with the issue-number prefix is found from the branch alone" {
  wt=$(_make_worktree "task-a")
  _write_record "$wt" pass "07-task-a"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a"
  [ "$status" -eq 0 ]
}

@test "merge gate: a sibling whose slug ends in this one's does not stand in for it" {
  wt=$(_make_worktree "task-a")
  _write_record "$wt" pass "07-other-task-a"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a"
  [ "$status" -ne 0 ]
}

@test "merge gate: a record with a fail verdict for the current tip is not a receipt" {
  wt=$(_make_worktree "task-a")
  _write_record "$wt" fail

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a"
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not pass verification"* ]]
}

@test "merge gate: receipt for an older commit is rejected as stale" {
  wt=$(_make_worktree "task-a")
  _write_record "$wt"

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
  _write_record "$wt_b"

  run bash "$MERGE_SCRIPT" "$FEATURE_BRANCH" "crew/my-feature/task-a" "crew/my-feature/task-b"
  [ "$status" -ne 0 ]

  run git -C "$MAIN_ROOT" log "$FEATURE_BRANCH" --oneline
  [[ "$output" == *"task-b work"* ]]
  [[ "$output" != *"task-a work"* ]]
}

# ─── verify-worktree.sh record emission ─────────────────────────────────────

@test "verify-worktree: writes a receipt when all checks pass" {
  wt=$(_make_worktree "task-a")
  cat > "$wt/Makefile" <<'EOF'
test:
	@true
EOF
  git -C "$wt" add -A && git -C "$wt" commit -q -m "add makefile"

  run bash "$VERIFY_SCRIPT" --dir "$wt" --stem 01-task-a
  [ "$status" -eq 0 ]
  rec="$DISPATCH_DIR/01-task-a.verify.json"
  [ -f "$rec" ]
  grep -q "\"commit\": \"$(git -C "$wt" rev-parse HEAD)\"" "$rec"
  grep -q '"verdict": "pass"' "$rec"
  grep -q '"category": "test", "command": "make test", "result": "pass", "exit": 0' "$rec"
  # Every check's full output outlives the worktree, beside the record.
  grep -q "\"log\": \"$DISPATCH_DIR/01-task-a.verify-test.log\"" "$rec"
  [ -f "$DISPATCH_DIR/01-task-a.verify-test.log" ]
  [ ! -e "$wt/.scratch/verify-test.log" ]
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$rec"

  cd "$MAIN_ROOT"
  run bash "$RECEIPTS_SCRIPT" check verify --branch crew/my-feature/task-a
  [ "$status" -eq 0 ]
}

@test "verify-worktree: the record runs every cached check and names the ones set to null" {
  wt=$(_make_worktree "task-a")
  mkdir -p "$MAIN_ROOT/.coding-crew"
  echo '{"test": "true", "lint": null, "typecheck": null, "install": "true", "coverage": "echo c", "integration": null, "install_mode": "host"}' \
    > "$MAIN_ROOT/.coding-crew/dev-commands.json"

  run bash "$VERIFY_SCRIPT" --dir "$wt" --stem 01-task-a
  [ "$status" -eq 0 ]
  rec="$DISPATCH_DIR/01-task-a.verify.json"
  grep -q '"category": "coverage", "command": "echo c", "result": "pass"' "$rec"
  grep -q '"not_configured": \["integration"\]' "$rec"
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' "$rec"
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
  grep -q '"verdict": "fail"' "$DISPATCH_DIR/task-a.verify.json"
  grep -q '"result": "fail", "exit": 2' "$DISPATCH_DIR/task-a.verify.json"
}

@test "verify-worktree: a failing run revokes a receipt from an earlier pass" {
  wt=$(_make_worktree "task-a")
  _write_record "$wt"

  cat > "$wt/Makefile" <<'EOF'
test:
	@false
EOF
  git -C "$wt" add -A && git -C "$wt" commit -q -m "add failing makefile"

  run bash "$VERIFY_SCRIPT" --dir "$wt"
  [ "$status" -ne 0 ]
  cd "$MAIN_ROOT"
  run bash "$RECEIPTS_SCRIPT" check verify --branch crew/my-feature/task-a
  [ "$status" -ne 0 ]
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
# close") plus the ac.ok / verify.json existence checks in the clean-merge and criteria-unmet
# cases.

@test "parity: the pipeline writes both receipts, from one place, for every platform" {
  pipeline="$REPO_ROOT/orchestrator/lib/pipeline.mjs"
  grep -q 'receipts.sh' "$pipeline"
  grep -q '"write", "ac"' "$pipeline"
  # And the verify record stays with the script that ran the checks.
  grep -q 'path verify' "$REPO_ROOT/skills/crew-afk/scripts/verify-worktree.sh"
}
