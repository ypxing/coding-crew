#!/usr/bin/env bats

# verify-worktree.sh — docker-mode verification.
#
# dep-install's docker-install.md tells a worker "every subsequent docker compose command
# must pass both -f flags — including test, lint and type-check runs", because
# gen-override.sh mounts a *named volume* over the ecosystem's dependency directory at a
# container-side subpath, not a host bind-mount: content written there never exists on the
# host filesystem, in the worktree or in MAIN_ROOT. A worker gets that instruction from the
# skill; this gate cannot read a skill, so before this it ran every discovered command
# directly on the host — looking at a worktree whose node_modules never existed outside
# the container, and failing every check that needed it.
#
# `docker` is stubbed on PATH throughout: these tests pin the command construction (both
# -f flags, the service, the path substitution) and the fallback-to-host safety net, not
# real docker behaviour.

VERIFY_SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/verify-worktree.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR

  git -C "$TEMP_DIR" init -q
  git -C "$TEMP_DIR" config user.email t@test
  git -C "$TEMP_DIR" config user.name T
  git -C "$TEMP_DIR" commit -q --allow-empty -m init

  STUB="$TEMP_DIR/.stub"
  mkdir -p "$STUB"
  export PATH="$STUB:$PATH"

  DOCKER_LOG="$TEMP_DIR/.docker.args"
  export DOCKER_LOG

  unset MAIN_ROOT CREW_VERIFY_DOCKER CREW_DEP_INSTALL_SCRIPTS

  # A working docker stub by default — tests that want a failure override it explicitly.
  stub_docker 0
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# stub_docker <exit> — a fake `docker` on PATH that records every argument it received
# (one per line, so an embedded `sh -c "..."` string stays intact on its own line) and
# exits with the given code. Never touches a real daemon.
stub_docker() {
  local rc="$1"
  cat > "$STUB/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$DOCKER_LOG"
exit $rc
EOF
  chmod +x "$STUB/docker"
}

# _docker_ready — a worktree wired for docker-mode verification: a compose file with one
# service bind-mounting the tree at /opt/app, a node manifest so gen-override.sh detects
# an ecosystem and a service, agent.install-mode persisted (as ensure-deps.sh's docker
# path does), and the override file ensure-deps.sh's one MAIN_ROOT call would have written.
# This repo is used as both the worktree and MAIN_ROOT, matching how _main_root_of resolves
# a non-linked-worktree checkout.
_docker_ready() {
  cat > "$TEMP_DIR/docker-compose.yml" <<'YML'
services:
  app:
    build: .
    volumes:
      - .:/opt/app
YML
  cat > "$TEMP_DIR/package.json" <<'JSON'
{"name":"fixture"}
JSON
  echo '{}' > "$TEMP_DIR/package-lock.json"
  git -C "$TEMP_DIR" config --local agent.install-mode docker
  echo "services: {}" > "$TEMP_DIR/docker-compose.override.yml"
}

# ─── routing through docker ───────────────────────────────────────────────────

@test "docker mode: routes TEST through docker compose with both -f flags and the detected service" {
  _docker_ready
  cat > "$TEMP_DIR/Makefile" <<EOF
test:
	@true
EOF

  # Physical path: the script resolves --dir with `pwd -P`, so on a host where $TEMP_DIR
  # itself is a symlink (macOS's /var -> /private/var) the printed/compose paths differ
  # from the raw value textually while naming the same directory.
  REAL_DIR="$(cd "$TEMP_DIR" && pwd -P)"

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  # The log now shows the command that actually runs inside the container (container-src
  # cwd, host path substituted for ".") — not the host-path command it was derived from,
  # which previously read as if the host path had leaked into the container.
  [[ "$output" == *'TEST: running (docker: app): cd "/opt/app" && make -C "." test'* ]]
  [[ "$output" != *"TEST: running (docker: app): make -C \"$REAL_DIR\""* ]]
  [[ "$output" == *"TEST: pass"* ]]

  [ -f "$DOCKER_LOG" ]
  mapfile -t args < "$DOCKER_LOG"
  [ "${args[0]}" = "compose" ]
  [ "${args[1]}" = "-f" ]
  [ "${args[2]}" = "$REAL_DIR/docker-compose.yml" ]
  [ "${args[3]}" = "-f" ]
  [ "${args[4]}" = "$REAL_DIR/docker-compose.override.yml" ]
  [ "${args[5]}" = "run" ]
  [ "${args[6]}" = "--rm" ]
  [ "${args[7]}" = "app" ]
  [ "${args[8]}" = "sh" ]
  [ "${args[9]}" = "-c" ]
  # the host worktree path was substituted for "." — it does not exist in the container
  [[ "${args[10]}" != *"$REAL_DIR"* ]]
  [[ "${args[10]}" == *'cd "/opt/app"'* ]]
  [[ "${args[10]}" == *'make -C "." test'* ]]
}

