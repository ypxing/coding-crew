#!/usr/bin/env bats

# docker-install.sh — dep-install's docker-mode sibling of host-install.sh. Deterministic
# (ecosystem detection, service selection, the install command), so ensure-deps.sh can call
# it mechanically for the one MAIN_ROOT call a sprint makes before any worktree exists.
#
# What is NOT pinned here: real docker behaviour. `docker` is stubbed on PATH throughout, so
# these tests pin argument construction, exit codes, and the lock — not the daemon.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts"
SCRIPT="$SCRIPTS_DIR/docker-install.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  MAIN=$(mktemp -d)
  WORK=$(mktemp -d)
  export MAIN WORK
  cat > "$WORK/docker-compose.yml" <<'YML'
services:
  app:
    build: .
    volumes:
      - .:/opt/app
YML
  cat > "$WORK/package.json" <<'JSON'
{"name":"fixture"}
JSON
  cat > "$WORK/package-lock.json" <<'JSON'
{}
JSON
  STUB="$TEMP_DIR/stub"
  mkdir -p "$STUB"
  export PATH="$STUB:$PATH"
}

teardown() {
  rm -rf "$TEMP_DIR" "$MAIN" "$WORK"
}

# stub_docker <exit> [stderr-text] — a fake `docker` on PATH so `docker compose run` never
# touches a real daemon.
stub_docker() {
  local rc="$1" err="${2:-}"
  {
    printf '#!/usr/bin/env bash\n'
    [ -n "$err" ] && printf 'echo %q >&2\n' "$err"
    printf 'exit %s\n' "$rc"
  } > "$STUB/docker"
  chmod +x "$STUB/docker"
}

# ─── gen-override.sh --query ─────────────────────────────────────────────────

@test "gen-override.sh --query services prints the compose services, one per line" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --query services
  [ "$status" -eq 0 ]
  [ "$output" = "app" ]
}

@test "gen-override.sh --query ecosystem, container-src and manifest-dirs answer without writing the override" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --query ecosystem
  [ "$output" = "node" ]
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --query container-src
  [ "$output" = "/opt/app" ]
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --query manifest-dirs
  [ "$output" = "$WORK" ]
  [ ! -f "$MAIN/docker-compose.override.yml" ]
}

@test "gen-override.sh --query rejects an unknown field" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --query bogus
  [ "$status" -ne 0 ]
}

# ─── gen-override.sh: worktree symlink ───────────────────────────────────────
#
# Every mechanical caller still passes the override's absolute MAIN_ROOT path via an
# explicit second `-f` (see the docker-install.sh tests below) — these tests pin the added
# safety net: a symlink at PROJECT_ROOT so compose's own same-directory override convention
# also picks it up if something ever invokes `docker compose run` with no `-f` at all.

@test "a worktree PROJECT_ROOT gets a symlink to the MAIN_ROOT override" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -L "$WORK/docker-compose.override.yml" ]
  [ "$(readlink "$WORK/docker-compose.override.yml")" = "$MAIN/docker-compose.override.yml" ]
  diff "$WORK/docker-compose.override.yml" "$MAIN/docker-compose.override.yml"
}

@test "--dry-run prints YAML but writes and links nothing" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$MAIN/docker-compose.override.yml" ]
  [ ! -e "$WORK/docker-compose.override.yml" ]
}

@test "the MAIN_ROOT-only call (PROJECT_ROOT == MAIN_ROOT) does not self-link" {
  cp "$WORK/docker-compose.yml" "$WORK/package.json" "$WORK/package-lock.json" "$MAIN/"
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$MAIN" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -f "$MAIN/docker-compose.override.yml" ]
  [ ! -L "$MAIN/docker-compose.override.yml" ]
}

@test "a stale symlink pointing at a different MAIN_ROOT is cleared and relinked, not left dangling" {
  local other_main; other_main=$(mktemp -d)
  ln -s "$other_main/docker-compose.override.yml" "$WORK/docker-compose.override.yml"
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -L "$WORK/docker-compose.override.yml" ]
  [ "$(readlink "$WORK/docker-compose.override.yml")" = "$MAIN/docker-compose.override.yml" ]
  rm -rf "$other_main"
}

@test "a project's own committed docker-compose.override.yml at PROJECT_ROOT is left untouched" {
  echo "services: {}" > "$WORK/docker-compose.override.yml"
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ ! -L "$WORK/docker-compose.override.yml" ]
  [ "$(cat "$WORK/docker-compose.override.yml")" = "services: {}" ]
}

@test "re-running gen-override.sh against the same worktree is idempotent" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -L "$WORK/docker-compose.override.yml" ]
  [ "$(readlink "$WORK/docker-compose.override.yml")" = "$MAIN/docker-compose.override.yml" ]
}

