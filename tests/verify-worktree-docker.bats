#!/usr/bin/env bats

# verify-worktree.sh — docker-mode verification.
#
# gen-override.sh mounts a *named volume* over the ecosystem's dependency directory at a
# container-side subpath, not a host bind-mount: content written there never exists on the
# host filesystem, in the worktree or in MAIN_ROOT. Every check therefore has to run inside
# `docker compose run`, with the worktree's crew override loaded — which the `docker` shim run.sh
# puts on PATH adds to the call. This gate cannot read a skill, so it asks run.sh where each
# command goes instead of running it directly on the host.
#
# `docker` is stubbed on PATH throughout (behind the shim): these tests pin the command
# construction (the service, the override as the last -f), the fallback-to-host safety net, and
# the docker-in-docker guard (a Makefile recipe that already manages docker itself runs on the
# host, not nested) — not real docker behaviour.

load helpers/fake-docker

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
  # The stub's own files are not the project's: verify-worktree.sh fails a check that leaves
  # the tree modified, and the stub writes $DOCKER_LOG during every check.
  printf '.stub/\n.docker.args\n' >> "$TEMP_DIR/.git/info/exclude"

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

  # Windows only: the docker-in-docker guard's host-fallback path runs the discovered
  # command through the system's GNU Make, whose native Windows port shells recipe lines
  # through cmd.exe — which only resolves PATH entries matching %PATHEXT% (.exe/.cmd/...),
  # so the extensionless bash stub above is invisible to it and a nested-recipe test would
  # silently fall through to a real docker.exe instead. A .cmd sibling with the same
  # behaviour closes that gap; unused (and harmless) on every other platform.
  if command -v cygpath >/dev/null 2>&1; then
    local win_log
    win_log="$(cygpath -w "$DOCKER_LOG")"
    cat > "$STUB/docker.cmd" <<EOF
@echo off
(for %%a in (%*) do @echo %%~a) > "$win_log"
exit /b $rc
EOF
  fi
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
  echo "services: {}" > "$TEMP_DIR/.git/crew-compose.override.yml"
}

# ─── routing through docker ───────────────────────────────────────────────────

@test "docker mode: routes TEST through docker compose, the shim adding the override last, with the detected service" {
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
  # Discovery returns a bare command ("make test", no embedded -C path — see step 1 of
  # verify-worktree.sh's comments); the docker branch's only job is the container-src cd.
  # The log shows the command that actually runs inside the container.
  [[ "$output" == *'TEST: running (docker: app): cd "/opt/app" && make test'* ]]
  [[ "$output" != *"TEST: running (docker: app): make -C"* ]]
  [[ "$output" == *"TEST: pass"* ]]

  [ -f "$DOCKER_LOG" ]
  mapfile -t args < "$DOCKER_LOG"
  [ "${args[0]}" = "compose" ]
  [ "${args[1]}" = "-f" ]
  [ "${args[2]}" = "$REAL_DIR/docker-compose.yml" ]
  [ "${args[3]}" = "-f" ]
  [ "${args[4]}" = "$REAL_DIR/.git/crew-compose.override.yml" ]
  [ "${args[5]}" = "run" ]
  [ "${args[6]}" = "--rm" ]
  [ "${args[7]}" = "app" ]
  [ "${args[8]}" = "sh" ]
  [ "${args[9]}" = "-c" ]
  # bare command — no host worktree path anywhere to have leaked into the container
  [[ "${args[10]}" != *"$REAL_DIR"* ]]
  [[ "${args[10]}" == *'cd "/opt/app"'* ]]
  [[ "${args[10]}" == *'make test'* ]]
}

