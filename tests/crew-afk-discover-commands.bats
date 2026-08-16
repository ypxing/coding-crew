#!/usr/bin/env bats

# Tests for discover-commands.sh — the mechanical prompt-builder half of command discovery.
#
# This script never calls a model. It only decides whether a model call is needed (mirroring
# coverage-validation.sh's skip/not-skip stdout contract) and, when it is, assembles the
# discovery prompt. Writing the model's response into .scratch/commands.json is a separate
# script (write-commands-cache.sh, not yet built).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
# Canonical source is scripts/skill-utils/git-workflow/ (shared by crew-afk and solve-issue
# at install time via their registry.json `scripts` field) — not skills/crew-afk/scripts/.
DISCOVER_SCRIPT="$SCRIPT_DIR/scripts/skill-utils/git-workflow/discover-commands.sh"

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

# --- Script Existence ---

@test "discover-commands.sh script exists" {
  [ -f "$DISCOVER_SCRIPT" ]
}

# --- Skip: nothing to read ---

@test "skips with a reason when no CLAUDE.md, AGENTS.md, Makefile, or manifest exists" {
  run bash "$DISCOVER_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]]
  # The prompt must not be printed for a step that is not running.
  [[ "$output" != *"command discovery prompt"* ]]
}

# --- Run: at least one source file exists ---