@test "docker mode: a failing check inside the container is TEST: fail, exit non-zero, no receipt" {
  _docker_ready
  cat > "$TEMP_DIR/Makefile" <<EOF
test:
	@true
EOF
  stub_docker 1

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"TEST: fail"* ]]
  [[ "$output" == *"Verification: fail"* ]]
}

@test "docker mode: git config agent.install-service wins over the first detected service" {
  cat > "$TEMP_DIR/docker-compose.yml" <<'YML'
services:
  app:
    volumes: [".:/opt/app"]
  worker:
    volumes: [".:/opt/app"]
YML
  cat > "$TEMP_DIR/package.json" <<'JSON'
{"name":"fixture"}
JSON
  echo '{}' > "$TEMP_DIR/package-lock.json"
  git -C "$TEMP_DIR" config --local agent.install-mode docker
  git -C "$TEMP_DIR" config --local agent.install-service worker
  echo "services: {}" > "$TEMP_DIR/docker-compose.override.yml"
  cat > "$TEMP_DIR/Makefile" <<EOF
test:
	@true
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  mapfile -t args < "$DOCKER_LOG"
  [ "${args[7]}" = "worker" ]
}

# ─── fallback to host: every gap in the docker signal must be silent ────────

@test "host mode by default: docker is never invoked when agent.install-mode is unset" {
  cat > "$TEMP_DIR/Makefile" <<EOF
test:
	@true
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST: running: make -C"* ]]
  [ ! -f "$DOCKER_LOG" ]
}

@test "falls back to host when docker-compose.override.yml has not been written yet" {
  cat > "$TEMP_DIR/docker-compose.yml" <<'YML'
services:
  app:
    volumes: [".:/opt/app"]
YML
  cat > "$TEMP_DIR/package.json" <<'JSON'
{"name":"fixture"}
JSON
  echo '{}' > "$TEMP_DIR/package-lock.json"
  git -C "$TEMP_DIR" config --local agent.install-mode docker
  # no docker-compose.override.yml written — ensure-deps.sh's MAIN_ROOT call has not run yet
  cat > "$TEMP_DIR/Makefile" <<EOF
test:
	@true
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST: running: make -C"* ]]
  [ ! -f "$DOCKER_LOG" ]
}

@test "falls back to host when the worktree has no compose file" {
  _docker_ready
  rm -f "$TEMP_DIR/docker-compose.yml"
  cat > "$TEMP_DIR/Makefile" <<EOF
test:
	@true
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST: running: make -C"* ]]
  [ ! -f "$DOCKER_LOG" ]
}

@test "CREW_VERIFY_DOCKER=off forces host execution even when every docker signal is present" {
  _docker_ready
  cat > "$TEMP_DIR/Makefile" <<EOF
test:
	@true
EOF
  export CREW_VERIFY_DOCKER=off

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST: running: make -C"* ]]
  [ ! -f "$DOCKER_LOG" ]
}

@test "docker mode: MAIN_ROOT env, when set, is used ahead of git-common-dir resolution" {
  _docker_ready
  cat > "$TEMP_DIR/Makefile" <<EOF
test:
	@true
EOF

  MAIN_ROOT="$TEMP_DIR" run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [ -f "$DOCKER_LOG" ]
}
