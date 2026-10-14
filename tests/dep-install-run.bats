#!/usr/bin/env bats

# run.sh and run-checks.sh — "run this where this checkout's checks run". The mode is the checkout's
# committed .coding-crew/dev-commands.json; docker mode runs in the checkout's own compose project,
# installs first when it has no override yet, and never falls back to the host. `docker` is stubbed
# on PATH and never reaches a daemon; run.sh puts the crew shim in front of the stub, so the stub
# logs what the shim finally passed on.

LIB="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"
SCRIPT="$LIB/run.sh"
RUN_CHECKS="$LIB/run-checks.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.email t@test
  git -C "$WORK" config user.name T
  WORK="$(cd "$WORK" && pwd -P)"
  STUB="$TEMP_DIR/.stub"
  mkdir -p "$STUB"
  DOCKER_LOG="$TEMP_DIR/docker.args"
  CALLS="$TEMP_DIR/docker.calls"
  # Each call: its argv one per line in DOCKER_LOG (the last call), and one joined line in CALLS.
  # The install's container script (it writes .crew-stamp) exits FAKE_INSTALL_RC; nothing else runs.
  cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$DOCKER_LOG"
all="\$*"
printf '%s\n' "\${all//\$'\n'/ }" >> "$CALLS"
case "\$all" in *crew-stamp*) echo "npm ERR! boom"; exit "\${FAKE_INSTALL_RC:-0}" ;; esac
exit 0
EOF
  chmod +x "$STUB/docker"
  export PATH="$STUB:$PATH"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

_override() { printf '%s/crew-compose.override.yml' "$(git -C "$1" rev-parse --path-format=absolute --git-dir)"; }

# A docker-mode project: compose file, a node manifest, and dev-commands.json naming docker and app.
_docker_project() {
  local dir="$1" checks="${2:-}"
  printf 'services:\n  app:\n    build: .\n    volumes:\n      - .:/opt/app\n  db:\n    image: postgres\n' > "$dir/docker-compose.yml"
  echo '{"name":"fixture"}' > "$dir/package.json"
  echo '{}' > "$dir/package-lock.json"
  mkdir -p "$dir/.coding-crew"
  printf '{"install_mode": "docker", "docker_service": "app"%s}\n' "$checks" > "$dir/.coding-crew/dev-commands.json"
}

_docker_ready() {
  _docker_project "$WORK"
  OVERRIDE="$(_override "$WORK")"
  echo "services: {}" > "$OVERRIDE"
}

# ─── run.sh ─────────────────────────────────────────────────────────────────

@test "host mode runs the command in PROJECT_ROOT and returns its exit code" {
  run bash "$SCRIPT" --project-root "$WORK" -- 'pwd -P; exit 3'
  [ "$status" -eq 3 ]
  [ "$output" = "$WORK" ]
  [ ! -f "$CALLS" ]
}

@test "a dev-commands.json with no install_mode is host, whatever the Makefile or git config say" {
  printf 'install:\n\tdocker compose run app npm ci\n' > "$WORK/Makefile"
  git -C "$WORK" config --local agent.install-mode docker
  mkdir -p "$WORK/.coding-crew"
  echo '{"test": "echo T"}' > "$WORK/.coding-crew/dev-commands.json"
  run bash "$SCRIPT" --project-root "$WORK" -- 'echo ran-on-host'
  [ "$status" -eq 0 ]
  [ "$output" = ran-on-host ]
  [ ! -f "$CALLS" ]
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
  cp -R "$LIB" "$TEMP_DIR/scripts"
  printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$STUB/docker" > "$TEMP_DIR/scripts/shim/docker"
  run bash "$TEMP_DIR/scripts/run.sh" --project-root "$WORK" -- npm test
  [ "$status" -eq 0 ]
  mapfile -t args < "$DOCKER_LOG"
  [ "${args[*]:0:4}" = "compose run --rm app" ]
  [ "${#args[@]}" -eq 7 ]
}

