#!/usr/bin/env bats

# discover-mode.sh — the prompt asking a model where a compose project's commands run, asked once per clone:
# no compose file is host with nothing to ask, and a recorded install_mode (a hand edit included) is never re-asked.

LIB="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"

setup() {
  TEMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
  MAIN="$TEMP_DIR/main" WT="$TEMP_DIR/wt"
  git init -q -b main "$MAIN"
  printf 'services:\n  app:\n    build: .\n' > "$MAIN/docker-compose.yml"
  printf 'test:\n\tdocker compose run --rm app npm test\n' > "$MAIN/Makefile"
  git -C "$MAIN" add -A
  git -C "$MAIN" -c user.email=t@t -c user.name=T commit -q -m init
  git -C "$MAIN" worktree add -q --detach "$WT"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "no compose file: skipped, host" {
  mkdir "$TEMP_DIR/plain"
  run bash "$LIB/discover-mode.sh" --project-root "$TEMP_DIR/plain"
  [ "$status" -eq 0 ]
  [ "$output" = "Mode discovery: skipped (no compose file: host)" ]
}

@test "a compose file and no recorded mode: a prompt naming the compose file and the files to read" {
  run bash "$LIB/discover-mode.sh" --project-root "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docker-compose.yml and no install mode recorded"* ]]
  [[ "$output" == *"  - Makefile"* ]]
  [[ "$output" == *"  - docker-compose.yml"* ]]
  [[ "$output" != *"  - README.md"* ]]
  [[ "$output" == *'{"install_mode": "<docker or host>", "docker_service": "<service, or null for host>"}'* ]]
}

@test "an answer persisted from one worktree settles it for every worktree, and resolve-mode acts on it" {
  printf '{"install_mode": "docker", "docker_service": "app"}\n' > "$TEMP_DIR/answer.json"
  (cd "$WT" && bash "$LIB/write-commands-cache.sh" --response-file "$TEMP_DIR/answer.json") >/dev/null
  [ -z "$(git -C "$WT" status --porcelain)" ]
  run bash "$LIB/discover-mode.sh" --project-root "$MAIN"
  [[ "$output" == "Mode discovery: skipped (already recorded at $MAIN/.git/coding-crew/dev-commands.json)" ]]
  run bash "$LIB/resolve-mode.sh" --project-root "$WT"
  [ "$output" = $'INSTALL_MODE=docker\nDOCKER_SERVICE=app' ]
}

@test "checks discovered without a mode still ask for the mode; a host answer with a null service is recorded" {
  mkdir -p "$MAIN/.git/coding-crew"
  echo '{"test": "make test", "lint": null}' > "$MAIN/.git/coding-crew/dev-commands.json"
  run bash "$LIB/discover-mode.sh" --project-root "$WT"
  [[ "$output" == *"mode discovery prompt"* ]]
  printf '{"install_mode": "host", "docker_service": null}\n' > "$TEMP_DIR/answer.json"
  (cd "$WT" && bash "$LIB/write-commands-cache.sh" --response-file "$TEMP_DIR/answer.json") >/dev/null
  run bash "$LIB/discover-mode.sh" --project-root "$WT"
  [[ "$output" == "Mode discovery: skipped"* ]]
  grep -q '"test": "make test"' "$MAIN/.git/coding-crew/dev-commands.json"
  run bash "$LIB/resolve-mode.sh" --project-root "$WT"
  [ "$output" = $'INSTALL_MODE=host\nDOCKER_SERVICE=' ]
}

@test "a missing root is a usage error" {
  run bash "$LIB/discover-mode.sh"
  [ "$status" -eq 2 ]
  run bash "$LIB/discover-mode.sh" --project-root "$TEMP_DIR/missing"
  [ "$status" -eq 2 ]
}
