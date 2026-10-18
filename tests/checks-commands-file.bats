#!/usr/bin/env bats

# commands-file.sh — where the dev commands file is: the main checkout's .coding-crew/dev-commands.json, committed or
# not, read and written from every worktree of the clone. write-commands-cache.sh writes it there, and resolve-mode.sh,
# run-checks.sh and discover-commands.sh read it there.

LIB="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"

setup() {
  TEMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
  MAIN="$TEMP_DIR/main" WT="$TEMP_DIR/wt" WT2="$TEMP_DIR/wt2"
  git init -q -b main "$MAIN"
  git -C "$MAIN" -c user.email=t@t -c user.name=T commit -q --allow-empty -m init
  git -C "$MAIN" worktree add -q --detach "$WT"
  git -C "$MAIN" worktree add -q --detach "$WT2"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# where <root> — commands-file.sh's answer for <root>
where() { bash "$LIB/commands-file.sh" --project-root "$1"; }

@test "it is the main checkout's file from the main checkout, a linked worktree or a subdirectory, the file missing" {
  mkdir -p "$MAIN/sub" "$WT/sub"
  for root in "$MAIN" "$WT" "$MAIN/sub" "$WT/sub"; do
    [ "$(where "$root")" = "$MAIN/.coding-crew/dev-commands.json" ] || { echo "$root: $(where "$root")"; return 1; }
  done
}

@test "it is the main checkout's file whether committed or untracked, never the worktree's own or under .git" {
  mkdir -p "$MAIN/.coding-crew" && echo '{}' > "$MAIN/.coding-crew/dev-commands.json"
  [ "$(where "$WT")" = "$MAIN/.coding-crew/dev-commands.json" ]
  git -C "$MAIN" add .coding-crew && git -C "$MAIN" -c user.email=t@t -c user.name=T commit -q -m cmds
  git -C "$MAIN" worktree add -q --detach "$TEMP_DIR/wt3"
  [ -f "$TEMP_DIR/wt3/.coding-crew/dev-commands.json" ]
  [ "$(where "$TEMP_DIR/wt3")" = "$MAIN/.coding-crew/dev-commands.json" ]
  [ "$(where "$MAIN")" = "$MAIN/.coding-crew/dev-commands.json" ]
  [[ "$(where "$WT")" != *"/.git/"* ]]
}

@test "outside a git repository it is that path" {
  mkdir "$TEMP_DIR/plain"
  [ "$(where "$TEMP_DIR/plain")" = "$TEMP_DIR/plain/.coding-crew/dev-commands.json" ]
}

@test "a missing or non-directory root is a usage error" {
  run bash "$LIB/commands-file.sh"
  [ "$status" -eq 2 ]
  run bash "$LIB/commands-file.sh" --project-root "$TEMP_DIR/missing"
  [ "$status" -eq 2 ]
}

@test "checks discovered in one worktree land in the main checkout's file, read from another, both trees clean" {
  printf '{"test": "echo T > %s/ran", "lint": null}\n' "$TEMP_DIR" > "$TEMP_DIR/discovered.json"
  (cd "$WT" && bash "$LIB/write-commands-cache.sh" --response-file "$TEMP_DIR/discovered.json") >/dev/null
  [ ! -e "$WT/.coding-crew" ]
  grep -q '"lint": null' "$MAIN/.coding-crew/dev-commands.json"

  printf '{"install_mode": "docker", "docker_service": "web"}\n' > "$TEMP_DIR/answer.json"
  (cd "$MAIN" && bash "$LIB/write-commands-cache.sh" --response-file "$TEMP_DIR/answer.json") >/dev/null
  run bash "$LIB/resolve-mode.sh" --project-root "$WT2"
  [ "$output" = $'INSTALL_MODE=docker\nDOCKER_SERVICE=web' ]
  grep -q '"test": "echo T' "$MAIN/.coding-crew/dev-commands.json"

  touch "$WT/Makefile"
  run bash -c 'cd "$1" && bash "$2/discover-commands.sh"' _ "$WT" "$LIB"
  [[ "$output" == *"building discovery prompt for 6 of eight"* ]]
  rm "$WT/Makefile"
  [ -z "$(git -C "$WT" status --porcelain)" ]
  [ -z "$(git -C "$WT2" status --porcelain)" ]
  [ "$(git -C "$MAIN" status --porcelain)" = "?? .coding-crew/" ]
}

@test "run-checks in a second worktree runs what the first one wrote, and says DISCOVER with none" {
  run bash "$LIB/run-checks.sh" --project-root "$WT2"
  [ "$status" -eq 3 ]
  [ "$output" = DISCOVER ]
  printf '{"test": "echo T > %s/ran"}\n' "$TEMP_DIR" > "$TEMP_DIR/discovered.json"
  (cd "$WT" && bash "$LIB/write-commands-cache.sh" --response-file "$TEMP_DIR/discovered.json") >/dev/null
  run bash "$LIB/run-checks.sh" --project-root "$WT2"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$TEMP_DIR/ran")" = T ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
  [ -z "$(git -C "$WT2" status --porcelain)" ]
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

@test "commands_field unescapes a JSON string, and write-commands-cache.sh escapes it again" {
  printf '%s\n' '{"test": "pytest -m \"not slow\" && echo a\\b", "lint": "x"}' > "$TEMP_DIR/c.json"
  run bash -c '. "$1/commands-file.sh"; commands_field "$2" test' _ "$LIB" "$TEMP_DIR/c.json"
  [ "$output" = 'pytest -m "not slow" && echo a\b' ]
  (cd "$MAIN" && bash "$LIB/write-commands-cache.sh" --response-file "$TEMP_DIR/c.json") >/dev/null
  run bash -c '. "$1/commands-file.sh"; commands_field "$2" test' _ "$LIB" "$MAIN/.coding-crew/dev-commands.json"
  [ "$output" = 'pytest -m "not slow" && echo a\b' ]
}

@test "run-checks asks for discovery when only a value, not a key, is \"test\"" {
  mkdir -p "$MAIN/.coding-crew"
  printf '{"docker_service": "test", "lint": "true"}\n' > "$MAIN/.coding-crew/dev-commands.json"
  run bash "$LIB/run-checks.sh" --project-root "$MAIN"
  [ "$status" -eq 3 ]
  [ "$output" = DISCOVER ]
}

@test "only commands-file.sh parses a dev-commands field" {
  run grep -ln -E '"[a-z_]*"\[\[:space:\]\]\*:|\[\[:space:\]\]\*:\[\[:space:\]\]\*|grep[^|]*'"'"'"[a-z_]+"'"'" "$LIB"/*.sh
  [ "$output" = "$LIB/commands-file.sh" ]
}