@test "a command that runs docker itself goes to the host in docker mode, its compose calls given the override" {
  _docker_ready
  printf 'test:\n\tdocker compose -f a.yml run app npm test\n' > "$WORK/Makefile"
  touch "$WORK/a.yml"
  run bash "$SCRIPT" --project-root "$WORK" -- make test
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$CALLS")" -eq 1 ]
  mapfile -t args < "$DOCKER_LOG"
  # the recipe's own `-f a.yml` call got the override inserted before its subcommand
  [ "${args[*]}" = "compose -f a.yml -f $OVERRIDE run app npm test" ]

  run bash "$SCRIPT" --project-root "$WORK" -- 'docker compose version >/dev/null; echo "${PATH%%:*}|$CREW_COMPOSE_OVERRIDE"'
  [ "$output" = "$LIB/shim|$OVERRIDE" ]
}

@test "docker mode with no override generates it and installs before the command runs" {
  _docker_project "$WORK"
  OVERRIDE="$(_override "$WORK")"
  run bash "$SCRIPT" --project-root "$WORK" -- npm test
  [ "$status" -eq 0 ]
  [ -f "$OVERRIDE" ]
  [ "$(wc -l < "$CALLS")" -eq 2 ]
  [[ "$(sed -n 1p "$CALLS")" == *"-f $OVERRIDE run --rm app sh -c"*crew-stamp* ]]
  [[ "$(sed -n 2p "$CALLS")" == *"-f $OVERRIDE run --rm app sh -c cd \"/opt/app\" && npm test" ]]
}

@test "a failed docker install stops with the service, the step and its log; the command never runs" {
  _docker_project "$WORK"
  OVERRIDE="$(_override "$WORK")"
  FAKE_INSTALL_RC=1 run bash "$SCRIPT" --project-root "$WORK" -- "touch $TEMP_DIR/ran-on-host"
  [ "$status" -eq 1 ]
  log="$(git -C "$WORK" rev-parse --path-format=absolute --git-dir)/crew-docker-install.log"
  [[ "$output" == *"the dependency install failed — service app, step install, exit 3; log: $log"* ]]
  [[ "$output" == *"did not run. Nothing runs on the host in docker mode."* ]]
  [ -f "$log" ]
  [ ! -e "$TEMP_DIR/ran-on-host" ]
  [ "$(wc -l < "$CALLS")" -eq 1 ]
  # no override is left behind, so the next call installs again rather than run on empty volumes
  [ ! -f "$OVERRIDE" ]
}

@test "docker mode with no compose file stops instead of running on the host" {
  _docker_ready
  rm "$WORK/docker-compose.yml"
  run bash "$SCRIPT" --project-root "$WORK" -- "touch $TEMP_DIR/ran-on-host"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no compose file in $WORK"* ]]
  [ ! -e "$TEMP_DIR/ran-on-host" ]
}

@test "two worktrees of one repo get their own compose project and volumes" {
  _docker_project "$WORK"
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m init
  git -C "$WORK" worktree add -q "$TEMP_DIR/wt-a" -b a
  git -C "$WORK" worktree add -q "$TEMP_DIR/wt-b" -b b
  local wt name vols names=() volsets=()
  for wt in "$TEMP_DIR/wt-a" "$TEMP_DIR/wt-b"; do
    : > "$CALLS"
    run bash "$SCRIPT" --project-root "$wt" -- npm test
    [ "$status" -eq 0 ]
    # the stub saw this worktree's own override on every call
    [ "$(grep -c -- "-f $(_override "$wt") run" "$CALLS")" -eq 2 ]
    names+=("$(sed -n 's/^name: //p' "$(_override "$wt")")")
    volsets+=("$(grep -oE '^  wt_[A-Za-z0-9_]+' "$(_override "$wt")" | sort | tr -d ' ' | tr '\n' ' ')")
  done
  [ -n "${names[0]}" ] && [ -n "${volsets[0]}" ]
  [ "${names[0]}" != "${names[1]}" ]
  for vol in ${volsets[0]}; do [[ " ${volsets[1]} " != *" $vol "* ]]; done
}

