#!/usr/bin/env bats

# run.sh — the one construction of "run this check where this project's checks run". The
# gate's side of it is pinned in verify-worktree-docker.bats; this pins the script on its
# own, as a worker calls it. `docker` is stubbed on PATH and never reaches a daemon.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/run.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK"
  git -C "$WORK" init -q
  WORK="$(cd "$WORK" && pwd -P)"
  STUB="$TEMP_DIR/.stub"
  mkdir -p "$STUB"
  DOCKER_LOG="$TEMP_DIR/docker.args"
  cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$DOCKER_LOG"
EOF
  chmod +x "$STUB/docker"
  export PATH="$STUB:$PATH"
  unset MAIN_ROOT
}

teardown() {
  rm -rf "$TEMP_DIR"
}

_docker_ready() {
  printf 'services:\n  app:\n    build: .\n    volumes:\n      - .:/opt/app\n' > "$WORK/docker-compose.yml"
  echo '{"name":"fixture"}' > "$WORK/package.json"
  echo '{}' > "$WORK/package-lock.json"
  git -C "$WORK" config --local agent.install-mode docker
  echo "services: {}" > "$WORK/docker-compose.override.yml"
}

@test "host mode runs the command in PROJECT_ROOT and returns its exit code" {
  run bash "$SCRIPT" --project-root "$WORK" -- 'pwd -P; exit 3'
  [ "$status" -eq 3 ]
  [ "$output" = "$WORK" ]
  [ ! -f "$DOCKER_LOG" ]
}

@test "docker mode wraps the command in docker compose run with both -f flags" {
  _docker_ready
  run bash "$SCRIPT" --project-root "$WORK" -- npm test
  [ "$status" -eq 0 ]
  mapfile -t args < "$DOCKER_LOG"
  [ "${args[0]}" = compose ]
  [ "${args[2]}" = "$WORK/docker-compose.yml" ]
  [ "${args[4]}" = "$WORK/docker-compose.override.yml" ]
  [ "${args[5]}" = run ]
  [ "${args[7]}" = app ]
  [ "${args[10]}" = 'cd "/opt/app" && npm test' ]
}

@test "a command that runs docker itself goes to the host, not nested" {
  _docker_ready
  run bash "$SCRIPT" --project-root "$WORK" --describe -- 'docker compose run --rm app npm test'
  [[ "$output" == *"VIA=nested"* ]]
}

@test "docker mode with no override yet falls back to host, with a warning" {
  _docker_ready
  rm "$WORK/docker-compose.override.yml"
  run bash "$SCRIPT" --project-root "$WORK" -- 'echo ran-on-host'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran-on-host"* ]]
  [[ "$output" == *"run.sh: docker mode, but no "*"docker-compose.override.yml yet"* ]]
  [ ! -f "$DOCKER_LOG" ]
}

@test "--describe reports the docker verdict without running anything" {
  _docker_ready
  run bash "$SCRIPT" --project-root "$WORK" --describe -- 'touch ran'
  [ "$status" -eq 0 ]
  [[ "$output" == *"RUN=docker"* ]]
  [[ "$output" == *"SERVICE=app"* ]]
  [[ "$output" == *"CONTAINER_SRC=/opt/app"* ]]
  [[ "$output" == *"VIA=docker"* ]]
  [ ! -f "$WORK/ran" ] && [ ! -f "$DOCKER_LOG" ]
}

@test "--via host runs on the host even when every docker signal is present" {
  _docker_ready
  run bash "$SCRIPT" --project-root "$WORK" --via host -- 'echo host'
  [ "$output" = host ]
  [ ! -f "$DOCKER_LOG" ]
}

@test "no command is a usage error" {
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 2 ]
}
