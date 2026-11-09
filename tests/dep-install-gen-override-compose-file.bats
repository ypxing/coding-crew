#!/usr/bin/env bats

# gen-override.sh: which compose file it reads — Docker's default names, in Docker's order, so it reads the
# file `docker compose` runs.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"
SCRIPT="$SCRIPTS_DIR/gen-override.sh"

setup() {
  ROOT=$(mktemp -d)
  git init -q "$ROOT"
  echo '{"name":"fixture"}' > "$ROOT/package.json"
}

teardown() {
  [ -n "${ROOT:-}" ] && rm -rf "$ROOT"
  return 0
}

@test "a compose.yaml, Docker's preferred name, is read" {
  printf 'services:\n  app:\n    build: .\n' > "$ROOT/compose.yaml"
  run bash "$SCRIPT" --project-root "$ROOT" --query services
  [ "$status" -eq 0 ]
  [ "$output" = app ]
}

@test "with compose.yaml and docker-compose.yml both present, compose.yaml is read, the one docker compose runs" {
  printf 'services:\n  web:\n    build: .\n    volumes:\n      - .:/srv\n' > "$ROOT/compose.yaml"
  printf 'services:\n  app:\n    build: .\n    volumes:\n      - .:/opt/app\n' > "$ROOT/docker-compose.yml"
  run bash "$SCRIPT" --project-root "$ROOT" --query services
  [ "$output" = web ]
  run bash "$SCRIPT" --project-root "$ROOT" --query container-src
  [ "$output" = /srv ]
}

@test "no compose file: exit 2, the message lists all four names in Docker's order" {
  run bash "$SCRIPT" --project-root "$ROOT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Expected one of: compose.yaml, compose.yml, docker-compose.yaml, docker-compose.yml"* ]]
}