@test "gen-override.sh falls back to /app when no bind-mount volume line matches" {
  cat > "$WORK/docker-compose.yml" <<'YML'
services:
  app:
    volumes: ["appdata:/data"]
volumes:
  appdata:
YML
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --query container-src
  [ "$status" -eq 0 ]
  [ "$output" = "/app" ]
}

# ─── gen-override.sh: CREW_DOCKER_PLATFORM ───────────────────────────────────
#
# The project's own docker-compose.yml (fixture below) pins `platform: linux/amd64`.
# These tests pin that the *override* — not the project's pin — decides what lands in
# the generated YAML, since verify-worktree.sh and docker-install.sh always pass the
# override with a later -f, so its platform key wins the compose merge.

@test "gen-override.sh emits a platform key matching the detected host architecture by default" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --query platform
  [ "$status" -eq 0 ]
  [[ "$output" == "linux/amd64" || "$output" == "linux/arm64" ]]
  local detected="$output"
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [[ "$output" == *"platform: $detected"* ]]
}

@test "CREW_DOCKER_PLATFORM=arm64 forces linux/arm64 regardless of host" {
  CREW_DOCKER_PLATFORM=arm64 run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"platform: linux/arm64"* ]]
}

@test "CREW_DOCKER_PLATFORM=amd64 forces linux/amd64 regardless of host" {
  CREW_DOCKER_PLATFORM=amd64 run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"platform: linux/amd64"* ]]
}

@test "CREW_DOCKER_PLATFORM=linux/arm64/v8 is passed through verbatim" {
  CREW_DOCKER_PLATFORM=linux/arm64/v8 run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"platform: linux/arm64/v8"* ]]
}

@test "CREW_DOCKER_PLATFORM=off emits no platform key, leaving the project's own pin unchanged" {
  CREW_DOCKER_PLATFORM=off run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"platform:"* ]]
}

@test "CREW_DOCKER_PLATFORM=off makes --query platform print nothing" {
  CREW_DOCKER_PLATFORM=off run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --query platform
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an unknown CREW_DOCKER_PLATFORM value is a usage error, not a silent fallback" {
  CREW_DOCKER_PLATFORM=bogus run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"CREW_DOCKER_PLATFORM"* ]]
}

@test "docker-install.sh's written override carries the resolved platform key" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  grep -q "platform: linux/" "$MAIN/docker-compose.override.yml"
}

# ─── docker-install.sh: detection and argument construction ─────────────────

@test "installs via docker compose run with both -f flags and the ecosystem's own command" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == "Running: docker compose run --rm app sh -c"* ]]
  [[ "$output" == *"npm ci"* ]]
  [ -f "$MAIN/docker-compose.override.yml" ]
  [ -L "$WORK/docker-compose.override.yml" ]
}

@test "--service overrides the first-service default" {
  cat > "$WORK/docker-compose.yml" <<'YML'
services:
  app:
    volumes: [".:/opt/app"]
  worker:
    volumes: [".:/opt/app"]
YML
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --service worker
  [ "$status" -eq 0 ]
  [[ "$output" == *"--rm worker"* ]]
}

@test "agent.install-service git config wins over the first-service default" {
  cat > "$WORK/docker-compose.yml" <<'YML'
services:
  app:
    volumes: [".:/opt/app"]
  worker:
    volumes: [".:/opt/app"]
YML
  git -C "$WORK" init -q
  git -C "$WORK" config --local agent.install-service worker
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--rm worker"* ]]
}

@test "dev-commands.json docker_service wins over the first-service default when no git config is set" {
  cat > "$WORK/docker-compose.yml" <<'YML'
services:
  app:
    volumes: [".:/opt/app"]
  worker:
    volumes: [".:/opt/app"]
YML
  mkdir -p "$MAIN/.coding-crew"
  printf '{"docker_service": "worker"}\n' > "$MAIN/.coding-crew/dev-commands.json"
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--rm worker"* ]]
}

@test "agent.install-service git config wins over a cached docker_service" {
  cat > "$WORK/docker-compose.yml" <<'YML'
services:
  app:
    volumes: [".:/opt/app"]
  worker:
    volumes: [".:/opt/app"]
YML
  mkdir -p "$MAIN/.coding-crew"
  printf '{"docker_service": "worker"}\n' > "$MAIN/.coding-crew/dev-commands.json"
  git -C "$WORK" init -q
  git -C "$WORK" config --local agent.install-service app
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--rm app"* ]]
}

