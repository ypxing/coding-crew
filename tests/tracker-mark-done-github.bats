#!/usr/bin/env bats

# mark-issue-done.sh / close-issue.sh — github backend.
#
# mark-issue-done.sh re-fetches the issue body live (never a cached copy the caller
# might be holding) and marks it done by swapping ready-for-agent for awaiting-merge —
# never `gh issue close`: the work is only on a branch, and the PR's `Closes #n` closes
# the issue on merge. close-issue.sh delegates to it. The local backend's
# `.orchestrated`-marker / `--force` / exit-3-and-4 contract holds identically.
#
# `gh` is stubbed on PATH throughout: these tests pin argument shape and call
# count, not real GitHub behaviour.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
MARK_DONE="$REPO_ROOT/scripts/tracker/mark-issue-done.sh"
CLOSE_SCRIPT="$REPO_ROOT/skills/crew-afk/scripts/close-issue.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  export MAIN_ROOT="$TEMP_DIR"

  mkdir -p "$MAIN_ROOT/.coding-crew/docs" "$MAIN_ROOT/.coding-crew/scripts"
  cat > "$MAIN_ROOT/.coding-crew/docs/issue-tracker.md" <<'EOF'
---
tracker: github
---

# Issue tracker: GitHub Issues
EOF
  # close-issue.sh is not a sibling of tracker-config.sh (mark-issue-done.sh is —
  # they install together under .coding-crew/scripts/); reproduce that installed
  # layout so close-issue.sh's lookup relative to MAIN_ROOT actually finds it.
  cp "$REPO_ROOT/scripts/tracker/tracker-config.sh" "$MAIN_ROOT/.coding-crew/scripts/tracker-config.sh"
  cp "$REPO_ROOT/scripts/tracker/mark-issue-done.sh" "$MAIN_ROOT/.coding-crew/scripts/mark-issue-done.sh"
  # mark-issue-done.sh delegates to the tracker CLI, installed beside the scripts.
  cp -R "$REPO_ROOT/tracker" "$MAIN_ROOT/.coding-crew/tracker"

  STUB="$TEMP_DIR/.stub"
  mkdir -p "$STUB"
  export PATH="$STUB:$PATH"

  GH_LOG="$TEMP_DIR/gh.log"
  export GH_LOG
  : > "$GH_LOG"
  GH_BODY_FILE="$TEMP_DIR/gh-body.txt"
  export GH_BODY_FILE

  unset CREW_ORCHESTRATED SPRINT_DIR FEATURE_SLUG CREW_RECEIPTS
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# stub_gh <edit-exit> — a fake `gh` that logs every invocation (one per line) and:
#   - `issue view ... --json body ...` prints the current contents of $GH_BODY_FILE
#   - `issue edit ...` exits with the given code
#   - `label create ...` and `issue close ...` exit 0
stub_gh() {
  local edit_rc="${1:-0}"
  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$1 \$2" in
  "issue view")
    cat "$GH_BODY_FILE"
    exit 0
    ;;
  "issue edit")
    exit $edit_rc
    ;;
  "label create"|"issue close")
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$STUB/gh"
  # github.mjs spawns gh from Node, which on Windows never reads a shebang and won't run a
  # .cmd, so the stub on PATH loses to the real gh.exe there; CREW_FAKE_GH hands it over.
  export CREW_FAKE_GH="$STUB/gh"
}

write_body_met() {
  cat > "$GH_BODY_FILE" <<'EOF'
Status: ready-for-agent

## Acceptance criteria

- [x] one
- [x] two
EOF
}

write_body_unmet() {
  cat > "$GH_BODY_FILE" <<'EOF'
Status: ready-for-agent

## Acceptance criteria

- [x] one
- [ ] two
EOF
}

# The done-marking edit: the awaiting-merge label swap.
done_calls() {
  grep -c '^issue edit .*--add-label awaiting-merge' "$GH_LOG" || true
}

close_calls() {
  grep -c '^issue close' "$GH_LOG" || true
}

# ─── mark-issue-done.sh: criteria against a fresh fetch ──────────────────────

@test "mark-issue-done (github): unmet criteria exits 4 without labelling the issue" {
  stub_gh 0
  write_body_unmet

  run bash "$MARK_DONE" 42
  [ "$status" -eq 4 ]
  [[ "$output" == *"unchecked criteria"* ]]
  [ "$(done_calls)" -eq 0 ]
}

@test "mark-issue-done (github): in-progress comes off in the one edit that adds awaiting-merge, and is created first" {
  stub_gh 0
  write_body_met

  run bash "$MARK_DONE" 42
  [ "$status" -eq 0 ]
  grep -q '^label create in-progress --force' "$GH_LOG"
  [ "$(grep -c '^issue edit' "$GH_LOG")" -eq 1 ]
  grep -q '^issue edit 42 .*--remove-label in-progress' "$GH_LOG"
}

