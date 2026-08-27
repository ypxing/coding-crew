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

# ─── output capping ──────────────────────────────────────────────────────────
# A check command's own output can be far larger than anything a caller wants to see
# unconditionally streamed to stdout. A passing check's output over the cap is fully
# suppressed (nobody reads it); a failing check's is tailed. Either way, the full
# output is persisted to disk.

@test "verify-worktree: small command output passes through uncapped" {
  cat > "$TEMP_DIR/Makefile" <<'EOF'
test:
	@echo small-output-line
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"small-output-line"* ]]
  [[ "$output" != *"omitted"* ]]
}

@test "verify-worktree: large output from a passing check is fully suppressed, not just tailed" {
  cat > "$TEMP_DIR/Makefile" <<'EOF'
test:
	@seq 1 500
EOF

  CREW_VERIFY_OUTPUT_LINES=50 run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  # Nothing from the 500-line body leaks through — not even the tail: a passing check
  # is not why anyone reads this output, so the whole body is dropped, not capped.
  [[ "$output" != *$'\n1\n'* ]]
  [[ "$output" != *$'\n500\n'* ]]
  [[ "$output" == *"500 lines omitted"* ]]
  [[ "$output" == *".scratch/verify-test.log"* ]]
  [[ "$output" == *"TEST: pass"* ]]
  [ -f "$TEMP_DIR/.scratch/verify-test.log" ]
  [ "$(wc -l < "$TEMP_DIR/.scratch/verify-test.log")" -eq 500 ]
}

@test "verify-worktree: large output from a failing check is tailed, and the full log is persisted" {
  cat > "$TEMP_DIR/Makefile" <<'EOF'
test:
	@seq 1 500; exit 1
EOF

  CREW_VERIFY_OUTPUT_LINES=50 run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
  # An early line, well outside the last-50-line tail, must not appear in the capped output.
  [[ "$output" != *$'\n1\n'* ]]
  # The tail — the last lines closest to pass/fail, where the actual error usually is —
  # must still be present.
  [[ "$output" == *$'\n500'* ]]
  [[ "$output" == *"omitted"* ]]
  [[ "$output" == *".scratch/verify-test.log"* ]]
  [[ "$output" == *"TEST: fail"* ]]
  [ -f "$TEMP_DIR/.scratch/verify-test.log" ]
  [ "$(wc -l < "$TEMP_DIR/.scratch/verify-test.log")" -ge 500 ]
}

@test "verify-worktree: CREW_VERIFY_OUTPUT_LINES raises the cap" {
  cat > "$TEMP_DIR/Makefile" <<'EOF'
test:
	@seq 1 10
EOF

  CREW_VERIFY_OUTPUT_LINES=5 run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [[ "$output" == *"omitted"* ]]

  CREW_VERIFY_OUTPUT_LINES=20 run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [[ "$output" != *"omitted"* ]]
  [[ "$output" == *"10"* ]]
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

# ─── python discovery false positive ────────────────────────────────────────
# A stray, unrelated .py file (a deploy/build helper) must not make the gate
# attempt pytest on a project that has no actual Python test suite — that
# reports a real "fail" for a repo where nothing should have run at all.

@test "verify-worktree: an unrelated root-level .py script does not trigger pytest" {
  echo "print('hello')" > "$TEMP_DIR/deploy.py"

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [[ "$output" != *"pytest"* ]]
  [[ "$output" == *"TEST: not_run"* ]]
}

@test "verify-worktree: conventionally-named test files still trigger pytest" {
  mkdir -p "$TEMP_DIR/tests"
  echo "def test_ok(): assert True" > "$TEMP_DIR/tests/test_sample.py"

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [[ "$output" == *"pytest"* ]]
}

# ─── .scratch/commands.json cache ────────────────────────────────────────────
#
# Written once per sprint by discover-commands.sh / write-commands-cache.sh (see
# orchestrator/lib/commands.mjs). Trusted as-is when present and parseable — including an
# explicit null — so this gate never re-guesses a category a model already looked at.

@test "verify-worktree: uses the cached command from .scratch/commands.json over CLAUDE.md/Makefile" {
  mkdir -p "$TEMP_DIR/.scratch"
  cat > "$TEMP_DIR/.scratch/commands.json" <<'EOF2'
{"sourceHash": "abc", "test": "echo cached-test-ran", "lint": null, "typecheck": null}
EOF2
  # A Makefile that would answer differently if the cache were not consulted first.
  cat > "$TEMP_DIR/Makefile" <<'EOF2'
test:
	@exit 1
EOF2

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"

  [[ "$output" == *"cached-test-ran"* ]]
  [[ "$output" != *"make test"* ]]
}

@test "verify-worktree: a cached explicit null is not_run, and is not retried against the Makefile" {
  mkdir -p "$TEMP_DIR/.scratch"
  cat > "$TEMP_DIR/.scratch/commands.json" <<'EOF2'
{"sourceHash": "abc", "test": "true", "lint": null, "typecheck": null}
EOF2
  # A Makefile lint target exists, but the cache's null must win — the model already
  # decided there is no local lint command (e.g. it was a CI-only/broken shortcut).
  cat > "$TEMP_DIR/Makefile" <<'EOF2'
test:
	@true
lint:
	@exit 1
EOF2

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"

  [[ "$output" == *"LINT: not_run"* ]]
  [[ "$output" != *"make lint"* ]]
  [ "$status" -eq 0 ]
}

@test "verify-worktree: falls back to the heuristic chain when there is no cache at all" {
  cat > "$TEMP_DIR/Makefile" <<'EOF2'
test:
	@echo heuristic-test-ran
EOF2

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"

  [[ "$output" == *"heuristic-test-ran"* ]]
}

@test "verify-worktree: falls back to the heuristic chain when the cache file is not our schema" {
  mkdir -p "$TEMP_DIR/.scratch"
  echo '{"unrelated": true}' > "$TEMP_DIR/.scratch/commands.json"
  cat > "$TEMP_DIR/Makefile" <<'EOF2'
test:
	@echo heuristic-test-ran
EOF2

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"

  [[ "$output" == *"heuristic-test-ran"* ]]
}

@test "verify-worktree: a failing cached command still fails the gate" {
  mkdir -p "$TEMP_DIR/.scratch"
  cat > "$TEMP_DIR/.scratch/commands.json" <<'EOF2'
{"sourceHash": "abc", "test": "exit 1", "lint": null, "typecheck": null}
EOF2

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"

  [ "$status" -ne 0 ]
  [[ "$output" == *"TEST: fail"* ]]
}

@test "verify-worktree: finds the cache from a real linked worktree, not just when --dir is the main root" {
  mkdir -p "$TEMP_DIR/.scratch"
  cat > "$TEMP_DIR/.scratch/commands.json" <<'EOF2'
{"sourceHash": "abc", "test": "echo cached-from-linked-worktree", "lint": null, "typecheck": null}
EOF2
  git -C "$TEMP_DIR" branch feature-x
  git -C "$TEMP_DIR" worktree add -q "$TEMP_DIR-wt" feature-x

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR-wt"

  [[ "$output" == *"cached-from-linked-worktree"* ]]

  git -C "$TEMP_DIR" worktree remove -f "$TEMP_DIR-wt" 2>/dev/null || rm -rf "$TEMP_DIR-wt"
}
