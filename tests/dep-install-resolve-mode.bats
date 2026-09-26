#!/usr/bin/env bats

# resolve-mode.sh — the one install-mode verdict solve-issue's Step 2 and run.sh both read,
# and the ACTION a worker takes on it. Pins the precedence rungs and every ACTION case.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/resolve-mode.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK"
  git -C "$WORK" init -q
  unset MAIN_ROOT
}

teardown() {
  rm -rf "$TEMP_DIR"
}

_cache() {
  mkdir -p "$WORK/.coding-crew"
  printf '%s\n' "$1" > "$WORK/.coding-crew/dev-commands.json"
}

_docker_makefile() {
  printf 'install:\n\tdocker compose run --rm app npm ci\n' > "$WORK/Makefile"
}

@test "no signal at all is host, installing only on failure" {
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"INSTALL_MODE=host"* ]]
  [[ "$output" == *"ACTION=on-failure"* ]]
}

@test "git config agent.install-mode wins over the cache and the override file" {
  git -C "$WORK" config --local agent.install-mode host
  _cache '{"install_mode": "docker"}'
  echo "services: {}" > "$WORK/docker-compose.override.yml"
  run bash "$SCRIPT" --project-root "$WORK"
  [[ "$output" == *"INSTALL_MODE=host"* ]]
}

@test "the cached install_mode wins over the override file" {
  _cache '{"install_mode": "host"}'
  echo "services: {}" > "$WORK/docker-compose.override.yml"
  run bash "$SCRIPT" --project-root "$WORK"
  [[ "$output" == *"INSTALL_MODE=host"* ]]
}

@test "an existing override file at MAIN_ROOT means docker" {
  echo "services: {}" > "$WORK/docker-compose.override.yml"
  run bash "$SCRIPT" --project-root "$WORK"
  [[ "$output" == *"INSTALL_MODE=docker"* ]]
  [[ "$output" == *"ACTION=install"* ]]
}

@test "the Makefile heuristic is the last rung, and --no-heuristic skips it" {
  _docker_makefile
  run bash "$SCRIPT" --project-root "$WORK"
  [[ "$output" == *"INSTALL_MODE=docker"* ]]
  run bash "$SCRIPT" --project-root "$WORK" --no-heuristic
  [[ "$output" == *"INSTALL_MODE=host"* ]]
}

@test "the recorded service: git config first, then the cache" {
  _cache '{"install_mode": "docker", "docker_service": "node"}'
  run bash "$SCRIPT" --project-root "$WORK"
  [[ "$output" == *"DOCKER_SERVICE=node"* ]]
  git -C "$WORK" config --local agent.install-service worker
  run bash "$SCRIPT" --project-root "$WORK"
  [[ "$output" == *"DOCKER_SERVICE=worker"* ]]
}

@test "ACTION=none for every outcome that means the deps are already in place" {
  _cache '{"install_mode": "docker"}'
  for d in present "installed npm ci" docker-present "docker-installed npm ci" "DEPS: docker-present"; do
    run bash "$SCRIPT" --project-root "$WORK" --deps "$d"
    [[ "$output" == *"ACTION=none"* ]] || { echo "--deps '$d' → $output" >&2; return 1; }
  done
}

@test "an outcome that installed nothing leaves docker at ACTION=install" {
  _cache '{"install_mode": "docker"}'
  for d in docker none skipped "failed npm ci (exit 1)" "docker-failed npm ci (exit 1)"; do
    run bash "$SCRIPT" --project-root "$WORK" --deps "$d"
    [[ "$output" == *"ACTION=install"* ]] || { echo "--deps '$d' → $output" >&2; return 1; }
  done
}

@test "--main-root is where the cache and override are read from" {
  MAIN="$TEMP_DIR/main"
  mkdir -p "$MAIN/.coding-crew"
  echo '{"install_mode": "docker"}' > "$MAIN/.coding-crew/dev-commands.json"
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [[ "$output" == *"INSTALL_MODE=docker"* ]]
}
