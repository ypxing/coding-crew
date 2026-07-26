#!/usr/bin/env bats

# Tests for verify-worktree.sh
# Following the pattern in tests/squash-commits.bats:
#   - temp git repo per test
#   - assert exit codes

VERIFY_SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/verify-worktree.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git commit --allow-empty -m "initial"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# ─── passing checks ──────────────────────────────────────────────────────────

@test "verify-worktree: exits zero when all checks pass (via CLAUDE.md)" {
  # Write a CLAUDE.md that specifies a passing test command
  cat > "$TEMP_DIR/CLAUDE.md" <<'EOF'
## Tests

Run: `bash -c 'exit 0'`
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
}

@test "verify-worktree: exits zero when Makefile defines passing test target" {
  # Write a Makefile with a passing test target
  cat > "$TEMP_DIR/Makefile" <<'EOF'
test:
	@exit 0
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
}

@test "verify-worktree: reports success output when checks pass" {
  cat > "$TEMP_DIR/CLAUDE.md" <<'EOF'
## Tests

Run: `bash -c 'exit 0'`
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pass"* ]] || [[ "$output" == *"ok"* ]] || [[ "$output" == *"success"* ]]
}

# ─── failing checks ──────────────────────────────────────────────────────────

@test "verify-worktree: exits non-zero when test command fails" {
  cat > "$TEMP_DIR/CLAUDE.md" <<'EOF'
## Tests

Run: `bash -c 'exit 1'`
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
}

@test "verify-worktree: exits non-zero when Makefile test target fails" {
  cat > "$TEMP_DIR/Makefile" <<'EOF'
test:
	@exit 1
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
}

@test "verify-worktree: reports failure output when checks fail" {
  cat > "$TEMP_DIR/CLAUDE.md" <<'EOF'
## Tests

Run: `bash -c 'exit 1'`
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"fail"* ]] || [[ "$output" == *"FAIL"* ]]
}

# ─── missing check command ───────────────────────────────────────────────────

@test "verify-worktree: exits non-zero when no test command can be discovered" {
  # Empty directory with no CLAUDE.md, Makefile, or recognizable ecosystem files
  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
}

@test "verify-worktree: explicitly reports when check command is not discoverable" {
  # Empty directory — no test discovery possible
  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  # Exit code must be non-zero
  [ "$status" -ne 0 ]
  # Output must explicitly mention the missing command (not silent)
  [[ "$output" == *"not_run"* ]] || [[ "$output" == *"no command"* ]] || [[ "$output" == *"NOT RUN"* ]]
}

# ─── schema pre-filter ───────────────────────────────────────────────────────

@test "verify-worktree: accepts --dir flag" {
  cat > "$TEMP_DIR/CLAUDE.md" <<'EOF'
## Tests

Run: `bash -c 'exit 0'`
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
}