@test "docker mode: a Makefile target whose recipe already invokes docker runs on the host, not nested" {
  # SHELL=sh below (a bare name, PATH-searched by GNU Make itself) was meant to make this
  # recipe's real execution (the host-fallback path, unlike detect-docker-nesting.sh's own
  # `make -n` scan above it) find our stub `docker` regardless of platform. On the Windows
  # CI runner it still resolves the real docker.exe instead — CI logs show an actual `docker
  # compose` network created and a real build-context failure, so make's Windows port is
  # routing the recipe's PATH lookup somewhere this test's own PATH prepend doesn't reach.
  # Needs an actual Windows box to iterate on; the guard logic itself (does the discovered
  # command already invoke docker) is still exercised on Linux/macOS.
  command -v cygpath >/dev/null 2>&1 && skip "docker-in-docker guard: real docker.exe runs instead of the stub on Windows — see comment above"
  _docker_ready
  cat > "$TEMP_DIR/Makefile" <<'EOF'
SHELL = sh
test:
	docker compose run --rm app pytest
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST: running on host"* ]]
  [[ "$output" == *"recipe already manages docker itself"* ]]
  [[ "$output" == *"TEST: pass"* ]]
  # the stub *did* run — make's own recipe called it — with the recipe's own args, never wrapped
  # in an outer `run --rm app sh -c "..."`; the shim made its compose file explicit and added
  # the override last, so the recipe's call mounts the dependency volumes too.
  [ -f "$DOCKER_LOG" ]
  mapfile -t args < "$DOCKER_LOG"
  [ "${args[0]}" = "compose" ]
  [ "${args[3]}" = "-f" ]
  [ "${args[4]}" = "$(cd "$TEMP_DIR" && pwd -P)/.git/crew-compose.override.yml" ]
  [ "${args[5]}" = "run" ]
  [ "${args[6]}" = "--rm" ]
  [ "${args[7]}" = "app" ]
  [ "${args[8]}" = "pytest" ]
}

@test "docker mode: a Makefile target whose recipe invokes docker through a variable also runs on the host" {
  # See the sibling test above — same real-execution path, same unresolved Windows skip.
  command -v cygpath >/dev/null 2>&1 && skip "docker-in-docker guard: real docker.exe runs instead of the stub on Windows — see comment on the sibling test above"
  _docker_ready
  cat > "$TEMP_DIR/Makefile" <<'EOF'
SHELL = sh
RUN_IN_DOCKER = docker compose run --rm app
test:
	$(RUN_IN_DOCKER) pytest
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST: running on host"* ]]
  [[ "$output" == *"recipe already manages docker itself"* ]]
  [ -f "$DOCKER_LOG" ]
  mapfile -t args < "$DOCKER_LOG"
  [ "${args[0]}" = "compose" ]
  [ "${args[5]}" = "run" ]
  [ "${args[7]}" = "app" ]
  [ "${args[8]}" = "pytest" ]
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
  echo "services: {}" > "$TEMP_DIR/.git/crew-compose.override.yml"
  cat > "$TEMP_DIR/Makefile" <<EOF
test:
	@true
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  mapfile -t args < "$DOCKER_LOG"
  [ "${args[7]}" = "worker" ]
}

@test "docker mode: cached docker_service wins over the first detected service when no git config is set" {
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
  echo "services: {}" > "$TEMP_DIR/.git/crew-compose.override.yml"
  mkdir -p "$TEMP_DIR/.coding-crew"
  printf '{"docker_service": "worker"}\n' > "$TEMP_DIR/.coding-crew/dev-commands.json"
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
  [[ "$output" == *"TEST: running: make test"* ]]
  [ ! -f "$DOCKER_LOG" ]
}

