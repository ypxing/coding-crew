#!/usr/bin/env bats

# cli.mjs mark-done — github backend.
#
# mark-done re-fetches the issue body live (never a cached copy the caller
# might be holding) and marks it done by swapping ready-for-agent for awaiting-merge —
# never `gh issue close`: the work is only on a branch, and the PR's `Closes #n` closes
# the issue on merge. The guards every backend shares (unchecked criteria) are tested once, in
# tests/tracker/tracker-cli-write.test.mjs; this file keeps what is GitHub's own.
#
# `gh` is stubbed on PATH throughout: these tests pin argument shape and call
# count, not real GitHub behaviour.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  export MAIN_ROOT="$TEMP_DIR"

  mkdir -p "$MAIN_ROOT/.coding-crew/docs"
  cat > "$MAIN_ROOT/.coding-crew/docs/issue-tracker.md" <<'EOF'
---
tracker: github
---

# Issue tracker: GitHub Issues
EOF
  # The tracker CLI, installed in the repo — the only tracker file an install ships.
  cp -R "$REPO_ROOT/tracker" "$MAIN_ROOT/.coding-crew/tracker"

  STUB="$TEMP_DIR/.stub"
  mkdir -p "$STUB"
  export PATH="$STUB:$PATH"

  GH_LOG="$TEMP_DIR/gh.log"
  export GH_LOG
  : > "$GH_LOG"
  GH_BODY_FILE="$TEMP_DIR/gh-body.txt"
  export GH_BODY_FILE
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# mark_done <args> — the tracker CLI's mark-done, against this fixture's main root.
mark_done() { node "$MAIN_ROOT/.coding-crew/tracker/cli.mjs" mark-done "$@" --main-root "$MAIN_ROOT"; }

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

# The done-marking edit: the awaiting-merge label swap.
done_calls() {
  grep -c '^issue edit .*--add-label awaiting-merge' "$GH_LOG" || true
}

close_calls() {
  grep -c '^issue close' "$GH_LOG" || true
}

# ─── mark-done: the label edits ─────────────────────────────────────

@test "mark-done (github): met criteria swaps ready-for-agent for awaiting-merge and never closes" {
  stub_gh 0
  write_body_met

  run mark_done 42
  [ "$status" -eq 0 ]
  [ "$(done_calls)" -eq 1 ]
  grep -q '^label create awaiting-merge --force' "$GH_LOG"
  grep -q '^issue edit 42 --add-label awaiting-merge --remove-label ready-for-agent --remove-label ready-for-human$' "$GH_LOG"
  [ "$(close_calls)" -eq 0 ]
  [[ "$output" == *"Closes #42"* ]]
}

@test "mark-done (github): a ready-for-human issue loses that label in the one edit, after it is created" {
  stub_gh 0
  cat > "$GH_BODY_FILE" <<'EOF'
Status: ready-for-human

## Acceptance criteria

- [x] one
- [x] two
EOF

  run mark_done 42
  [ "$status" -eq 0 ]
  [ "$(grep -c '^issue edit' "$GH_LOG")" -eq 1 ]
  create=$(grep -n '^label create ready-for-human' "$GH_LOG" | cut -d: -f1)
  # --force would reset an existing label's colour and description.
  ! grep -q '^label create ready-for-human.*--force' "$GH_LOG" || false
  edit=$(grep -n '^issue edit' "$GH_LOG" | cut -d: -f1)
  [ -n "$create" ] && [ "$create" -lt "$edit" ]
  grep -q '^issue edit 42 --add-label awaiting-merge --remove-label ready-for-agent --remove-label ready-for-human$' "$GH_LOG"
}

@test "mark-done (github): an existing ready-for-human label is left as is and still removed" {
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

  run mark_done 42
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
  ! grep -q '^label create ready-for-human.*--force' "$GH_LOG" || false
  grep -q '^issue edit 42 --add-label awaiting-merge --remove-label ready-for-agent --remove-label ready-for-human$' "$GH_LOG"
}

@test "mark-done (github): a failed ready-for-human label create only warns and leaves it alone" {
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

  run mark_done 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: gh label create ready-for-human failed"* ]]
  grep -q '^issue edit 42 --add-label awaiting-merge --remove-label ready-for-agent$' "$GH_LOG"
}

@test "mark-done (github): rejects a non-numeric argument instead of shelling out to gh" {
  stub_gh 0
  write_body_met

  run mark_done ".scratch/alpha/issues/open/01-first.md"
  [ "$status" -eq 2 ]
  [ ! -s "$GH_LOG" ]
}

@test "mark-done (github): a gh issue edit failure surfaces and is not swallowed" {
  stub_gh 7
  write_body_met

  run mark_done 42
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh issue edit failed"* ]]
}