@test "--install-cmd overrides the per-manifest lockfile table" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --install-cmd "make deps"
  [ "$status" -eq 0 ]
  [[ "$output" == *"make deps"* ]]
  [[ "$output" != *"npm ci"* ]]
}

@test "--install-cmd runs even when no lockfile the per-manifest table recognises is present" {
  rm -f "$WORK/package-lock.json"
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --install-cmd "make deps"
  [ "$status" -eq 0 ]
  [[ "$output" == *"make deps"* ]]
}

@test "--install-cmd that itself names docker compose/run/exec is rejected, not nested" {
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" \
    --install-cmd "docker compose run --rm other-service make deps"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already invokes docker"* ]]
}

@test "--install-cmd running a make target whose own recipe shells out to docker is rejected, not nested" {
  cat > "$WORK/Makefile" <<'MAKE'
deps:
	docker compose run --rm node npm ci
MAKE
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --install-cmd "make deps"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already invokes docker"* ]]
}

@test "no compose file is exit 2, not a failure" {
  rm -f "$WORK/docker-compose.yml"
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 2 ]
}

@test "a compose file with no supported ecosystem manifest is exit 2" {
  rm -f "$WORK/package.json" "$WORK/package-lock.json"
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 2 ]
}

@test "an install that fails inside the container is exit 3 with the tail on stderr" {
  stub_docker 1 "npm ERR! boom"
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 3 ]
  [[ "$output" == *"npm ERR! boom"* ]]
}

# ─── the lock ─────────────────────────────────────────────────────────────────

@test "an already-held lock is exit 4 within --lock-timeout, not a hang" {
  mkdir -p "$MAIN/.scratch/.docker-install.lock"
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --lock-timeout 1
  [ "$status" -eq 4 ]
  # the lock this run did not create is left exactly as it was found
  [ -d "$MAIN/.scratch/.docker-install.lock" ]
}

@test "the lock is released after a successful install" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ ! -d "$MAIN/.scratch/.docker-install.lock" ]
}

@test "the lock is released after a failed install" {
  stub_docker 1 "boom"
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 3 ]
  [ ! -d "$MAIN/.scratch/.docker-install.lock" ]
}

# ─── .env: forwards --main-root to ensure-env.sh ──────────────────────────────────────────

@test "honors an existing MAIN_ROOT .env instead of generating a new one in PROJECT_ROOT" {
  echo "SECRET=real" > "$MAIN/.env"
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -L "$WORK/.env" ]
  [ "$(cat "$WORK/.env")" = "SECRET=real" ]
}

# ─── --credential-target: forwarded to ensure-env.sh, unexamined ──────────────────────────
#
# The mechanical mirror of dep-install's docker-install.md step 0, where a model scans the
# Makefile by hand. ensure-deps.sh forwards a dev-commands.json-cached value here the same way
# it forwards --install-cmd, so this needs no model call once a value is cached.

@test "--credential-target is forwarded to ensure-env.sh, generating credential config via the discovered command" {
  cat > "$WORK/Makefile" <<'MK'
.npmrc:
	echo "TOKEN=x" > .npmrc
MK
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --credential-target "make .npmrc"
  [ "$status" -eq 0 ]
  [ -f "$WORK/.npmrc" ]
}

@test "no --credential-target leaves ensure-env.sh to its own template-only fallback" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ ! -f "$WORK/.npmrc" ]
}

# ─── usage ────────────────────────────────────────────────────────────────────

@test "--project-root and --main-root are required" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -ne 0 ]
}

@test "the script is shipped executable" {
  [ -x "$SCRIPT" ]
}

# ─── docker-in-docker guard (prose, step 2 of docker-install.md) ─────────────
# docker-install.sh's own per-directory install table only ever reads a fixed
# lockfile→package-manager map, so that path cannot recurse into a nested docker call.
# Its --install-cmd override can (a project's documented "install" command may itself be
# `make deps`, and that recipe may shell out to docker) — that case is guarded in the
# script itself (_override_uses_docker, exit 2), pinned above. The one place this repo
# *also* suggests running a Makefile `install`/`deps` target inside `docker compose run`
# from scratch is docker-install.md's step 2, read and followed by a model rather than
# executed by a script — so that half of the guard lives there as prose, pinned here the
# same way worker-close-guard.bats pins solve-issue's prose sections.

@test "docker-install.md's step 2 dry-runs a Makefile install/deps target before wrapping it in docker compose" {
  local doc="$SCRIPTS_DIR/../references/docker-install.md"
  [ -f "$doc" ]
  grep -q 'make -n install' "$doc"
  grep -qiE "docker compose\`, \`docker run\`, or \`docker exec\`" "$doc"
  grep -qi 'on the host, unwrapped' "$doc"
}
