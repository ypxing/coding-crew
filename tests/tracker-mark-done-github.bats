#!/usr/bin/env bats

# mark-issue-done.sh / close-issue.sh — github backend.
#
# Issue 05's orchestrator/lib/trackers/github.mjs markDone re-fetches the issue body
# live (never a cached copy the caller might be holding) and closes with
# `gh issue close <n> --reason completed` — no label swap, since "closed" already
# is the github-native "done" state. This mirrors that same behavior for the two
# scripts that are invoked directly rather than through that Node module, while
# preserving the local backend's `.orchestrated`-marker / `--force` /
# exit-3-and-4 contract identically for both backends.
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

# stub_gh <close-exit> — a fake `gh` that logs every invocation (one per line) and:
#   - `issue view ... --json body ...` prints the current contents of $GH_BODY_FILE
#   - `issue close ...` exits with the given code
stub_gh() {
  local close_rc="${1:-0}"
  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$1 \$2" in
  "issue view")
    cat "$GH_BODY_FILE"
    exit 0
    ;;
  "issue close")
    exit $close_rc
    ;;
esac
exit 1
EOF
  chmod +x "$STUB/gh"
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

close_calls() {
  grep -c '^issue close' "$GH_LOG" || true
}

# ─── mark-issue-done.sh: criteria against a fresh fetch ──────────────────────

@test "mark-issue-done (github): unmet criteria exits 4 without calling gh issue close" {
  stub_gh 0
  write_body_unmet

  run bash "$MARK_DONE" 42
  [ "$status" -eq 4 ]
  [[ "$output" == *"unchecked criteria"* ]]
  [ "$(close_calls)" -eq 0 ]
}

@test "mark-issue-done (github): met criteria calls gh issue close exactly once, with --reason completed" {
  stub_gh 0
  write_body_met

  run bash "$MARK_DONE" 42
  [ "$status" -eq 0 ]
  [ "$(close_calls)" -eq 1 ]
  grep -q '^issue close 42 --reason completed$' "$GH_LOG"
}

@test "mark-issue-done (github): checks the freshly fetched body, not a stale local copy" {
  # A criterion unmet in the *fresh* fetch must still refuse, even though the
  # caller passes nothing but the bare issue number — there is no cache to fool.
  stub_gh 0
  write_body_unmet

  run bash "$MARK_DONE" 42
  [ "$status" -eq 4 ]
  [ "$(close_calls)" -eq 0 ]

  # Now the issue is fixed upstream (the fresh fetch changes) — same invocation,
  # same script, must now succeed: proof the body is fetched live each call.
  write_body_met
  run bash "$MARK_DONE" 42
  [ "$status" -eq 0 ]
  [ "$(close_calls)" -eq 1 ]
}

@test "mark-issue-done (github): --force closes despite an unchecked criterion" {
  stub_gh 0
  write_body_unmet

  run bash "$MARK_DONE" 42 --force
  [ "$status" -eq 0 ]
  [ "$(close_calls)" -eq 1 ]
}

@test "mark-issue-done (github): rejects a non-numeric argument instead of shelling out to gh" {
  stub_gh 0
  write_body_met

  run bash "$MARK_DONE" ".scratch/alpha/issues/open/01-first.md"
  [ "$status" -eq 1 ]
  [ ! -s "$GH_LOG" ]
}

@test "mark-issue-done (github): a gh issue close failure surfaces and is not swallowed" {
  stub_gh 7
  write_body_met

  run bash "$MARK_DONE" 42
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh issue close failed"* ]]
}

# ─── mark-issue-done.sh: guard 1 (orchestrator ownership), same semantics ─────

@test "mark-issue-done (github): refuses when CREW_ORCHESTRATED is set" {
  stub_gh 0
  write_body_met

  run env CREW_ORCHESTRATED=1 bash "$MARK_DONE" 42
  [ "$status" -eq 3 ]
  [ "$(close_calls)" -eq 0 ]
}

@test "mark-issue-done (github): refuses while the sprint marker exists under SPRINT_DIR" {
  stub_gh 0
  write_body_met
  mkdir -p "$MAIN_ROOT/.scratch/alpha"
  touch "$MAIN_ROOT/.scratch/alpha/.orchestrated"

  run env SPRINT_DIR="$MAIN_ROOT/.scratch/alpha" bash "$MARK_DONE" 42
  [ "$status" -eq 3 ]
  [ "$(close_calls)" -eq 0 ]
}

@test "mark-issue-done (github): --force overrides the sprint marker" {
  stub_gh 0
  write_body_met
  mkdir -p "$MAIN_ROOT/.scratch/alpha"
  touch "$MAIN_ROOT/.scratch/alpha/.orchestrated"

  run env SPRINT_DIR="$MAIN_ROOT/.scratch/alpha" bash "$MARK_DONE" 42 --force
  [ "$status" -eq 0 ]
  [ "$(close_calls)" -eq 1 ]
}

# ─── close-issue.sh: the orchestrator's own close, github backend ────────────

@test "close-issue (github): closes via gh issue close --reason completed, no label" {
  stub_gh 0

  run env CREW_RECEIPTS=off bash "$CLOSE_SCRIPT" 42
  [ "$status" -eq 0 ]
  [ "$(close_calls)" -eq 1 ]
  grep -q '^issue close 42 --reason completed$' "$GH_LOG"
  ! grep -q -- '--add-label\|--remove-label' "$GH_LOG"
}

@test "close-issue (github): a gh issue close failure surfaces and is not swallowed" {
  stub_gh 9

  run env CREW_RECEIPTS=off bash "$CLOSE_SCRIPT" 42
  [ "$status" -ne 0 ]
}
