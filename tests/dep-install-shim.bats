#!/usr/bin/env bats

# shim/docker and shim/docker-compose: add the worktree's crew override as the last -f of
# every `docker compose` call. A fake `docker` / `docker-compose` behind the shim logs its argv.

bats_require_minimum_version 1.5.0

SHIM_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/shim"

setup() {
  TEMP_DIR=$(mktemp -d)
  TEMP_DIR="$(cd "$TEMP_DIR" && pwd -P)"
  FAKE="$TEMP_DIR/fake-bin"
  mkdir -p "$FAKE"
  LOG="$TEMP_DIR/argv.log"
  for bin in docker docker-compose; do
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s"\n' "$LOG" > "$FAKE/$bin"
    chmod +x "$FAKE/$bin"
  done
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK"
  git -C "$WORK" init -q
  OVERRIDE="$TEMP_DIR/override.yml"
  : > "$OVERRIDE"
  export PATH="$SHIM_DIR:$FAKE:$PATH"
  export CREW_COMPOSE_OVERRIDE="$OVERRIDE"
  unset COMPOSE_FILE COMPOSE_PATH_SEPARATOR
  cd "$WORK"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# logged — the argv the fake binary saw, space-joined.
logged() { tr '\n' ' ' < "$LOG" | sed 's/ $//'; }

@test "-f flags: the override goes last, just before the subcommand" {
  run docker compose -f a.yml -f b.yml run app x
  [ "$status" -eq 0 ]
  [ "$(logged)" = "compose -f a.yml -f b.yml -f $OVERRIDE run app x" ]
}

@test "COMPOSE_FILE with no -f: its entries become -f flags, then the override" {
  COMPOSE_FILE=a.yml:b.yml run docker compose run app x
  [ "$(logged)" = "compose -f a.yml -f b.yml -f $OVERRIDE run app x" ]
}

@test "COMPOSE_PATH_SEPARATOR splits COMPOSE_FILE" {
  COMPOSE_FILE='a.yml;b.yml' COMPOSE_PATH_SEPARATOR=';' run docker compose up
  [ "$(logged)" = "compose -f a.yml -f b.yml -f $OVERRIDE up" ]
}

@test "neither -f nor COMPOSE_FILE: the default compose file and the project's own override come first" {
  touch docker-compose.yml docker-compose.override.yml
  run docker compose run app x
  [ "$(logged)" = "compose -f $WORK/docker-compose.yml -f $WORK/docker-compose.override.yml -f $OVERRIDE run app x" ]
}

@test "a default compose file with no override of its own adds just itself" {
  touch compose.yaml
  run docker compose up
  [ "$(logged)" = "compose -f $WORK/compose.yaml -f $OVERRIDE up" ]
}

@test "default discovery searches parent directories, as compose does" {
  touch docker-compose.yml
  mkdir sub && cd sub
  run docker compose up
  [ "$(logged)" = "compose -f $WORK/docker-compose.yml -f $OVERRIDE up" ]
}

@test "--project-directory names the dir the default files come from" {
  mkdir proj && touch proj/docker-compose.yml proj/docker-compose.override.yml
  run docker compose --project-directory proj run app
  [ "$(logged)" = "compose --project-directory proj -f proj/docker-compose.yml -f proj/docker-compose.override.yml -f $OVERRIDE run app" ]
}

@test "no compose file anywhere: the call passes through unchanged" {
  run docker compose up
  [ "$(logged)" = "compose up" ]
}

@test "a value-taking option's value is not mistaken for the subcommand" {
  touch docker-compose.yml
  local opt
  for opt in "-p proj" "--project-name proj" "--project-directory $WORK" "--env-file e.env" "--profile dev" \
             "--ansi never" "--progress plain" "--parallel 2"; do
    run docker compose $opt run app x
    [ "$status" -eq 0 ]
    [[ "$(logged)" == "compose $opt "*"-f $OVERRIDE run app x" ]]
  done
}

@test "docker's own value-taking options before compose are skipped too" {
  local opt
  for opt in "-c ctx" "--context ctx" "-H tcp://h:1" "--host tcp://h:1" "--config /c" "-l debug" "--log-level debug"; do
    run docker $opt compose -f a.yml run app
    [ "$status" -eq 0 ]
    [ "$(logged)" = "$opt compose -f a.yml -f $OVERRIDE run app" ]
  done
}

@test "docker-compose gets the same insertion" {
  run docker-compose -f a.yml run app x
  [ "$(logged)" = "-f a.yml -f $OVERRIDE run app x" ]
  COMPOSE_FILE=a.yml:b.yml run docker-compose -p proj up
  [ "$(logged)" = "-p proj -f a.yml -f b.yml -f $OVERRIDE up" ]
}

@test "a non-compose docker command passes through unchanged" {
  run docker ps -a --format '{{.ID}}'
  [ "$(logged)" = "ps -a --format {{.ID}}" ]
  run docker -H tcp://h:1 run --rm img
  [ "$(logged)" = "-H tcp://h:1 run --rm img" ]
}

@test "no override (unset and none in the git dir): argv passes through unchanged" {
  unset CREW_COMPOSE_OVERRIDE
  run docker compose -f a.yml run app
  [ "$(logged)" = "compose -f a.yml run app" ]
}

@test "no CREW_COMPOSE_OVERRIDE: the cwd's git dir override is used" {
  unset CREW_COMPOSE_OVERRIDE
  git_dir="$(git rev-parse --path-format=absolute --git-dir)"
  : > "$git_dir/crew-compose.override.yml"
  mkdir sub && cd sub
  run docker compose -f a.yml run app
  [ "$(logged)" = "compose -f a.yml -f $git_dir/crew-compose.override.yml run app" ]
}

@test "cwd outside a git repo with no override variable: passes through unchanged" {
  unset CREW_COMPOSE_OVERRIDE
  mkdir "$TEMP_DIR/nogit" && cd "$TEMP_DIR/nogit"
  GIT_CEILING_DIRECTORIES="$TEMP_DIR" run docker compose -f a.yml run app
  [ "$(logged)" = "compose -f a.yml run app" ]
}

@test "no subcommand found: passes through unchanged with one crew-shim: line on stderr" {
  run --separate-stderr docker compose --help
  [ "$status" -eq 0 ]
  [ "$(logged)" = "compose --help" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$stderr" == "crew-shim: "* ]]
}

@test "the real docker is found with the shim's own dir removed from PATH" {
  # The shim dir is first on PATH; if it resolved itself this would loop forever.
  run timeout 10 docker compose -f a.yml up
  [ "$status" -eq 0 ]
  [ -f "$LOG" ]
}

@test "no real docker on PATH: exit 127 with a crew-shim: message" {
  run --separate-stderr env PATH="$SHIM_DIR:/nonexistent" "$BASH" "$SHIM_DIR/docker" compose up
  [ "$status" -eq 127 ]
  [ "$stderr" = "crew-shim: no real docker on PATH" ]
}

@test "the argv reaches the real binary byte for byte, spaces and quotes included" {
  run docker compose -f 'a b.yml' run app sh -c 'echo "hi there" && exit 0'
  mapfile -t got < "$LOG"
  [ "${got[2]}" = "a b.yml" ]
  [ "${got[${#got[@]} - 1]}" = 'echo "hi there" && exit 0' ]
}
