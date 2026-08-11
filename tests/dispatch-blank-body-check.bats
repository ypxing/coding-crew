#!/usr/bin/env bats

# The dispatchers validate that an agent definition's instruction body is not blank.
# Both used ${VAR//[[:space:]]/} to do it, which is O(n^2) in bash 3.2 (the system
# bash on macOS, and the shell `#!/usr/bin/env bash` resolves to there by default).
# On a real agent body that is ~40s of pure CPU for crew-coder and ~140s for
# crew-code-reviewer, paid on every single dispatch before any model work starts.
#
# These tests pin both halves of the fix: the check must still reject a blank body,
# and it must not do it by walking the string quadratically.

PI_DISPATCH="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/dispatch-agent.sh"
CODEX_DISPATCH="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/dispatch-codex-agent.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/wt" "$TEMP_DIR/.pi/agents" "$TEMP_DIR/.codex/agents"

  # Stubs: these tests are about the dispatchers' own preflight, not the CLIs.
  printf '#!/usr/bin/env bash\necho "ARGS: $*"\ncat >/dev/null\n' > "$TEMP_DIR/bin/pi"
  printf '#!/usr/bin/env bash\necho "ARGS: $*"\ncat >/dev/null\n' > "$TEMP_DIR/bin/codex"
  chmod +x "$TEMP_DIR/bin/pi" "$TEMP_DIR/bin/codex"

  echo "implement issue 01" > "$TEMP_DIR/prompt.md"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# --- the check still works ------------------------------------------------------

@test "pi dispatch rejects an agent file whose body is whitespace only" {
  printf -- '---\nname: blank\n---\n\n   \n\t\n' > "$TEMP_DIR/.pi/agents/blank.md"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$PI_DISPATCH" --agent blank --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty body"* ]]
}

@test "codex dispatch rejects an agent TOML whose developer_instructions is whitespace only" {
  printf 'name = "blank"\ndescription = "d"\ndeveloper_instructions = %s\n   \n\t\n%s\n' "'''" "'''" \
    > "$TEMP_DIR/.codex/agents/blank.toml"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$CODEX_DISPATCH" --agent blank --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty developer_instructions"* ]]
}

@test "pi dispatch accepts a body whose only content is far from the start" {
  # Guards against a fix that just checks the first N chars instead of the whole body.
  { printf -- '---\nname: late\n---\n'; head -c 4000 /dev/zero | tr '\0' '\n'; echo "real content"; } \
    > "$TEMP_DIR/.pi/agents/late.md"

  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    bash "$PI_DISPATCH" --agent late --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"
  [ "$status" -eq 0 ]
}

# --- and does not do it quadratically ------------------------------------------

@test "neither dispatcher blank-checks via pattern substitution over the whole body" {
  # ${VAR//[[:space:]]/} builds a new multi-KB string one char at a time in bash 3.2.
  # Comment lines are stripped first: the fix documents the pattern it replaced.
  for script in "$PI_DISPATCH" "$CODEX_DISPATCH"; do
    run bash -c "grep -v '^[[:space:]]*#' '$script' | grep -n '//\[\[:space:\]\]'"
    [ "$status" -ne 0 ]
  done
}

@test "dispatch preflight on a realistic multi-KB agent body is fast under system bash" {
  # A real crew-coder body is ~10KB; crew-code-reviewer ~15KB. The old code took 40-140s
  # here. The bound is deliberately loose — it is catching a quadratic blowup, not
  # benchmarking — so it cannot flake on a slow or loaded CI runner.
  { printf -- '---\nname: big\n---\n'; for _ in $(seq 1 400); do
      echo "Step: do the thing carefully and then report back with a summary line."
    done; } > "$TEMP_DIR/.pi/agents/big.md"
  [ "$(wc -c < "$TEMP_DIR/.pi/agents/big.md")" -gt 10000 ]

  # /bin/bash is bash 3.2 on macOS, which is where the blowup is worst.
  start=$SECONDS
  run env PATH="$TEMP_DIR/bin:$PATH" MAIN_ROOT="$TEMP_DIR" \
    /bin/bash "$PI_DISPATCH" --agent big --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"
  elapsed=$((SECONDS - start))

  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 15 ]
}
