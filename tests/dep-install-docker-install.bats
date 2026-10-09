#!/usr/bin/env bats

# docker-install.sh — dep-install's docker-mode sibling of host-install.sh. Deterministic
# (ecosystem detection, service selection, the install command), so ensure-deps.sh can call
# it mechanically for the one MAIN_ROOT call a sprint makes before any worktree exists.
#
# What is NOT pinned here: real docker behaviour. `docker` is stubbed on PATH throughout, so
# these tests pin argument construction, exit codes, and the lock — not the daemon.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts"
SCRIPT="$SCRIPTS_DIR/docker-install.sh"

# assert_linked_or_copied <worktree-path> <main-root-path> — ensure-env.sh's `.env` link: a real
# symlink where the platform allows it, or (no symlink privilege — the default on Windows
# without Developer Mode/elevation) an independent file with identical content instead.
assert_linked_or_copied() {
  local link="$1" target="$2"
  if [[ -L "$link" ]]; then
    [ "$(readlink "$link")" = "$target" ]
  else
    [ -f "$link" ]
    diff "$link" "$target"
  fi
}

setup() {
  # Isolation from whatever the ambient shell happens to export — a real crew-afk dispatch
  # always sets MAIN_ROOT for its worker, and without this a test that means to exercise "no
  # --main-root passed" would silently pick that up instead.
  unset MAIN_ROOT
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  MAIN=$(mktemp -d)
  WORK=$(mktemp -d)
  export MAIN WORK
  git init -q "$MAIN"
  git init -q "$WORK"
  # where gen-override.sh writes WORK's override: its own git dir
  OVERRIDE="$WORK/.git/crew-compose.override.yml"
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
  [ ! -f "$OVERRIDE" ]
}

@test "gen-override.sh --query vendor-paths prints each dep volume's container path" {
  mkdir -p "$WORK/packages/web"
  printf '{"name":"web"}\n' > "$WORK/packages/web/package.json"
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --query vendor-paths
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/opt/app/node_modules\n/opt/app/packages/web/node_modules')" ]
}

@test "gen-override.sh --query rejects an unknown field" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --query bogus
  [ "$status" -ne 0 ]
}

# ─── gen-override.sh: where the override goes ───────────────────────────────
#
# Into the worktree's own git dir, never the repo tree: every compose call gets it from the
# docker shim, so nothing named docker-compose.override.yml is written or linked anywhere.

@test "gen-override.sh writes the override into PROJECT_ROOT's git dir and nothing into either tree" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -f "$OVERRIDE" ]
  [ ! -e "$WORK/docker-compose.override.yml" ]
  [ ! -e "$MAIN/docker-compose.override.yml" ]
}

@test "--dry-run prints YAML but writes nothing" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$OVERRIDE" ]
  [ ! -e "$WORK/docker-compose.override.yml" ]
}

@test "a project's own docker-compose.override.yml at PROJECT_ROOT is left untouched" {
  echo "services: {}" > "$WORK/docker-compose.override.yml"
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ ! -L "$WORK/docker-compose.override.yml" ]
  [ "$(cat "$WORK/docker-compose.override.yml")" = "services: {}" ]
}

@test "re-running gen-override.sh against the same worktree is idempotent" {
  bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN" >/dev/null
  first="$(cat "$OVERRIDE")"
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ "$(cat "$OVERRIDE")" = "$first" ]
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
  grep -q "platform: linux/" "$OVERRIDE"
}

# ─── docker-install.sh: detection and argument construction ─────────────────

@test "installs via docker compose run through the shim, with the ecosystem's own command" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == "Running: docker compose run --rm app sh -c"* ]]
  [[ "$output" == *"npm ci"* ]]
  [ -f "$OVERRIDE" ]
  [ ! -e "$MAIN/docker-compose.override.yml" ]
  [ ! -e "$WORK/docker-compose.override.yml" ]
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

