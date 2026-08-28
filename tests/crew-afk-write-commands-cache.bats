#!/usr/bin/env bats

# Tests for write-commands-cache.sh — turns a model's discovery response into
# .coding-crew/dev-commands.json. The sibling of discover-commands.sh: that script decides
# whether a model call is needed and builds its prompt; this one takes the model's answer and
# persists it. The file is committed and human-editable, so once it exists discover-commands.sh
# trusts it as-is (bootstrap-once) until a human clears it or passes --refresh — there is no
# staleness stamp for this script to compute or compare.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
# Canonical source is scripts/skill-utils/git-workflow/ (shared by crew-afk and solve-issue
# at install time via their registry.json `scripts` field) — not skills/crew-afk/scripts/.
WRITE_SCRIPT="$SCRIPT_DIR/scripts/skill-utils/git-workflow/write-commands-cache.sh"
DISCOVER_SCRIPT="$SCRIPT_DIR/scripts/skill-utils/git-workflow/discover-commands.sh"
CACHE_FILE=".coding-crew/dev-commands.json"

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

@test "write-commands-cache.sh script exists" {
  [ -f "$WRITE_SCRIPT" ]
}

# --- Happy path ---

@test "writes all three commands from a clean JSON response" {
  echo "claude notes" > CLAUDE.md
  echo '{"test": "npm test", "lint": "npm run lint", "typecheck": "tsc --noEmit"}' > response.txt

  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  [ -f "$CACHE_FILE" ]
  grep -q '"test": *"npm test"' "$CACHE_FILE"
  grep -q '"lint": *"npm run lint"' "$CACHE_FILE"
  grep -q '"typecheck": *"tsc --noEmit"' "$CACHE_FILE"
}

@test "writes a fourth install command from a response that documents one" {
  echo "claude notes" > CLAUDE.md
  echo '{"test": "npm test", "lint": "npm run lint", "typecheck": "tsc --noEmit", "install": "make bootstrap"}' > response.txt

  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  grep -q '"install": *"make bootstrap"' "$CACHE_FILE"
}

@test "writes a fifth env command from a response that documents one" {
  echo "claude notes" > CLAUDE.md
  echo '{"test": "npm test", "lint": "npm run lint", "typecheck": "tsc --noEmit", "install": "make bootstrap", "env": "make env"}' > response.txt

  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  grep -q '"env": *"make env"' "$CACHE_FILE"
}

@test "writes null for install when the response omits it, same as the other three" {
  echo "claude notes" > CLAUDE.md
  echo '{"test": "npm test", "lint": "npm run lint", "typecheck": "tsc --noEmit"}' > response.txt

  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  grep -q '"install": *null' "$CACHE_FILE"
}

@test "writes null for env when the response omits it, same as the other four" {
  echo "claude notes" > CLAUDE.md
  echo '{"test": "npm test", "lint": "npm run lint", "typecheck": "tsc --noEmit"}' > response.txt

  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  grep -q '"env": *null' "$CACHE_FILE"
}

@test "a response with only install recognisable still succeeds" {
  echo "claude notes" > CLAUDE.md
  echo '{"install": "make bootstrap"}' > response.txt

  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  grep -q '"install": *"make bootstrap"' "$CACHE_FILE"
  grep -q '"test": *null' "$CACHE_FILE"
}

@test "a response with only env recognisable still succeeds" {
  echo "claude notes" > CLAUDE.md
  echo '{"env": "make env"}' > response.txt

  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  grep -q '"env": *"make env"' "$CACHE_FILE"
  grep -q '"test": *null' "$CACHE_FILE"
}

# --- Schema: exactly the five fields, no sourceHash ---

@test "the written cache has exactly the five fields, and no sourceHash key" {
  echo "claude notes" > CLAUDE.md
  echo '{"test": "npm test", "lint": "npm run lint", "typecheck": "tsc --noEmit", "install": "make bootstrap", "env": "make env"}' > response.txt

  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  run grep -q "sourceHash" "$CACHE_FILE"
  [ "$status" -ne 0 ]
  for field in test lint typecheck install env; do
    grep -q "\"$field\"" "$CACHE_FILE"
  done
}

# --- Bootstrap-once: writing the cache is what makes discover-commands.sh skip ---

@test "once written, a subsequent discover-commands.sh run skips (bootstrap-only, no re-check)" {
  echo "claude notes" > CLAUDE.md
  echo '{"test": "npm test", "lint": "npm run lint", "typecheck": "tsc --noEmit"}' > response.txt

  bash "$WRITE_SCRIPT" --response-file response.txt

  run bash "$DISCOVER_SCRIPT"
  [[ "$output" == *"skipped"* ]]
  [[ "$output" == *"already cached"* ]]
}

