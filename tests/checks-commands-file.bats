#!/usr/bin/env bats

# commands-file.sh — where the dev commands file is: a tracked .coding-crew/dev-commands.json in the checkout, else
# .git/coding-crew/dev-commands.json in the clone's common dir, shared by its worktrees and never committed.
# write-commands-cache.sh writes it there, and resolve-mode.sh, run-checks.sh and discover-commands.sh read it there.

LIB="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"

setup() {
  TEMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
  MAIN="$TEMP_DIR/main" WT="$TEMP_DIR/wt"
  git init -q -b main "$MAIN"
  git -C "$MAIN" -c user.email=t@t -c user.name=T commit -q --allow-empty -m init
  git -C "$MAIN" worktree add -q --detach "$WT"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "with no file in the tree it is the clone's common dir, the same from every worktree" {
  run bash "$LIB/commands-file.sh" --project-root "$MAIN"
  [ "$output" = "$MAIN/.git/coding-crew/dev-commands.json" ]
  run bash "$LIB/commands-file.sh" --project-root "$WT"
  [ "$output" = "$MAIN/.git/coding-crew/dev-commands.json" ]
}

@test "a file in the checkout's tree wins; outside a repo it is that path" {
  mkdir -p "$WT/.coding-crew" && echo '{}' > "$WT/.coding-crew/dev-commands.json"
  run bash "$LIB/commands-file.sh" --project-root "$WT"
  [ "$output" = "$WT/.coding-crew/dev-commands.json" ]
  run bash "$LIB/commands-file.sh" --project-root "$MAIN"
  [ "$output" = "$MAIN/.git/coding-crew/dev-commands.json" ]
  mkdir "$TEMP_DIR/plain"
  run bash "$LIB/commands-file.sh" --project-root "$TEMP_DIR/plain"
  [ "$output" = "$TEMP_DIR/plain/.coding-crew/dev-commands.json" ]
}

@test "a missing or non-directory root is a usage error" {
  run bash "$LIB/commands-file.sh"
  [ "$status" -eq 2 ]
  run bash "$LIB/commands-file.sh" --project-root "$TEMP_DIR/missing"
  [ "$status" -eq 2 ]
}

@test "checks discovered in one worktree are written outside every tree and read from another" {
  printf '{"test": "echo T > %s/ran", "lint": null}\n' "$TEMP_DIR" > "$TEMP_DIR/discovered.json"
  (cd "$WT" && bash "$LIB/write-commands-cache.sh" --response-file "$TEMP_DIR/discovered.json") >/dev/null
  [ -z "$(git -C "$WT" status --porcelain)" ]
  [ ! -e "$WT/.coding-crew" ]
  grep -q '"lint": null' "$MAIN/.git/coding-crew/dev-commands.json"

  printf '{"install_mode": "docker", "docker_service": "web"}\n' > "$TEMP_DIR/answer.json"
  (cd "$MAIN" && bash "$LIB/write-commands-cache.sh" --response-file "$TEMP_DIR/answer.json") >/dev/null
  run bash "$LIB/resolve-mode.sh" --project-root "$WT"
  [ "$output" = $'INSTALL_MODE=docker\nDOCKER_SERVICE=web' ]
  grep -q '"test": "echo T' "$MAIN/.git/coding-crew/dev-commands.json"

  touch "$WT/Makefile"
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$WT" "$LIB"
  [[ "$output" == *"building discovery prompt for 6 of eight"* ]]
}

@test "run-checks runs the shared file's checks from a worktree, and says DISCOVER with none" {
  run bash "$LIB/run-checks.sh" --project-root "$WT"
  [ "$status" -eq 3 ]
  [ "$output" = DISCOVER ]
  mkdir -p "$MAIN/.git/coding-crew"
  printf '{"test": "echo T > %s/ran"}\n' "$TEMP_DIR" > "$MAIN/.git/coding-crew/dev-commands.json"
  run bash "$LIB/run-checks.sh" --project-root "$WT"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$TEMP_DIR/ran")" = T ]
}

@test "commands_field reads a string, empty for null or absent; commands_field_present counts null as present" {
  printf '{"install": "npm ci", "env": null}\n' > "$TEMP_DIR/c.json"
  run bash -c '. "$1/commands-file.sh"; commands_field "$2" install' _ "$LIB" "$TEMP_DIR/c.json"
  [ "$output" = "npm ci" ]
  run bash -c '. "$1/commands-file.sh"; commands_field "$2" env; commands_field "$2" lint; commands_field "$3" install' _ "$LIB" "$TEMP_DIR/c.json" "$TEMP_DIR/missing.json"
  [ -z "$output" ]
  run bash -c '. "$1/commands-file.sh"; commands_field_present "$2" env && commands_field_present "$2" install' _ "$LIB" "$TEMP_DIR/c.json"
  [ "$status" -eq 0 ]
  run bash -c '. "$1/commands-file.sh"; commands_field_present "$2" lint' _ "$LIB" "$TEMP_DIR/c.json"
  [ "$status" -eq 1 ]
}

@test "only commands-file.sh parses a dev-commands field" {
  run grep -ln -E '"[a-z_]*"\[\[:space:\]\]\*:|\[\[:space:\]\]\*:\[\[:space:\]\]\*' "$LIB"/*.sh
  [ "$output" = "$LIB/commands-file.sh" ]
}
