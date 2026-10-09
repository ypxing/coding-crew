#!/usr/bin/env bats

# detect-compose-bypass.sh — whether an install command that runs docker itself would miss the
# crew compose override, and with it the shared dep volumes the checks read. The docker shim adds
# the override to every `docker compose` call, so `-f`, COMPOSE_FILE and `-p` are no bypass; only
# `docker run` / `docker exec` (no compose file at all) are. docker-install.sh refuses those
# (exit 5) before running them.

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

@test "plain docker compose is no bypass" {
  recipe "docker compose run --rm node pnpm install"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "-f, --file and the legacy docker-compose binary are no bypass: the shim still adds the override" {
  recipe "cd . && docker compose -f docker-compose.yml run --rm node pnpm install" \
         "docker-compose --file=ci.yml run node npm ci"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "-p and COMPOSE_PROJECT_NAME are no bypass" {
  recipe "docker compose -p other run --rm node pnpm i"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 1 ]

  run bash "$SCRIPT" --dir "$WORK" --cmd "COMPOSE_PROJECT_NAME=x docker compose run node i"
  [ "$status" -eq 1 ]
}

@test "COMPOSE_FILE in the command, the environment or the project's .env is no bypass" {
  run bash "$SCRIPT" --dir "$WORK" --cmd "COMPOSE_FILE=a.yml docker compose run node i"
  [ "$status" -eq 1 ]

  COMPOSE_FILE=b.yml run bash "$SCRIPT" --dir "$WORK" --cmd "docker compose run node i"
  [ "$status" -eq 1 ]

  printf 'COMPOSE_FILE="docker-compose.yml:docker-compose.ci.yml"\n' > "$WORK/.env"
  run bash "$SCRIPT" --dir "$WORK" --cmd "docker compose run node i"
  [ "$status" -eq 1 ]
}

@test "a make variable is expanded before judging" {
  printf 'DC = docker compose -f base.yml\ndeps:\n\t$(DC) run --rm node pnpm i\n' > "$WORK/Makefile"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 1 ]

  printf 'DC = docker\ndeps:\n\t$(DC) run --rm node:20 npm ci\n' > "$WORK/Makefile"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`docker run` loads no compose file'* ]]
}

@test "docker run and docker exec load no compose file at all" {
  recipe "docker run --rm node:20 npm ci" "docker exec app npm ci"
  run bash "$SCRIPT" --dir "$WORK" --cmd "make deps"
  [ "$status" -eq 0 ]
  [[ "$output" == *'`docker run` loads no compose file'* ]]
  [[ "$output" == *'`docker exec` loads no compose file'* ]]
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