@test "--describe, --via and --main-root are unknown flags" {
  _docker_ready
  for flag in --describe "--via host" "--main-root $WORK"; do
    run bash "$SCRIPT" --project-root "$WORK" $flag -- true
    [ "$status" -eq 2 ]
  done
}

@test "no command is a usage error" {
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 2 ]
}

# ─── run-checks.sh in docker mode ───────────────────────────────────────────

@test "run-checks: docker mode with no override installs first, then runs each check in the service" {
  _docker_project "$WORK" ', "typecheck": "echo Y", "lint": null, "test": "echo T"'
  OVERRIDE="$(_override "$WORK")"
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"typecheck: pass"*"lint: NOT RUN: no command found"*"test: pass"*"CHECKS: pass" ]]
  [ -f "$OVERRIDE" ]
  # the install is the first container run; each check runs in app afterwards
  [[ "$(sed -n 1p "$CALLS")" == *"-f $OVERRIDE run --rm app sh -c"*crew-stamp* ]]
  [ "$(grep -c crew-stamp "$CALLS")" -eq 1 ]
  [[ "$(tail -n 2 "$CALLS" | head -1)" == *"run --rm app sh -c cd \"/opt/app\" && echo Y" ]]
  [[ "$(tail -n 1 "$CALLS")" == *"run --rm app sh -c cd \"/opt/app\" && echo T" ]]
}

@test "run-checks: a failed docker install fails the run once, naming the service, step and log, and runs no check" {
  _docker_project "$WORK" ", \"typecheck\": \"touch $TEMP_DIR/ran-typecheck\", \"test\": \"touch $TEMP_DIR/ran-test\""
  FAKE_INSTALL_RC=1 run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ]
  log="$(git -C "$WORK" rev-parse --path-format=absolute --git-dir)/crew-docker-install.log"
  [[ "$output" == *"service app, step install, exit 3; log: $log"* ]]
  [[ "$output" == *"CHECKS: fail" ]]
  [[ "$output" != *"typecheck: "* ]]
  [ ! -e "$TEMP_DIR/ran-typecheck" ] && [ ! -e "$TEMP_DIR/ran-test" ]
  # one install attempt, and no check command reached docker either
  [ "$(wc -l < "$CALLS")" -eq 1 ]
  ! grep -q 'ran-' "$CALLS"
}

@test "run-checks: this repo's own dev-commands.json (no install_mode) runs every check on the host" {
  local repo; repo="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  ! grep -q install_mode "$repo/.coding-crew/dev-commands.json"
  mkdir -p "$WORK/.coding-crew"
  cp "$repo/.coding-crew/dev-commands.json" "$WORK/.coding-crew/"
  # every check of that file swapped for one that records where it ran, keeping its keys
  sed -E 's/"([a-z_]+)": "[^"]*"/"\1": "pwd -P >> where"/g' "$repo/.coding-crew/dev-commands.json" \
    > "$WORK/.coding-crew/dev-commands.json"
  printf 'where\n.coding-crew/\n' > "$WORK/.gitignore"
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CHECKS: pass" ]]
  [ -s "$WORK/where" ]
  [ -z "$(grep -vx "$WORK" "$WORK/where")" ]
  [ ! -f "$CALLS" ]
}

@test "run-checks: a check command that runs docker itself runs on the host in docker mode" {
  _docker_ready
  printf '{"install_mode": "docker", "docker_service": "app", "typecheck": null, "lint": null, "test": "docker compose version >/dev/null && pwd -P > where"}\n' \
    > "$WORK/.coding-crew/dev-commands.json"
  printf 'where\n.coding-crew/\n' > "$WORK/.gitignore"
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/where")" = "$WORK" ]
  [ "$(wc -l < "$CALLS")" -eq 1 ]
  [[ "$(cat "$CALLS")" == "compose "*"-f $OVERRIDE version" ]]
}

@test "run-checks: --main-root and --dep-scripts are unknown arguments" {
  run bash "$RUN_CHECKS" --project-root "$WORK" --main-root "$WORK"
  [ "$status" -eq 2 ]
  run bash "$RUN_CHECKS" --project-root "$WORK" --dep-scripts "$LIB"
  [ "$status" -eq 2 ]
}
