#!/usr/bin/env bats

# detect-compose-bypass.sh — whether an install command that runs docker itself would miss the
# generated docker-compose.override.yml, and with it the shared dep volumes the checks read.
# docker-install.sh refuses such a command (exit 5) before running it.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/detect-compose-bypass.sh"

setup() {
  unset COMPOSE_FILE COMPOSE_PROJECT_NAME
  WORK=$(mktemp -d)
}

teardown() {
  rm -rf "$WORK"
}

# recipe <line>... — a Makefile whose `deps` target runs the given lines.
recipe() {
  { echo "deps:"; printf '\t%s\n' "$@"; } > "$WORK/Makefile"
}

@test "plain docker compose loads the override by discovery: no bypass" {
  recipe "docker compose run --rm node pnpm install"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "-f without the override is a bypass, named with the call it came from" {
  recipe "cd . && docker compose -f docker-compose.yml run --rm node pnpm install"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 0 ]
  [[ "$output" == '`-f docker-compose.yml` replaces compose'*": docker compose -f docker-compose.yml run --rm node pnpm install" ]]
}

@test "-f that also names the override is not a bypass" {
  recipe "docker compose -f docker-compose.yml -f docker-compose.override.yml run --rm node pnpm i"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 1 ]
}

@test "the legacy docker-compose binary is judged the same way" {
  recipe "docker-compose --file=ci.yml run node npm ci"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-f ci.yml"* ]]
}

@test "a -p before the subcommand renames the project; a -p after it is run's port publish" {
  recipe "docker compose -p other run --rm node pnpm i"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 0 ]
  [[ "$output" == *"renames the compose project"* ]]

  recipe "docker compose run --rm -p 8080:80 node pnpm i"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 1 ]
}

@test "a make variable is expanded before judging" {
  printf 'DC = docker compose -f base.yml\ndeps:\n\t$(DC) run --rm node pnpm i\n' > "$WORK/Makefile"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 0 ]
  [[ "$output" == *"-f base.yml"* ]]
}

@test "docker run and docker exec load no compose file at all" {
  recipe "docker run --rm node:20 npm ci" "docker exec app npm ci"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`docker run` loads no compose file'* ]]
  [[ "$output" == *'`docker exec` loads no compose file'* ]]
}

@test "COMPOSE_FILE in the command, the environment or the project's .env is a bypass unless it lists the override" {
  run bash "$SCRIPT" --dir "$WORK" --cmd "COMPOSE_FILE=a.yml docker compose run node i"
  [ "$status" -eq 0 ]
  [[ "$output" == "the command sets COMPOSE_FILE=a.yml"* ]]

  COMPOSE_FILE=b.yml run bash "$SCRIPT" --dir "$WORK" --cmd "docker compose run node i"
  [ "$status" -eq 0 ]
  [[ "$output" == "the environment sets COMPOSE_FILE=b.yml"* ]]

  printf 'COMPOSE_FILE="docker-compose.yml:docker-compose.ci.yml"\n' > "$WORK/.env"
  run bash "$SCRIPT" --dir "$WORK" --cmd "docker compose run node i"
  [ "$status" -eq 0 ]
  [[ "$output" == ".env sets COMPOSE_FILE=docker-compose.yml:docker-compose.ci.yml"* ]]

  printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml\n' > "$WORK/.env"
  run bash "$SCRIPT" --dir "$WORK" --cmd "docker compose run node i"
  [ "$status" -eq 1 ]
}

@test "COMPOSE_PROJECT_NAME renames the project" {
  run bash "$SCRIPT" --dir "$WORK" --cmd "COMPOSE_PROJECT_NAME=x docker compose run node i"
  [ "$status" -eq 0 ]
  [[ "$output" == *"renames the compose project"* ]]
}

@test "a command it cannot expand has nothing to object to" {
  run bash "$SCRIPT" --dir "$WORK" --cmd "./scripts/install.sh"
  [ "$status" -eq 1 ]
}

@test "--dir and --cmd are required" {
  run bash "$SCRIPT" --dir "$WORK"
  [ "$status" -eq 2 ]
}

@test "the script is shipped executable" {
  [ -x "$SCRIPT" ]
}
