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
