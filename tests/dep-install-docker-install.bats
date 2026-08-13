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

# ─── docker-install.sh: detection and argument construction ─────────────────

@test "installs via docker compose run with both -f flags and the ecosystem's own command" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == "Running: docker compose run --rm app sh -c"* ]]
  [[ "$output" == *"npm ci"* ]]
  [ -f "$MAIN/docker-compose.override.yml" ]
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