@test "mark-issue-done (github): met criteria swaps ready-for-agent for awaiting-merge and never closes" {
  stub_gh 0
  write_body_met

  run bash "$MARK_DONE" 42
  [ "$status" -eq 0 ]
  [ "$(done_calls)" -eq 1 ]
  grep -q '^label create awaiting-merge --force' "$GH_LOG"
  grep -q '^issue edit 42 --add-label awaiting-merge --remove-label ready-for-agent --remove-label ready-for-human --remove-label in-progress$' "$GH_LOG"
  [ "$(close_calls)" -eq 0 ]
  [[ "$output" == *"Closes #42"* ]]
}

@test "mark-issue-done (github): a ready-for-human issue loses that label in the one edit, after it is created" {
  stub_gh 0
  cat > "$GH_BODY_FILE" <<'EOF'
Status: ready-for-human

## Acceptance criteria

- [x] one
- [x] two
EOF

  run bash "$MARK_DONE" 42
  [ "$status" -eq 0 ]
  [ "$(grep -c '^issue edit' "$GH_LOG")" -eq 1 ]
  create=$(grep -n '^label create ready-for-human' "$GH_LOG" | cut -d: -f1)
  # --force would reset an existing label's colour and description.
  ! grep -q '^label create ready-for-human.*--force' "$GH_LOG" || false
  edit=$(grep -n '^issue edit' "$GH_LOG" | cut -d: -f1)
  [ -n "$create" ] && [ "$create" -lt "$edit" ]
  grep -q '^issue edit 42 --add-label awaiting-merge --remove-label ready-for-agent --remove-label ready-for-human --remove-label in-progress$' "$GH_LOG"
}

@test "mark-issue-done (github): an existing ready-for-human label is left as is and still removed" {
  stub_gh 0
  write_body_met
  # Wrap the stub: `label create ready-for-human` fails the way gh does on an existing label.
  mv "$STUB/gh" "$STUB/gh-real"
  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2 \$3" = "label create ready-for-human" ]; then
  printf '%s\n' "\$*" >> "$GH_LOG"
  echo 'label with name "ready-for-human" already exists; use \`--force\` to update its color and description' >&2
  exit 1
fi
exec "$STUB/gh-real" "\$@"
EOF
  chmod +x "$STUB/gh"

  run bash "$MARK_DONE" 42
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
  ! grep -q '^label create ready-for-human.*--force' "$GH_LOG" || false
  grep -q '^issue edit 42 --add-label awaiting-merge --remove-label ready-for-agent --remove-label ready-for-human --remove-label in-progress$' "$GH_LOG"
}

@test "mark-issue-done (github): a failed ready-for-human label create only warns and leaves it alone" {
  stub_gh 0
  write_body_met
  # Wrap the stub: `label create ready-for-human` fails, everything else passes through.
  mv "$STUB/gh" "$STUB/gh-real"
  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
if [ "\$1 \$2 \$3" = "label create ready-for-human" ]; then
  printf '%s\n' "\$*" >> "$GH_LOG"
  echo "HTTP 403: no permission" >&2
  exit 1
fi
exec "$STUB/gh-real" "\$@"
EOF
  chmod +x "$STUB/gh"

  run bash "$MARK_DONE" 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: gh label create ready-for-human failed"* ]]
  grep -q '^issue edit 42 --add-label awaiting-merge --remove-label ready-for-agent --remove-label in-progress$' "$GH_LOG"
}

@test "mark-issue-done (github): checks the freshly fetched body, not a stale local copy" {
  # A criterion unmet in the *fresh* fetch must still refuse, even though the
  # caller passes nothing but the bare issue number — there is no cache to fool.
  stub_gh 0
  write_body_unmet

  run bash "$MARK_DONE" 42
  [ "$status" -eq 4 ]
  [ "$(done_calls)" -eq 0 ]

  # Now the issue is fixed upstream (the fresh fetch changes) — same invocation,
  # same script, must now succeed: proof the body is fetched live each call.
  write_body_met
  run bash "$MARK_DONE" 42
  [ "$status" -eq 0 ]
  [ "$(done_calls)" -eq 1 ]
}

@test "mark-issue-done (github): --force marks done despite an unchecked criterion" {
  stub_gh 0
  write_body_unmet

  run bash "$MARK_DONE" 42 --force
  [ "$status" -eq 0 ]
  [ "$(done_calls)" -eq 1 ]
}