@test "a symlinked AGENTS.md is not needed for the written cache to make discovery skip afterward" {
  echo "run tests with: npm test" > CLAUDE.md
  ln -s CLAUDE.md AGENTS.md
  echo '{"test": "npm test", "lint": null, "typecheck": null}' > response.txt

  bash "$WRITE_SCRIPT" --response-file response.txt

  run bash "$DISCOVER_SCRIPT"
  [[ "$output" == *"skipped"* ]]
  [[ "$output" == *"already cached"* ]]
}

# --- null handling ---

@test "writes null (not the literal string) for a category the model found no command for" {
  echo "claude notes" > CLAUDE.md
  echo '{"test": "npm test", "lint": null, "typecheck": null}' > response.txt

  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  grep -q '"lint": *null' "$CACHE_FILE"
  grep -q '"typecheck": *null' "$CACHE_FILE"
  # Must not have quoted the null into the string "null".
  run grep -q '"lint": *"null"' "$CACHE_FILE"
  [ "$status" -ne 0 ]
}

# --- Robust extraction ---

@test "extracts the JSON even when wrapped in prose and a markdown code fence" {
  echo "claude notes" > CLAUDE.md
  cat > response.txt <<'EOF'
Sure, here's what I found:

```json
{"test": "make test", "lint": "make lint", "typecheck": null}
```

Let me know if you need anything else.
EOF

  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  grep -q '"test": *"make test"' "$CACHE_FILE"
  grep -q '"lint": *"make lint"' "$CACHE_FILE"
}

# --- Usage errors ---

@test "fails with a usage error when --response-file is missing" {
  run bash "$WRITE_SCRIPT"

  [ "$status" -ne 0 ]
  [ ! -f "$CACHE_FILE" ]
}

@test "fails when the response file does not exist" {
  run bash "$WRITE_SCRIPT" --response-file does-not-exist.txt

  [ "$status" -ne 0 ]
  [ ! -f "$CACHE_FILE" ]
}

# --- Garbage response: never destroy a prior good (possibly hand-edited) cache ---

@test "an unparseable response fails and leaves an existing cache untouched" {
  echo "claude notes" > CLAUDE.md
  mkdir -p .coding-crew
  echo '{"test": "old command", "lint": null, "typecheck": null}' > "$CACHE_FILE"

  echo "I could not find any commands, sorry about that." > response.txt
  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -ne 0 ]
  grep -q "old command" "$CACHE_FILE"
}

@test "an unparseable response leaves a hand-edited cache untouched, exit non-zero" {
  mkdir -p .coding-crew
  echo '{"test": "hand-edited command", "lint": null, "typecheck": null, "install": null, "env": null}' > "$CACHE_FILE"

  echo "no recognizable fields in this response at all" > response.txt
  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -ne 0 ]
  grep -q "hand-edited command" "$CACHE_FILE"
}

# --- Directory creation ---

@test "creates .coding-crew/ if it does not exist yet" {
  echo "claude notes" > CLAUDE.md
  echo '{"test": "npm test", "lint": null, "typecheck": null}' > response.txt

  [ ! -d .coding-crew ]
  run bash "$WRITE_SCRIPT" --response-file response.txt

  [ "$status" -eq 0 ]
  [ -f "$CACHE_FILE" ]
}

# --- MAIN_ROOT resolution from inside a worktree ---

@test "writes to the main checkout's .coding-crew, not a linked worktree's own, when \$MAIN_ROOT is exported" {
  echo "claude notes" > CLAUDE.md
  git branch feat
  git worktree add "$TEMP_DIR/wt" feat -q

  echo '{"test": "npm test", "lint": null, "typecheck": null}' > response.txt
  cd wt
  MAIN_ROOT="$TEMP_DIR" run bash "$WRITE_SCRIPT" --response-file "$TEMP_DIR/response.txt"

  [ "$status" -eq 0 ]
  [ -f "$TEMP_DIR/.coding-crew/dev-commands.json" ]
  [ ! -d ".coding-crew" ]
}

@test "writes to the main checkout's .coding-crew when run from inside a linked worktree with no \$MAIN_ROOT set" {
  echo "claude notes" > CLAUDE.md
  git branch feat
  git worktree add "$TEMP_DIR/wt" feat -q

  echo '{"test": "npm test", "lint": null, "typecheck": null}' > response.txt
  cd wt
  run bash "$WRITE_SCRIPT" --response-file "$TEMP_DIR/response.txt"

  [ "$status" -eq 0 ]
  [ -f "$TEMP_DIR/.coding-crew/dev-commands.json" ]
  [ ! -d ".coding-crew" ]
}

# --- No Dead Stub ---

@test "write-commands-cache.sh does not contain 'not yet implemented'" {
  run grep -c "not yet implemented" "$WRITE_SCRIPT"
  [ "$output" -eq 0 ]
}
