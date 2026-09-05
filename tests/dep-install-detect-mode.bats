#!/usr/bin/env bats

# detect-mode.sh's Makefile scan: a candidate install/deps/... target is dry-run via
# `make -n` so indirection through Make's own variables and ifeq branches is resolved by
# Make itself, not re-implemented as text-pattern matching. Same pattern as
# host-install.sh's own install/deps scan and ensure-env.sh's _makefile_env_command.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/detect-mode.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK"
  git -C "$WORK" init -q
  git -C "$WORK" config user.email t@test
  git -C "$WORK" config user.name T
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "resolves a docker verdict through multi-level Makefile variable indirection and an ifeq toggle" {
  cat > "$WORK/Makefile" <<'MK'
DOCKER_COMPOSE = docker compose
DOCKER_COMPOSE_RUN = $(DOCKER_COMPOSE) run --rm
DOCKER_COMPOSE_RUN_NODE = $(DOCKER_COMPOSE_RUN) --remove-orphans node

USE_DOCKER ?= true

ifeq ($(USE_DOCKER),true)
    RUN_IN_DOCKER=$(DOCKER_COMPOSE_RUN_NODE) make
else
    RUN_IN_DOCKER=make
endif

deps:
	@$(RUN_IN_DOCKER) _deps
MK

  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "USE_DOCKER" ]
}

@test "the same indirected Makefile defaulted to USE_DOCKER=false resolves via Make's own ifeq" {
  cat > "$WORK/Makefile" <<'MK'
DOCKER_COMPOSE = docker compose
DOCKER_COMPOSE_RUN = $(DOCKER_COMPOSE) run --rm
DOCKER_COMPOSE_RUN_NODE = $(DOCKER_COMPOSE_RUN) --remove-orphans node

USE_DOCKER ?= false

ifeq ($(USE_DOCKER),true)
    RUN_IN_DOCKER=$(DOCKER_COMPOSE_RUN_NODE) make
else
    RUN_IN_DOCKER=make
endif

deps:
	@$(RUN_IN_DOCKER) _deps
MK

  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "USE_HOST" ]
}

@test "a direct docker recipe under a candidate target is still detected" {
  cat > "$WORK/Makefile" <<'MK'
deps:
	docker compose run --rm node make _deps
MK

  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "USE_DOCKER" ]
}

@test "a Makefile with a candidate target and no docker anywhere is host" {
  cat > "$WORK/Makefile" <<'MK'
install:
	npm ci
MK

  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "USE_HOST" ]
}

@test "no Makefile at all is host" {
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "USE_HOST" ]
}

@test "a cached host verdict in dev-commands.json wins even when the Makefile would say docker" {
  mkdir -p "$WORK/.coding-crew"
  printf '{"install_mode": "host"}\n' > "$WORK/.coding-crew/dev-commands.json"
  cat > "$WORK/Makefile" <<'MK'
deps:
	docker compose run --rm node make _deps
MK

  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = "USE_HOST" ]
}