@test "builds a prompt when CLAUDE.md exists" {
  echo "## Tests
Run: \`whatever test command\`" > CLAUDE.md

  run bash "$DISCOVER_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]]
  [[ "$output" == *"command discovery prompt"* ]]
  # The prompt lists the path, not the file's own content — the model reads it itself.
  [[ "$output" == *"CLAUDE.md"* ]]
  [[ "$output" != *"whatever test command"* ]]
}

@test "tells the model to read the files itself instead of pasting their content" {
  echo "## Tests
Run: \`whatever test command\`" > CLAUDE.md

  run bash "$DISCOVER_SCRIPT"

  [[ "$output" == *"Read these files yourself"* ]]
  [[ "$output" == *"Stop reading as soon as"* ]]
}

@test "prompt requests the local-dev-loop JSON shape for test/lint/typecheck" {
  echo "some project notes" > AGENTS.md

  run bash "$DISCOVER_SCRIPT"

  [[ "$output" == *'"test"'* ]]
  [[ "$output" == *'"lint"'* ]]
  [[ "$output" == *'"typecheck"'* ]]
}

@test "prompt also requests an install command, only when the source documents one" {
  echo "some project notes" > AGENTS.md

  run bash "$DISCOVER_SCRIPT"

  [[ "$output" == *'"install"'* ]]
  [[ "$output" == *"install (installing project dependencies"* ]]
  [[ "$output" == *"guessing one here would only override"* ]]
}

@test "prompt instructs to ignore build/deploy/CI-pipeline steps" {
  echo "some project notes" > AGENTS.md

  run bash "$DISCOVER_SCRIPT"

  [[ "$output" == *"deploy"* ]]
  [[ "$output" == *"CI-only"* || "$output" == *"CI only"* ]]
}

@test "prompt instructs to prefer the recommended alternative over a discouraged shortcut" {
  echo "some project notes" > AGENTS.md

  run bash "$DISCOVER_SCRIPT"

  [[ "$output" == *"don't use"* ]] || [[ "$output" == *"broken"* ]]
}

@test "lists every source file that exists, not just the first one found, in priority order" {
  echo "claude notes" > CLAUDE.md
  cat > Makefile <<'EOF'
test:
	@exit 0
EOF
  echo '{"scripts": {"test": "jest"}}' > package.json

  run bash "$DISCOVER_SCRIPT"

  claude_line=$(grep -n "CLAUDE.md" <<< "$output" | head -1 | cut -d: -f1)
  makefile_line=$(grep -n "Makefile" <<< "$output" | head -1 | cut -d: -f1)
  package_line=$(grep -n "package.json" <<< "$output" | head -1 | cut -d: -f1)
  [[ "$output" == *"CLAUDE.md"* ]]
  [[ "$output" == *"Makefile"* ]]
  [[ "$output" == *"package.json"* ]]
  [ "$claude_line" -lt "$makefile_line" ]
  [ "$makefile_line" -lt "$package_line" ]
}

@test "a symlinked AGENTS.md pointing at CLAUDE.md is listed once, not twice" {
  echo "run tests with: npm test" > CLAUDE.md
  ln -s CLAUDE.md AGENTS.md

  run bash "$DISCOVER_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"1 source file(s) found"* ]]
  occurrences=$(grep -c "CLAUDE.md" <<< "$output")
  [ "$occurrences" -eq 1 ]
}

@test "two independently-authored files with identical content are still deduped" {
  printf 'test: npm test\n' > CLAUDE.md
  printf 'test: npm test\n' > AGENTS.md

  run bash "$DISCOVER_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"1 source file(s) found"* ]]
}

# --- Skip: cache already fresh ---

@test "skips when .scratch/commands.json already caches a matching source hash" {
  echo "claude notes" > CLAUDE.md

  # Match the script's own MAIN_ROOT: `git rev-parse --show-toplevel` resolves symlinks
  # (macOS's /var -> /private/var), which $TEMP_DIR itself does not.
  ROOT=$(git rev-parse --show-toplevel)
  HASH=$(
    { printf '%s\n' "=== $ROOT/CLAUDE.md ==="; cat CLAUDE.md; } \
      | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } \
      | awk '{print $1}'
  )
  mkdir -p .scratch
  printf '{"sourceHash": "%s", "test": null, "lint": null, "typecheck": null}' "$HASH" > .scratch/commands.json

  run bash "$DISCOVER_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]]
  [[ "$output" == *"cache is fresh"* ]]
  [[ "$output" != *"command discovery prompt"* ]]
}

@test "re-runs discovery when the cached hash does not match current source content" {
  echo "claude notes" > CLAUDE.md
  mkdir -p .scratch
  echo '{"sourceHash": "stale-hash-does-not-match", "test": "old-command"}' > .scratch/commands.json

  run bash "$DISCOVER_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]]
  [[ "$output" == *"command discovery prompt"* ]]
}

@test "--refresh forces re-discovery even when the cache is fresh" {
  echo "claude notes" > CLAUDE.md
  HASH=$(
    { printf '%s\n' "=== $TEMP_DIR/CLAUDE.md ==="; cat CLAUDE.md; } \
      | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } \
      | awk '{print $1}'
  )
  mkdir -p .scratch
  printf '{"sourceHash": "%s"}' "$HASH" > .scratch/commands.json

  run bash "$DISCOVER_SCRIPT" --refresh

  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]]
  [[ "$output" == *"command discovery prompt"* ]]
}

@test "CREW_COMMANDS_REFRESH=1 has the same effect as --refresh" {
  echo "claude notes" > CLAUDE.md
  HASH=$(
    { printf '%s\n' "=== $TEMP_DIR/CLAUDE.md ==="; cat CLAUDE.md; } \
      | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } \
      | awk '{print $1}'
  )
  mkdir -p .scratch
  printf '{"sourceHash": "%s"}' "$HASH" > .scratch/commands.json

  CREW_COMMANDS_REFRESH=1 run bash "$DISCOVER_SCRIPT"

  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]]
}

# --- Determinism ---

@test "the same source content hashes the same way across two independent runs" {
  echo "claude notes" > CLAUDE.md

  run bash "$DISCOVER_SCRIPT"
  first="$output"
  run bash "$DISCOVER_SCRIPT"
  second="$output"

  [ "$first" = "$second" ]
}

# --- No Dead Stub ---

@test "discover-commands.sh does not contain 'not yet implemented'" {
  run grep -c "not yet implemented" "$DISCOVER_SCRIPT"
  [ "$output" -eq 0 ]
}
