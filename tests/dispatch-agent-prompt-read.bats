#!/usr/bin/env bats

# dispatch-agent.sh used to check `[[ -f "$PROMPT_FILE" ]]` at the top and then, many
# lines later (after resolving the agent file, parsing its frontmatter, validating the
# tool allowlist, and creating log/event directories), read the same file's *contents*
# for the first time via `pi ... "$(cat "$PROMPT_FILE")"` at the very bottom. On a real
# sprint the file was gone by the time that `cat` ran: `cat` failed, the command
# substitution silently produced an empty string, and pi was dispatched with essentially
# no prompt — exiting 0 having done nothing. The pipeline read that as an empty review
# report, not as a dispatch failure.
#
# The fix reads the prompt into a variable immediately next to the existence check, and
# treats a failed or empty read as a hard dispatch failure instead of quietly degrading
# to an empty prompt. These tests pin that contract: they do not (and cannot, from bats)
# reproduce the exact filesystem-timing race, but they pin the two observable halves of
# the fix — a prompt that cannot be read is a loud failure, and pi is never invoked with
# nothing to say.

PI_DISPATCH="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/dispatch-agent.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/wt" "$TEMP_DIR/.pi/agents"

  # A stub pi that records whether it was ever invoked, and with what final argument
  # (the prompt text pi -p takes positionally).
  cat > "$TEMP_DIR/bin/pi" <<'EOF'
#!/usr/bin/env bash
echo "PI-INVOKED"
echo "LAST-ARG: ${@: -1}"
cat >/dev/null
EOF
  chmod +x "$TEMP_DIR/bin/pi"

  printf -- '---\nname: worker\n---\nDo the thing.\n' > "$TEMP_DIR/.pi/agents/worker.md"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "a prompt file that exists but cannot be read fails the dispatch instead of running pi with nothing" {
  echo "implement issue 01" > "$TEMP_DIR/prompt.md"
  chmod 000 "$TEMP_DIR/prompt.md"

  # chmod 000 doesn't deny the owner a read everywhere (Windows/MSYS ignores POSIX mode
  # bits for the file owner; so does running as root) — skip rather than assert on a
  # permission this platform never actually withheld.
  if cat "$TEMP_DIR/prompt.md" >/dev/null 2>&1; then
    chmod 644 "$TEMP_DIR/prompt.md"
    skip "this platform does not enforce chmod 000 against the file's own owner"
  fi

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$PI_DISPATCH" --agent worker --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"

  chmod 644 "$TEMP_DIR/prompt.md"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to read prompt file"* ]]
  [[ "$output" != *"PI-INVOKED"* ]]
}

@test "an empty prompt file fails the dispatch instead of running pi with an empty prompt" {
  : > "$TEMP_DIR/prompt.md"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$PI_DISPATCH" --agent worker --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"

  [ "$status" -ne 0 ]
  [[ "$output" == *"prompt file is empty"* ]]
  [[ "$output" != *"PI-INVOKED"* ]]
}

@test "a normal prompt file is still read once and passed through to pi" {
  echo "implement issue 01" > "$TEMP_DIR/prompt.md"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$PI_DISPATCH" --agent worker --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PI-INVOKED"* ]]
  [[ "$output" == *"LAST-ARG: implement issue 01"* ]]
}

# The stub pi drains stdin, as a pi reading a piped prompt would. With the caller's stdin
# held open (a backgrounded shell, a pipe), that used to hang the dispatch.
# perl's alarm is the watchdog, not timeout(1): macOS ships no GNU coreutils.
# The sleeper keeps only the stdin pipe open: holding bats' own stderr/fd 3 too made bats
# wait out all 30s after the test had already passed.
@test "pi gets a closed stdin, so an open one on the caller can't hang the dispatch" {
  echo "implement issue 01" > "$TEMP_DIR/prompt.md"

  run perl -e 'alarm shift; exec @ARGV or die "exec: $!"' 10 env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$PI_DISPATCH" --agent worker --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md" < <(exec sleep 30 2>/dev/null 3>&-)

  [ "$status" -eq 0 ]
  [[ "$output" == *"PI-INVOKED"* ]]
}

@test "the dispatch's own log lines use orchestrator.log's date-and-level format" {
  echo "implement issue 01" > "$TEMP_DIR/prompt.md"
  mkdir -p "$TEMP_DIR/bin-events"
  cat > "$TEMP_DIR/bin-events/pi" <<'PI'
#!/usr/bin/env bash
cat >/dev/null
echo '{"type":"tool_execution_start","toolName":"bash","args":{"command":"ls"}}'
echo '{"type":"tool_execution_end","toolName":"bash","isError":true}'
PI
  chmod +x "$TEMP_DIR/bin-events/pi"

  run env PATH="$TEMP_DIR/bin-events:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$PI_DISPATCH" --agent worker --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md" --log "$TEMP_DIR/trace.log"

  [ "$status" -eq 0 ]
  local ts='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
  grep -qE "$ts INFO  \[DISPATCH\] agent=worker " "$TEMP_DIR/trace.log"
  grep -qE "$ts DEBUG \[TOOL\] agent=worker tool=bash" "$TEMP_DIR/trace.log"
  grep -qE "$ts WARN  \[TOOL-ERROR\] agent=worker tool=bash" "$TEMP_DIR/trace.log"
  grep -qE "$ts INFO  \[DISPATCH-END\] agent=worker exit=0$" "$TEMP_DIR/trace.log"
  # Every line is a header line: nothing written in the old `[HH:MM:SSZ]` shape.
  ! grep -qvE "$ts (DEBUG|INFO |WARN |ERROR|FATAL) " "$TEMP_DIR/trace.log"
}