@test "falls back to host when the crew compose override cannot be written (no supported ecosystem)" {
  cat > "$TEMP_DIR/docker-compose.yml" <<'YML'
services:
  app:
    volumes: [".:/opt/app"]
YML
  git -C "$TEMP_DIR" config --local agent.install-mode docker
  # no manifest: gen-override.sh cannot write crew-compose.override.yml, so there is nothing to run in docker
  cat > "$TEMP_DIR/Makefile" <<EOF
test:
	@true
EOF

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST: running: make test"* ]]
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
  [[ "$output" == *"TEST: running: make test"* ]]
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
  [[ "$output" == *"TEST: running: make test"* ]]
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

# ─── install-if-missing before the first check ──────────────────────────────
#
# The dependency volumes are named by the worktree's lockfile hash, so the checks must run against
# volumes that were installed for the lockfiles the branch has now. `docker` here is the fake that
# plays named volumes with temp dirs, running the container's script for real (helpers/fake-docker).

# _fake_docker_ready — a docker-mode worktree with its real override, the volume-playing fake, and
# a cached `true` as the only check, so what the checks see is the override they are handed
_fake_docker_ready() {
  FAKE="$TEMP_DIR/.fake"
  export FAKE
  printf '.fake/\n.coding-crew/\n' >> "$TEMP_DIR/.git/info/exclude"
  install_fake_docker "$STUB" "$FAKE"
  cat > "$TEMP_DIR/docker-compose.yml" <<'YML'
services:
  app:
    build: .
    volumes:
      - .:/opt/app
YML
  echo '{"name":"fixture"}' > "$TEMP_DIR/package.json"
  echo '{"lock":"A"}' > "$TEMP_DIR/package-lock.json"
  git -C "$TEMP_DIR" config --local agent.install-mode docker
  mkdir -p "$TEMP_DIR/.coding-crew"
  printf '{"test": "true", "lint": null, "typecheck": null}\n' > "$TEMP_DIR/.coding-crew/dev-commands.json"
  bash "$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/gen-override.sh" \
    --project-root "$TEMP_DIR" --main-root "$TEMP_DIR" >/dev/null
}

_volume_names() { grep -o 'name: wt_[A-Za-z0-9_]*' "$TEMP_DIR/.git/crew-compose.override.yml" | sed 's/^name: //' | grep -v '_state_'; }
_installs() { grep -c . "$FAKE/install.calls" || true; }

@test "docker mode: the first check runs only after an install-if-missing, which then costs nothing while the stamp is there" {
  _fake_docker_ready

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  # the deps check is reported before the first check
  [[ "$output" == *"DEPS: pass"*"TEST: pass"* ]]
  [ "$(_installs)" -eq 1 ]

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEPS: pass"* ]]
  [ "$(_installs)" -eq 1 ]
}

@test "docker mode with no override yet: the install still runs before the first check, and the checks run in docker" {
  _fake_docker_ready
  rm -f "$TEMP_DIR/.git/crew-compose.override.yml"

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"via: docker compose run --rm app"* ]]
  [[ "$output" == *"DEPS: pass"*"TEST: running (docker: app)"*"TEST: pass"* ]]
  [ -f "$TEMP_DIR/.git/crew-compose.override.yml" ]
  [ "$(_installs)" -eq 1 ]
  # the install first, then the check, each a `docker compose run` carrying the override
  runs="$(grep -E '^compose .* run ' "$FAKE/docker.calls" | grep -v -e '--user=0')"
  [ "$(grep -c . <<<"$runs")" -ge 2 ]
  [[ "$(head -1 <<<"$runs")" == *"npm ci"* ]]
  [[ "$(tail -1 <<<"$runs")" == *"crew-compose.override.yml run --rm app sh -c cd \"/opt/app\" && true"* ]]
}

@test "docker mode: after the branch's lockfile changes, the checks see the new-hash volume (B5)" {
  _fake_docker_ready
  bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR" >/dev/null
  before="$(_volume_names)"

  echo '{"lock":"B"}' > "$TEMP_DIR/package-lock.json"
  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST: pass"* ]]
  after="$(_volume_names)"
  [ -n "$after" ] && [ "$after" != "$before" ]
  [ "$(_installs)" -eq 2 ]
  # the install went into the new volume, and the override the check ran with names it
  [ -f "$FAKE/vols/$after/.crew-stamp" ]
}

@test "docker mode: an install failure fails the verify as a deps check with the install's tail" {
  _fake_docker_ready
  export FAKE_NPM_RC=1

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"DEPS: fail"* ]]
  [[ "$output" == *"npm ERR! boom"* ]]
  [[ "$output" == *"Verification: fail"* ]]
}

@test "docker mode: CREW_DEPS=off skips the install-if-missing" {
  _fake_docker_ready
  export CREW_DEPS=off

  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"DEPS:"* ]]
  [ "$(_installs)" -eq 0 ]
}

@test "host mode: no install-if-missing, no deps check" {
  cat > "$TEMP_DIR/Makefile" <<MAKE
test:
	@true
MAKE
  run bash "$VERIFY_SCRIPT" --dir "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"DEPS:"* ]]
}
