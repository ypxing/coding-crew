#!/usr/bin/env bats

# discover-commands.sh — the prompt asking a model for a repo's dev-loop commands; it ends with the
# commands that save the answer, so every skill that discovers them saves them the same way.

LIB="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"

setup() {
  TEMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
  REPO="$TEMP_DIR/repo"
  git init -q -b main "$REPO"
  printf 'test:\n\tnpm test\n' > "$REPO/Makefile"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "the prompt asks for the bare test command, not one wrapped in a container run" {
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$REPO" "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker compose run"* ]]
}

@test "the prompt's save commands, run with an answer filled in, record it in the dev commands file and touch nothing else" {
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$REPO" "$LIB"
  [[ "$output" == *"write-commands-cache.sh"* ]]
  [[ "$output" == *"rm -f $REPO/.discovered-commands.json"* ]]
  block=$(printf '%s\n' "$output" | awk '/^cat > /{f=1} f{print} /^rm -f /{f=0}' \
    | sed -e 's/"<command or null[^"]*>"/null/g' -e 's/"test": null/"test": "make test"/')
  [ -n "$block" ]
  (cd "$TEMP_DIR" && bash -c "$block")
  [ "$(git -C "$REPO" status --porcelain -uall -- . ':!Makefile')" = "?? .coding-crew/dev-commands.json" ]
  grep -q '"test": "make test"' "$REPO/.coding-crew/dev-commands.json"
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$REPO" "$LIB"
  [[ "$output" == "Command discovery: skipped (already cached"* ]]
}

@test "a repo with no doc or known manifest gets convention-based save commands, and saving them ends discovery" {
  rm "$REPO/Makefile"
  touch "$REPO/pom.xml"
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$REPO" "$LIB"
  [ "$status" -eq 0 ]
  block=$(printf '%s\n' "$output" | awk '/^cat > /{f=1} f{print} /^rm -f /{f=0}' \
    | sed -e 's/"<command or null[^"]*>"/null/g' -e 's/"test": null/"test": "mvn test"/')
  [ -n "$block" ]
  (cd "$TEMP_DIR" && bash -c "$block")
  grep -q '"test": "mvn test"' "$REPO/.coding-crew/dev-commands.json"
  run bash "$LIB/run-checks.sh" --project-root "$REPO"
  [[ "$output" != *"DISCOVER"* ]]
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$REPO" "$LIB"
  [[ "$output" == "Command discovery: skipped"* ]]
}

@test "CI workflows are listed last and the prompt asks for their local checks as check:<name> keys" {
  mkdir -p "$REPO/.github/workflows"
  printf 'on: push\n' > "$REPO/.github/workflows/ci.yml"
  printf 'on: pull_request\n' > "$REPO/.github/workflows/api.yaml"
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$REPO" "$LIB"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -E '^  - ' | tr '\n' ' ')" = "  - Makefile   - .github/workflows/api.yaml   - .github/workflows/ci.yml " ] || { echo "$output"; return 1; }
  [[ "$output" == *'"check:<name>": "<command>"'* ]] || { echo "$output"; return 1; }
}

@test "a repo whose only candidate is a workflow gets the full prompt, not the ecosystem fallback" {
  rm "$REPO/Makefile"
  mkdir -p "$REPO/.github/workflows" && printf 'on: push\n' > "$REPO/.github/workflows/ci.yml"
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$REPO" "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ecosystem-convention fallback"* ]]
  [[ "$output" == *"  - .github/workflows/ci.yml"*'check:<name>'* ]] || { echo "$output"; return 1; }
}

@test "--refresh hands --refresh to the writer, so the answer's check keys replace the file's; a first discovery does not" {
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$REPO" "$LIB"
  [[ "$output" == *"write-commands-cache.sh --response-file .discovered-commands.json)"* ]] || { echo "$output"; return 1; }
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh" --refresh' _ "$REPO" "$LIB"
  [[ "$output" == *"write-commands-cache.sh --response-file .discovered-commands.json --refresh)"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'check:<name>'* ]]
}

@test "with every fixed field cached and no check key, discovery is still skipped, workflows or not" {
  mkdir -p "$REPO/.github/workflows" "$REPO/.coding-crew"
  printf 'on: push\n' > "$REPO/.github/workflows/ci.yml"
  echo '{"test": "t", "lint": null, "typecheck": null, "install": null, "env": null, "registry_auth": null, "coverage": null, "integration": null}' \
    > "$REPO/.coding-crew/dev-commands.json"
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$REPO" "$LIB"
  [[ "$output" == "Command discovery: skipped (already cached"* ]]
}

@test "a partial discovery names the commands the file already holds, so a check does not repeat one" {
  mkdir -p "$REPO/.github/workflows" "$REPO/.coding-crew"
  printf 'on: push\n' > "$REPO/.github/workflows/ci.yml"
  echo '{"test": "make test", "lint": null, "typecheck": "tsc", "check:api": "npm run api"}' > "$REPO/.coding-crew/dev-commands.json"
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$REPO" "$LIB"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`make test`'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'`tsc`'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *'check:api: `npm run api`'* ]] || { echo "$output"; return 1; }
}