@test "a Python project with no lockfile installs its dev group in the container, as on the host" {
  rm -f "$WORK/package.json" "$WORK/package-lock.json"
  printf '[project]\nname = "x"\n\n[dependency-groups]\ndev = ["pytest"]\n' > "$WORK/pyproject.toml"
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pip install --quiet . --group dev"* ]]
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

# ─── an --install-cmd that runs docker itself ────────────────────────────────
#
# Run on the host, never nested inside the service (whose container has no docker CLI) — and,
# because its own docker call then reaches the shared volumes only by loading the override,
# refused when it visibly would not, and probed from the service when it has run.

# _skip_unless_make_sees_stubs — Windows' native make finds a recipe's `docker` by searching the
# whole PATH for docker.exe before any other name, so the bash stub never runs and the recipe
# reaches the real daemon. What these tests pin is docker-install.sh's own logic, which the
# other platforms cover.
_skip_unless_make_sees_stubs() {
  case "$OSTYPE" in msys*|cygwin*) skip "native Windows make bypasses the PATH docker stub" ;; esac
}

# stub_logging_docker [probe-exit] — a fake `docker` that appends each call's argv to
# $TEMP_DIR/docker.calls, exits 0, and exits <probe-exit> (default 0) for the volume probe.
stub_logging_docker() {
  local probe_rc="${1:-0}"
  cat > "$STUB/docker" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEMP_DIR/docker.calls"
case " \$* " in *" --entrypoint sh "*) exit $probe_rc ;; esac
exit 0
SH
  chmod +x "$STUB/docker"
}

@test "--install-cmd naming docker compose itself runs on the host, not nested in the service" {
  stub_logging_docker
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" \
    --install-cmd "docker compose run --rm other-service npm ci"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Running: docker compose run --rm other-service npm ci (on the host"* ]]
  # The command's own call, with the shim's files added — not wrapped in `docker compose ... run app sh -c`.
  grep -qx "compose -f $WORK/docker-compose.yml -f $OVERRIDE run --rm other-service npm ci" "$TEMP_DIR/docker.calls"
  ! grep -q "sh -c cd /opt/app" "$TEMP_DIR/docker.calls"
}

@test "a make target whose recipe runs plain docker compose runs on the host, then the volumes are probed" {
  _skip_unless_make_sees_stubs
  cat > "$WORK/Makefile" <<'MAKE'
deps:
	docker compose run --rm app npm ci
MAKE
  stub_logging_docker
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --install-cmd "make deps"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Running: make deps (on the host"* ]]
  grep -qx "compose -f $WORK/docker-compose.yml -f $OVERRIDE run --rm app npm ci" "$TEMP_DIR/docker.calls"
  # The probe goes through the override, like the checks, at the volume's container path.
  grep -q -- "-f $OVERRIDE run --rm --no-deps --entrypoint sh app .*/opt/app/node_modules" "$TEMP_DIR/docker.calls"
  [ -f "$MAIN/.scratch/docker-install.fingerprint" ]
}

@test "a recipe using -f, COMPOSE_FILE or -p is run, not refused: the shim adds the override to its call" {
  _skip_unless_make_sees_stubs
  cat > "$WORK/Makefile" <<'MAKE'
deps:
	docker compose -f docker-compose.yml -p other run --rm app npm ci
MAKE
  stub_logging_docker
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --install-cmd "make deps"
  [ "$status" -eq 0 ]
  grep -qx "compose -f docker-compose.yml -p other -f $OVERRIDE run --rm app npm ci" "$TEMP_DIR/docker.calls"
}

@test "a recipe running docker run is refused before anything runs (exit 5)" {
  cat > "$WORK/Makefile" <<'MAKE'
deps:
	docker run --rm -v $(PWD):/app node:20 npm ci
MAKE
  stub_logging_docker
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --install-cmd "make deps"
  [ "$status" -eq 5 ]
  [[ "$output" == *"not through docker compose"* ]]
  [[ "$output" == *"docker run"* ]]
  [ ! -f "$TEMP_DIR/docker.calls" ]
  [ ! -d "$MAIN/.scratch/.docker-install.lock" ]
}

@test "a host-run install that leaves every volume empty is exit 5, with no fingerprint stamp" {
  _skip_unless_make_sees_stubs
  cat > "$WORK/Makefile" <<'MAKE'
deps:
	docker compose run --rm app npm ci
MAKE
  stub_logging_docker 7
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --install-cmd "make deps"
  [ "$status" -eq 5 ]
  [[ "$output" == *"volumes the checks run against are still empty"* ]]
  [[ "$output" == *"/opt/app/node_modules"* ]]
  [ ! -f "$MAIN/.scratch/docker-install.fingerprint" ]
  [ ! -d "$MAIN/.scratch/.docker-install.lock" ]
}

@test "a probe that itself fails is exit 5 naming the probe, not an empty volume" {
  _skip_unless_make_sees_stubs
  cat > "$WORK/Makefile" <<'MAKE'
deps:
	docker compose run --rm app npm ci
MAKE
  stub_logging_docker 1
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --install-cmd "make deps"
  [ "$status" -eq 5 ]
  [[ "$output" == *"checking that it reached the dependency volumes failed (exit 1)"* ]]
  [[ "$output" != *"still empty"* ]]
}

@test "an install that runs inside the service is not probed" {
  stub_logging_docker 7
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  ! grep -q -- "--entrypoint" "$TEMP_DIR/docker.calls"
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
  assert_linked_or_copied "$WORK/.env" "$MAIN/.env"
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

# ─── the manifest-fingerprint fast path ──────────────────────────────────────

@test "a FRESH fingerprint stamp skips install entirely, without touching docker" {
  stub_docker 1 "docker should never be invoked on a FRESH stamp"
  bash "$SCRIPTS_DIR/manifest-fingerprint.sh" write --project-root "$WORK" \
    --stamp "$MAIN/.scratch/docker-install.fingerprint"

  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped"* ]]
  [ ! -f "$OVERRIDE" ]
}

@test "changing the lockfile after a successful install makes the next run reinstall" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]]

  echo '{"changed":true}' > "$WORK/package-lock.json"
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]]
  [[ "$output" == "Running: docker compose run"* ]]
}

