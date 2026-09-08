#!/usr/bin/env bats

# ensure-codegraph.sh — give a worktree its own codegraph
# (https://github.com/colbymchenry/codegraph) index, if codegraph is in use.
#
# The contract these tests pin: exactly one `CODEGRAPH:` line, always exit 0, off unless
# CREW_CODEGRAPH=on. codegraph's own index resolution walks up to the *nearest*
# `.codegraph/` — a worktree with none of its own silently borrows the main checkout's, so
# this script's only job is making sure one exists before a worker or reviewer ever reads
# from that worktree.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/ensure-codegraph.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK"
  STUB_BIN="$TEMP_DIR/bin"
  mkdir -p "$STUB_BIN"
  export PATH="$STUB_BIN:$PATH"
  unset TRACE_LOG CREW_CODEGRAPH
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# stub_codegraph <init-exit> — a fake `codegraph` CLI so these tests do not depend on the
# real tool being installed. Records its own argv so tests can assert on the invocation.
stub_codegraph() {
  local init_exit="$1"
  cat > "$STUB_BIN/codegraph" <<SCRIPT_EOF
#!/usr/bin/env bash
echo "\$@" >> "$TEMP_DIR/codegraph.invocations"
if [ "\$1" = "init" ]; then
  mkdir -p .codegraph
  exit $init_exit
fi
exit 0
SCRIPT_EOF
  chmod +x "$STUB_BIN/codegraph"
}

# codegraph_line — the single CODEGRAPH: line the script is allowed to print
codegraph_line() {
  printf '%s\n' "$output" | grep '^CODEGRAPH:' || true
}

# ─── the escape hatch ─────────────────────────────────────────────────────────

@test "CREW_CODEGRAPH unset is CODEGRAPH: skipped, and codegraph never runs" {
  stub_codegraph 0
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(codegraph_line)" = "CODEGRAPH: skipped" ]
  [ ! -f "$TEMP_DIR/codegraph.invocations" ]
}

@test "CREW_CODEGRAPH=off is CODEGRAPH: skipped" {
  stub_codegraph 0
  export CREW_CODEGRAPH=off
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(codegraph_line)" = "CODEGRAPH: skipped" ]
}

# ─── the CLI presence guard ───────────────────────────────────────────────────

@test "CREW_CODEGRAPH=on with no codegraph on PATH is CODEGRAPH: unavailable, not a failure" {
  export CREW_CODEGRAPH=on
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(codegraph_line)" = "CODEGRAPH: unavailable" ]
}

# ─── the presence guard ───────────────────────────────────────────────────────

@test "an existing .codegraph is CODEGRAPH: present, and codegraph never runs" {
  stub_codegraph 0
  export CREW_CODEGRAPH=on
  mkdir -p "$WORK/.codegraph"
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(codegraph_line)" = "CODEGRAPH: present" ]
  [ ! -f "$TEMP_DIR/codegraph.invocations" ]
}

# ─── init ──────────────────────────────────────────────────────────────────────

@test "a fresh worktree is CODEGRAPH: initialized, via 'codegraph init -i' run from inside it" {
  stub_codegraph 0
  export CREW_CODEGRAPH=on
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [ "$(codegraph_line)" = "CODEGRAPH: initialized" ]
  [ "$(cat "$TEMP_DIR/codegraph.invocations")" = "init -i" ]
  [ -d "$WORK/.codegraph" ]
}

@test "a failed init is reported, exit code still zero, and a log is left on disk" {
  stub_codegraph 1
  export CREW_CODEGRAPH=on
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 0 ]
  [[ "$(codegraph_line)" == "CODEGRAPH: failed (exit 1)"* ]]
  [ -f "$WORK/.scratch/codegraph-init.log" ]
}

# ─── usage errors are real errors ─────────────────────────────────────────────

@test "a missing --dir is a real error, not a silent CODEGRAPH: line" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ -z "$(codegraph_line)" ]
}

@test "a directory that does not exist is a real error" {
  run bash "$SCRIPT" --dir "$TEMP_DIR/does-not-exist"
  [ "$status" -ne 0 ]
}
