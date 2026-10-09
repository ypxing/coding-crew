#!/usr/bin/env bats

# run.sh — the one construction of "run this check where this project's checks run". The
# gate's side of it is pinned in verify-worktree-docker.bats; this pins the script on its
# own, as a worker calls it. `docker` is stubbed on PATH and never reaches a daemon; run.sh puts
# the crew shim in front of the stub, so the stub logs what the shim finally passed on.

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
  OVERRIDE="$(git -C "$WORK" rev-parse --path-format=absolute --git-dir)/crew-compose.override.yml"
  echo "services: {}" > "$OVERRIDE"
}

@test "host mode runs the command in PROJECT_ROOT and returns its exit code" {
  run bash "$SCRIPT" --project-root "$WORK" -- 'pwd -P; exit 3'
  [ "$status" -eq 3 ]
  [ "$output" = "$WORK" ]
  [ ! -f "$DOCKER_LOG" ]
}

@test "docker mode runs docker compose run --rm <service> sh -c through the shim, which adds the override" {
  _docker_ready
  run bash "$SCRIPT" --project-root "$WORK" -- npm test
  [ "$status" -eq 0 ]
  mapfile -t args < "$DOCKER_LOG"
  # run.sh builds no -f; the shim made the compose file explicit and added crew's override last
  [ "${args[0]}" = compose ]
  [ "${args[1]}" = -f ]
  [ "${args[2]}" = "$WORK/docker-compose.yml" ]
  [ "${args[3]}" = -f ]
  [ "${args[4]}" = "$OVERRIDE" ]
  [ "${args[5]}" = run ]
  [ "${args[6]}" = --rm ]
  [ "${args[7]}" = app ]
  [ "${args[8]}" = sh ]
  [ "${args[10]}" = 'cd "/opt/app" && npm test' ]
  ! printf '%s\n' "${args[@]}" | grep -qx -- '-e'
}

@test "run.sh itself passes no -f or -e to docker: the stub behind a stand-in shim sees a bare compose run" {
  _docker_ready
  # a copy of the scripts whose shim is a pass-through, to see exactly what run.sh asked for
  cp -R "$(dirname "$SCRIPT")" "$TEMP_DIR/scripts"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$STUB/docker" > "$TEMP_DIR/scripts/shim/docker"
  run bash "$TEMP_DIR/scripts/run.sh" --project-root "$WORK" -- npm test
  [ "$status" -eq 0 ]
  mapfile -t args < "$DOCKER_LOG"
  [ "${args[*]:0:4}" = "compose run --rm app" ]
  [ "${#args[@]}" -eq 7 ]
}

@test "a command that runs docker itself goes to the host, with the shim first on PATH and the override set" {
  _docker_ready
  run bash "$SCRIPT" --project-root "$WORK" --describe -- 'docker compose run --rm app npm test'
  [[ "$output" == *"VIA=host"* ]]
  [[ "$output" != *"nested"* ]]

  printf 'test:\n\tdocker compose -f a.yml run app npm test\n' > "$WORK/Makefile"
  touch "$WORK/a.yml"
  run bash "$SCRIPT" --project-root "$WORK" -- make test
  [ "$status" -eq 0 ]
  mapfile -t args < "$DOCKER_LOG"
  # the recipe's own `-f a.yml` call got the override inserted before its subcommand
  [ "${args[*]}" = "compose -f a.yml -f $OVERRIDE run app npm test" ]
}

@test "the host route sees the shim first on PATH and CREW_COMPOSE_OVERRIDE set" {
  _docker_ready
  run bash "$SCRIPT" --project-root "$WORK" --via host -- 'echo "${PATH%%:*}|$CREW_COMPOSE_OVERRIDE"'
  [ "$output" = "$(dirname "$SCRIPT")/shim|$OVERRIDE" ]
}

@test "docker mode with no override yet falls back to host, with a warning" {
  _docker_ready
  rm "$OVERRIDE"
  run bash "$SCRIPT" --project-root "$WORK" -- 'echo ran-on-host'
  [ "$status" -eq 0 ]
  [[ "$output" == *"ran-on-host"* ]]
  [[ "$output" == *"run.sh: docker mode, but no "*"crew-compose.override.yml yet"* ]]
  [ ! -f "$DOCKER_LOG" ]
}

@test "--via accepts docker and host, runs nested as host, and rejects anything else" {
  _docker_ready
  run bash "$SCRIPT" --project-root "$WORK" --via nested -- 'echo on-host'
  [ "$status" -eq 0 ]
  [ "$output" = on-host ]
  [ ! -f "$DOCKER_LOG" ]
  run bash "$SCRIPT" --project-root "$WORK" --via docker -- 'true'
  [ "$status" -eq 0 ]
  [ -f "$DOCKER_LOG" ]
  run bash "$SCRIPT" --project-root "$WORK" --via sideways -- 'true'
  [ "$status" -eq 2 ]
}

@test "--describe reports the docker verdict without running anything" {
  _docker_ready
  run bash "$SCRIPT" --project-root "$WORK" --describe -- 'touch ran'
  [ "$status" -eq 0 ]
  [[ "$output" == *"RUN=docker"* ]]
  [[ "$output" == *"SERVICE=app"* ]]
  [[ "$output" == *"CONTAINER_SRC=/opt/app"* ]]
  [[ "$output" == *"VIA=docker"* ]]
  [[ "$output" == *"OVERRIDE=$OVERRIDE"* ]]
  [[ "$output" != *"OVERRIDE_FILE"* ]]
  [ ! -f "$WORK/ran" ] && [ ! -f "$DOCKER_LOG" ]
}

@test "--via host runs on the host even when every docker signal is present" {
  _docker_ready
  run bash "$SCRIPT" --project-root "$WORK" --via host -- 'echo host'
  [ "$output" = host ]
  [ ! -f "$DOCKER_LOG" ]
}

# A copy of the scripts whose resolve-mode.sh is a stub running the given body (>64KB of output = a full pipe).
_stub_verdict() {
  local scripts="$TEMP_DIR/scripts"
  cp -R "$(dirname "$SCRIPT")" "$scripts"
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$scripts/resolve-mode.sh"
  STUBBED_SCRIPT="$scripts/run.sh"
}

@test "a docker verdict that keeps writing after INSTALL_MODE=docker still runs in docker" {
  _docker_ready
  _stub_verdict 'echo INSTALL_MODE=docker; yes xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx | head -n 200000'
  run bash "$STUBBED_SCRIPT" --project-root "$WORK" -- npm test
  [ "$status" -eq 0 ]
  [[ "$output" != *"Broken pipe"* ]]
  [ -f "$DOCKER_LOG" ]
  mapfile -t args < "$DOCKER_LOG"
  [ "${args[5]}" = run ]
}

@test "a verdict without INSTALL_MODE=docker runs the command on the host" {
  _docker_ready
  _stub_verdict 'echo INSTALL_MODE=host; yes xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx | head -n 200000'
  run bash "$STUBBED_SCRIPT" --project-root "$WORK" -- 'echo ran-on-host'
  [ "$status" -eq 0 ]
  [ "$output" = ran-on-host ]
  [ ! -f "$DOCKER_LOG" ]
}

@test "no command is a usage error" {
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 2 ]
}