@test "--force bypasses a FRESH stamp and reinstalls anyway" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]

  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN" --force
  [ "$status" -eq 0 ]
  [[ "$output" != *"skipped"* ]]
  [[ "$output" == "Running: docker compose run"* ]]
}

@test "a successful install writes the fingerprint stamp at MAIN_ROOT" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -f "$MAIN/.scratch/docker-install.fingerprint" ]
  expected="$(bash "$SCRIPTS_DIR/manifest-fingerprint.sh" compute --project-root "$WORK")"
  [ "$(cat "$MAIN/.scratch/docker-install.fingerprint")" = "$expected" ]
}

@test "a failed install writes no fingerprint stamp" {
  stub_docker 1 "boom"
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 3 ]
  [ ! -f "$MAIN/.scratch/docker-install.fingerprint" ]
}

# ─── docker-install.md delegates install execution to docker-install.sh's lock ───────────
# docker-install.md used to hand-run `docker compose run` itself for the install step —
# unlocked, unlike docker-install.sh's own mkdir-based lock (pinned above at "an already-held
# lock is exit 4..."). Multiple coders reaching that hand-run step around the same time each
# started their own container against the same shared named volume with no coordination at
# all. Fixed by having docker-install.md's own install step call docker-install.sh instead of
# reimplementing its logic — docker-in-docker nesting guard included, since it's already
# tested against docker-install.sh's own --install-cmd path above. Pinned here the same way
# worker-close-guard.bats pins solve-issue's prose sections.

@test "docker-install.md's install step delegates to docker-install.sh's lock instead of hand-running docker compose" {
  local doc="$SCRIPTS_DIR/../references/docker-install.md"
  [ -f "$doc" ]
  grep -q 'scripts/docker-install.sh' "$doc"
  grep -q -- '--lock-timeout' "$doc"
  grep -qi 'do not fall back to running .docker compose. yourself' "$doc"
  # No hand-rolled docker compose run for install — only the documented recovery paths
  # (entrypoint override under "Install failures") still construct one directly.
  ! grep -q 'GIT_ENV_ARGS' "$doc"
}
