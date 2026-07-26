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

# ─── bats discovery targets the directory the files are actually in ──────────

@test "verify-worktree: root-level .bats files are run from the repo root, not tests/" {
  # A repo whose bats files live at the root with no tests/ subdirectory.
  # Discovery must not point bats at a non-existent tests/ directory.
  printf '@test "trivial" { true; }\n' > "$TEMP_DIR/sample.bats"

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"does not exist"* ]]
}

@test "verify-worktree: tests/ .bats files are run from tests/" {
  mkdir -p "$TEMP_DIR/tests"
  printf '@test "trivial" { true; }\n' > "$TEMP_DIR/tests/sample.bats"

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tests"* ]]
}

@test "verify-worktree: failing root-level bats test still exits non-zero" {
  printf '@test "failing" { false; }\n' > "$TEMP_DIR/sample.bats"

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
}

# ─── discovered commands use only valid flags ────────────────────────────────

@test "verify-worktree: ruby discovery does not emit the invalid --project-root flag" {
  # rspec has no --project-root flag; emitting it fails every Ruby project.
  touch "$TEMP_DIR/Gemfile"

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [[ "$output" != *"--project-root"* ]]
}

# ─── argument validation ─────────────────────────────────────────────────────

@test "verify-worktree: --dir with no value reports usage, not an unbound variable" {
  run bash "$VERIFY_SCRIPT" --dir
  [ "$status" -ne 0 ]
  [[ "$output" != *"unbound variable"* ]]
  [[ "$output" == *"--dir"* ]]
}

# ─── all three check categories are discovered and reported ──────────────────
# verification.md makes tests, lint, and typecheck all mandatory. A category with
# no discoverable command must be reported explicitly, never treated as passing.

@test "verify-worktree: reports all three check categories" {
  cat > "$TEMP_DIR/Makefile" <<'EOF'
test:
	@exit 0
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [[ "$output" == *"TEST"* ]]
  [[ "$output" == *"LINT"* ]]
  [[ "$output" == *"TYPECHECK"* ]]
}

@test "verify-worktree: failing lint target exits non-zero even when tests pass" {
  cat > "$TEMP_DIR/Makefile" <<'EOF'
test:
	@exit 0
lint:
	@exit 1
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"LINT: fail"* ]]
}

@test "verify-worktree: failing typecheck target exits non-zero even when tests pass" {
  cat > "$TEMP_DIR/Makefile" <<'EOF'
test:
	@exit 0
typecheck:
	@exit 1
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TYPECHECK: fail"* ]]
}

@test "verify-worktree: all three passing Makefile targets exit zero" {
  cat > "$TEMP_DIR/Makefile" <<'EOF'
test:
	@exit 0
lint:
	@exit 0
typecheck:
	@exit 0
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
}

@test "verify-worktree: undiscoverable lint category is reported as not_run, not passing" {
  # Only a test command exists; lint/typecheck have no discoverable command.
  cat > "$TEMP_DIR/CLAUDE.md" <<'EOF'
## Tests

Run: `bash -c 'exit 0'`
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [[ "$output" == *"LINT: not_run"* ]]
  [[ "$output" == *"TYPECHECK: not_run"* ]]
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

# ─── not_run policy: loud but non-fatal for lint/typecheck, fatal for TEST ────
# Failing on a missing lint/typecheck command would stall every sprint in a repo
# that legitimately has neither (this repo included) — a false-positive gate is
# worse for an unattended run than the gap it closes. A missing TEST command is
# fatal because it means nothing was verified at all.

@test "verify-worktree: missing lint and typecheck do not fail the gate when tests pass" {
  cat > "$TEMP_DIR/CLAUDE.md" <<'EOF'
## Tests

Run: `bash -c 'exit 0'`
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
}

@test "verify-worktree: coverage gap is reported in the summary, not hidden by success" {
  cat > "$TEMP_DIR/CLAUDE.md" <<'EOF'
## Tests

Run: `bash -c 'exit 0'`
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"coverage gap"* ]]
  [[ "$output" == *"not_run"* ]]
}

@test "verify-worktree: missing TEST command is fatal even when lint and typecheck pass" {
  cat > "$TEMP_DIR/Makefile" <<'EOF'
lint:
	@exit 0
typecheck:
	@exit 0
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TEST: not_run"* ]]
}
