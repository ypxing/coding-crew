#!/usr/bin/env bats

# dispatch-agent.sh (pi) and dispatch-codex-agent.sh (codex) both read the review/worker
# prompt file right after checking it exists — but `[[ -f ]]` and `cat` are still two
# separate syscalls in two separate processes, not one atomic read. On a slow or
# virtualized filesystem (bind mounts, VM shared folders, network filesystems) a file a
# sibling process just wrote can briefly 404 for a freshly spawned `cat` even
# microseconds after `[[ -f ]]` found it — this is exactly the shape of a real crew-afk
# sprint failure: `[DISPATCH-FAIL] ... stderr="cat: .../*.review-prompt.md: No such file
# or directory dispatch-agent: failed to read prompt file: ..."` even though the
# orchestrator had already written that file, synchronously, moments earlier.
#
# Both dispatchers now retry the read briefly (5 attempts, 40ms apart) before giving up,
# to absorb exactly that class of transient miss. These tests pin two things: a prompt
# file that shows up a beat after the dispatcher starts is still picked up (the retry
# actually works), and a prompt file that never shows up still fails loudly, not slowly
# and silently (the retry does not turn into an infinite hang or a masked failure).
#
# dispatch-codex-agent.sh gets a second fix here too: it used to re-read $PROMPT_FILE via
# a bare `cat` (no `|| die`) many lines later, at COMBINED-build time, so a prompt file
# that vanished in between never failed the dispatch at all — it just ran codex with a
# blank task section. It now reads the prompt once, up front, the same as pi's dispatcher.

PI_DISPATCH="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/dispatch-agent.sh"
CODEX_DISPATCH="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/dispatch-codex-agent.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/wt" "$TEMP_DIR/.pi/agents" "$TEMP_DIR/.codex/agents"

  cat > "$TEMP_DIR/bin/pi" <<'EOF'
#!/usr/bin/env bash
echo "PI-INVOKED"
echo "LAST-ARG: ${@: -1}"
cat >/dev/null
EOF
  printf '#!/usr/bin/env bash\necho "CODEX-INVOKED: $*"\necho "STDIN:"\ncat\n' > "$TEMP_DIR/bin/codex"
  chmod +x "$TEMP_DIR/bin/pi" "$TEMP_DIR/bin/codex"

  printf -- '---\nname: worker\n---\nDo the thing.\n' > "$TEMP_DIR/.pi/agents/worker.md"
  printf 'name = "worker"\ndescription = "d"\ndeveloper_instructions = %s\nDo the thing.\n%s\n' \
    "'''" "'''" > "$TEMP_DIR/.codex/agents/worker.toml"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "pi dispatch picks up a prompt file that appears a beat after the dispatcher starts" {
  ( sleep 0.08; echo "implement issue 01" > "$TEMP_DIR/prompt.md" ) &

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$PI_DISPATCH" --agent worker --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"

  [ "$status" -eq 0 ]
  [[ "$output" == *"PI-INVOKED"* ]]
  [[ "$output" == *"LAST-ARG: implement issue 01"* ]]
}

@test "pi dispatch still fails loudly when the prompt file never appears" {
  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$PI_DISPATCH" --agent worker --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to read prompt file"* ]]
  [[ "$output" != *"PI-INVOKED"* ]]
}

@test "codex dispatch picks up a prompt file that appears a beat after the dispatcher starts" {
  ( sleep 0.08; echo "implement issue 01" > "$TEMP_DIR/prompt.md" ) &

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$CODEX_DISPATCH" --agent worker --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"

  [ "$status" -eq 0 ]
  [[ "$output" == *"CODEX-INVOKED"* ]]
}

@test "codex dispatch fails loudly, not silently, when the prompt file never appears" {
  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$CODEX_DISPATCH" --agent worker --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"

  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to read prompt file"* ]]
  [[ "$output" != *"CODEX-INVOKED"* ]]
}

@test "codex dispatch's task section actually carries the prompt, not a silent blank" {
  echo "implement issue 01" > "$TEMP_DIR/prompt.md"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$CODEX_DISPATCH" --agent worker --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"

  [ "$status" -eq 0 ]
  [[ "$output" == *"implement issue 01"* ]]
}