@test "mark-issue-done (github): rejects a non-numeric argument instead of shelling out to gh" {
  stub_gh 0
  write_body_met

  run bash "$MARK_DONE" ".scratch/alpha/issues/open/01-first.md"
  [ "$status" -eq 1 ]
  [ ! -s "$GH_LOG" ]
}

@test "mark-issue-done (github): a gh issue edit failure surfaces and is not swallowed" {
  stub_gh 7
  write_body_met

  run bash "$MARK_DONE" 42
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh issue edit failed"* ]]
}

# ─── mark-issue-done.sh: guard 1 (orchestrator ownership), same semantics ─────

@test "mark-issue-done (github): refuses when CREW_ORCHESTRATED is set" {
  stub_gh 0
  write_body_met

  run env CREW_ORCHESTRATED=1 bash "$MARK_DONE" 42
  [ "$status" -eq 3 ]
  [ "$(done_calls)" -eq 0 ]
}

@test "mark-issue-done (github): refuses while the sprint marker exists under SPRINT_DIR" {
  stub_gh 0
  write_body_met
  mkdir -p "$MAIN_ROOT/.scratch/alpha"
  touch "$MAIN_ROOT/.scratch/alpha/.orchestrated"

  run env SPRINT_DIR="$MAIN_ROOT/.scratch/alpha" bash "$MARK_DONE" 42
  [ "$status" -eq 3 ]
  [ "$(done_calls)" -eq 0 ]
}

@test "mark-issue-done (github): --force overrides the sprint marker" {
  stub_gh 0
  write_body_met
  mkdir -p "$MAIN_ROOT/.scratch/alpha"
  touch "$MAIN_ROOT/.scratch/alpha/.orchestrated"

  run env SPRINT_DIR="$MAIN_ROOT/.scratch/alpha" bash "$MARK_DONE" 42 --force
  [ "$status" -eq 0 ]
  [ "$(done_calls)" -eq 1 ]
}

# ─── close-issue.sh: the orchestrator's own close, github backend ────────────

@test "close-issue (github): labels the issue awaiting-merge and leaves it open for the PR to close" {
  stub_gh 0

  run env CREW_RECEIPTS=off bash "$CLOSE_SCRIPT" 42
  [ "$status" -eq 0 ]
  [ "$(done_calls)" -eq 1 ]
  grep -q '^label create awaiting-merge --force' "$GH_LOG"
  grep -q '^issue edit 42 --add-label awaiting-merge --remove-label ready-for-agent --remove-label ready-for-human --remove-label in-progress$' "$GH_LOG"
  [ "$(close_calls)" -eq 0 ]
}

@test "close-issue (github): a gh issue edit failure surfaces and is not swallowed" {
  stub_gh 9

  run env CREW_RECEIPTS=off bash "$CLOSE_SCRIPT" 42
  [ "$status" -ne 0 ]
}

# The tick is bookkeeping about the close, so close-issue.sh owns it on github too —
# a merged issue must not read as half-done on GitHub while the local backend ticks.
@test "close-issue (github): ticks every remaining criterion in the issue body" {
  stub_gh 0
  cat > "$GH_BODY_FILE" <<'BODY'
Status: ready-for-agent

## What to build

- [ ] a note, not a criterion

## Acceptance criteria

- [x] one
- [ ] two

## Cross-cutting Requirements

* [ ] three
BODY
  # Capture the body the edit sends, so the assertion is on what reached GitHub.
  cat > "$STUB/gh" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$1 \$2" in
  "issue view") cat "$GH_BODY_FILE" ;;
  "issue edit")
    while [ \$# -gt 0 ]; do
      [ "\$1" = "--body-file" ] && cp "\$2" "$TEMP_DIR/sent-body.txt"
      shift
    done ;;
esac
exit 0
STUBEOF
  chmod +x "$STUB/gh"

  run env CREW_RECEIPTS=off bash "$CLOSE_SCRIPT" 42
  [ "$status" -eq 0 ]
  grep -q '^issue edit 42 --body-file' "$GH_LOG"
  grep -qx -- '- \[x\] two' "$TEMP_DIR/sent-body.txt"
  grep -qx -- '\* \[x\] three' "$TEMP_DIR/sent-body.txt"
  grep -qx -- '- \[ \] a note, not a criterion' "$TEMP_DIR/sent-body.txt"
  grep -qx 'Status: ready-for-agent' "$TEMP_DIR/sent-body.txt"
  [ "$(done_calls)" -eq 1 ]
}

@test "close-issue (github): no body edit when every criterion is already ticked" {
  stub_gh 0
  write_body_met

  run env CREW_RECEIPTS=off bash "$CLOSE_SCRIPT" 42
  [ "$status" -eq 0 ]
  ! grep -q -- '--body-file' "$GH_LOG"
  [ "$(done_calls)" -eq 1 ]
}
