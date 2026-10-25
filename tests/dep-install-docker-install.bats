#!/usr/bin/env bats

# docker-install.sh — dep-install's docker-mode sibling of host-install.sh, and what run.sh calls
# when a docker-mode checkout has no override yet. Deterministic: ecosystem detection, service
# selection, the install command, the stamp.
#
# What is NOT pinned here: real docker behaviour. `docker` is stubbed on PATH throughout, so
# these tests pin argument construction, exit codes and the stamp — not the daemon.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"
SCRIPT="$SCRIPTS_DIR/docker-install.sh"

load helpers/fake-docker

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  # physical paths: the docker shim reports the override via `git rev-parse`, which resolves
  # symlinks (macOS's /var -> /private/var), so a logical path would never match its calls
  WORK=$(cd "$(mktemp -d)" && pwd -P)
  export WORK
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
  rm -rf "$TEMP_DIR" "$WORK"
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

_cache() {
  mkdir -p "$WORK/.coding-crew"
  printf '%s\n' "$1" > "$WORK/.coding-crew/dev-commands.json"
}

_two_services() {
  cat > "$WORK/docker-compose.yml" <<'YML'
services:
  app:
    volumes: [".:/opt/app"]
  worker:
    volumes: [".:/opt/app"]
YML
}

# ─── gen-override.sh --query ─────────────────────────────────────────────────

@test "gen-override.sh --query services prints the compose services, one per line" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --query services
  [ "$status" -eq 0 ]
  [ "$output" = "app" ]
}

@test "gen-override.sh --query ecosystem, container-src and manifest-dirs answer without writing the override" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --query ecosystem
  [ "$output" = "node" ]
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --query container-src
  [ "$output" = "/opt/app" ]
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --query manifest-dirs
  [ "$output" = "$WORK" ]
  [ ! -f "$OVERRIDE" ]
}

@test "gen-override.sh --query vendor-paths prints each dep volume's container path" {
  mkdir -p "$WORK/packages/web"
  printf '{"name":"web"}\n' > "$WORK/packages/web/package.json"
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --query vendor-paths
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '/opt/app/node_modules\n/opt/app/packages/web/node_modules')" ]
}

@test "gen-override.sh --query rejects an unknown field" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --query bogus
  [ "$status" -ne 0 ]
}

@test "gen-override.sh --query never hashes the lockfiles" {
  printf '#!/usr/bin/env bash\ntouch "%s/hashed"\nexit 1\n' "$TEMP_DIR" > "$STUB/manifest-stub"
  for b in sha256sum shasum openssl; do cp "$STUB/manifest-stub" "$STUB/$b"; chmod +x "$STUB/$b"; done
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --query services
  [ "$status" -eq 0 ]
  [ "$output" = "app" ]
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --query vendor-paths
  [ "$output" = "/opt/app/node_modules" ]
  [ ! -e "$TEMP_DIR/hashed" ]
}

# ─── gen-override.sh: where the override goes, and what it holds ─────────────
#
# Into the checkout's own git dir, never the repo tree: every compose call gets it from the
# docker shim, so nothing named docker-compose.override.yml is written or linked anywhere.

@test "gen-override.sh writes the override into PROJECT_ROOT's git dir and nothing into the tree" {
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ -f "$OVERRIDE" ]
  [ ! -e "$WORK/docker-compose.override.yml" ]
}

@test "a project's own docker-compose.override.yml at PROJECT_ROOT is left untouched" {
  echo "services: {}" > "$WORK/docker-compose.override.yml"
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ ! -L "$WORK/docker-compose.override.yml" ]
  [ "$(cat "$WORK/docker-compose.override.yml")" = "services: {}" ]
}

@test "re-running gen-override.sh against the same checkout is idempotent" {
  bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" >/dev/null
  first="$(cat "$OVERRIDE")"
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK"
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
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" --query container-src
  [ "$status" -eq 0 ]
  [ "$output" = "/app" ]
}

# stub_uname_m <arch> — `uname -m` prints <arch>; any other uname call goes to the real one.
stub_uname_m() {
  local real
  real=$(command -v uname)
  printf '#!/usr/bin/env bash\n[ "$1" = -m ] && { echo %s; exit 0; }\nexec %s "$@"\n' "$1" "$real" > "$STUB/uname"
  chmod +x "$STUB/uname"
}

# The override's later -f wins the compose merge, so its platform key overrides a project's own
# linux/amd64 pin: an arm64 host then runs native images instead of flaky qemu emulation.
@test "the override pins every service to the host's architecture" {
  _two_services
  stub_uname_m aarch64
  bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" >/dev/null
  [ "$(grep -c '^    platform: linux/arm64$' "$OVERRIDE")" -eq 2 ]
  stub_uname_m x86_64
  bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK" >/dev/null
  grep -q '^    platform: linux/amd64$' "$OVERRIDE"
}

@test "an unrecognised host architecture pins no platform, leaving the project's own" {
  stub_uname_m riscv64
  run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK"
  [ "$status" -eq 0 ]
  ! grep -q 'platform:' "$OVERRIDE"
}

@test "the override passes NPM_TOKEN by name, so a project's .npmrc \${NPM_TOKEN} resolves from the invoking shell" {
  NPM_TOKEN=t run bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$WORK"
  [ "$status" -eq 0 ]
  grep -qx '      - NPM_TOKEN' "$OVERRIDE"
}

# ─── docker-install.sh: detection and argument construction ─────────────────

@test "installs via docker compose run through the shim, with the ecosystem's own command" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == "Running: docker compose run --rm app sh -c"* ]]
  [[ "$output" == *"npm ci"* ]]
  [ -f "$OVERRIDE" ]
  [ ! -e "$WORK/docker-compose.override.yml" ]
}

@test "--service overrides the first-service default" {
  _two_services
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK" --service worker
  [ "$status" -eq 0 ]
  [[ "$output" == *"--rm worker"* ]]
}

@test "the checkout's dev-commands.json docker_service wins over the first-service default" {
  _two_services
  _cache '{"docker_service": "worker"}'
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--rm worker"* ]]
}

@test "a Python project with no lockfile installs its dev group in the container, as on the host" {
  rm -f "$WORK/package.json" "$WORK/package-lock.json"
  printf '[project]\nname = "x"\n\n[dependency-groups]\ndev = ["pytest"]\n' > "$WORK/pyproject.toml"
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pip install --quiet . --group dev"* ]]
}

@test "a Python project with a go.mod beside it installs with pip, the container's ecosystem" {
  rm -f "$WORK/package.json" "$WORK/package-lock.json"
  printf '[project]\nname = "x"\n' > "$WORK/pyproject.toml"
  printf 'module x\n' > "$WORK/go.mod"
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pip install --quiet ."* ]]
  [[ "$output" != *"go mod download"* ]]
}

@test "the cached install command replaces the per-manifest lockfile table" {
  _cache '{"install": "make deps"}'
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd /opt/app && make deps"* ]]
  [[ "$output" != *"npm ci"* ]]
}

# ─── the stamp in the volume ─────────────────────────────────────────────────
#
# `docker` is a fake that keeps each named volume as a temp dir (helpers/fake-docker.bash) and runs
# the container's script for real against it, so what is pinned here is what the script does to a
# volume, not just which argv it built.

# use_fake_docker — replaces the exit-code stubs with the volume-playing fake
use_fake_docker() {
  FAKE="$TEMP_DIR/fake"
  export FAKE
  install_fake_docker "$STUB" "$FAKE"
}

# vol_dir — the one dependency volume this checkout's override names, as a dir under the fake
vol_dir() {
  local n
  n="$(grep -o 'name: wt_[A-Za-z0-9_]*' "$OVERRIDE" | head -1 | sed 's/^name: //')"
  [ -n "$n" ] || return 1
  echo "$FAKE/vols/$n"
}

_installs() { grep -c . "$FAKE/install.calls" || true; }

@test "the first install runs the command and writes the stamp in the volume" {
  use_fake_docker
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == "Running: docker compose run --rm app sh -c 'cd /opt/app && npm ci'"* ]]
  [[ "$output" != *"Present:"* ]]
  [ "$(_installs)" -eq 1 ]
  [ -f "$(vol_dir)/.crew-stamp" ]
}

@test "two manifest dirs run both installs, joined with &&" {
  use_fake_docker
  mkdir -p "$WORK/web" "$FAKE/app/web" && echo '{}' > "$WORK/web/package.json" && echo x > "$WORK/web/pnpm-lock.yaml"
  printf '#!/bin/sh\necho "pnpm $*" >> "%s/install.calls"\n' "$FAKE" > "$STUB/pnpm" && chmod +x "$STUB/pnpm"
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == "Running: docker compose run --rm app sh -c 'cd /opt/app && npm ci && cd /opt/app/web && pnpm install --frozen-lockfile'"* ]] || { echo "$output"; return 1; }
  [ "$(_installs)" -eq 2 ]
}

@test "with the stamp present, no install command runs and it exits 0" {
  use_fake_docker
  bash "$SCRIPT" --project-root "$WORK" >/dev/null
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Present:"* ]]
  [ "$(_installs)" -eq 1 ]
}

@test "a second worktree with the same lockfiles gets its own volumes, and its own install" {
  use_fake_docker
  git -C "$WORK" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$WORK" worktree add -q "$TEMP_DIR/wt2" -b wt2
  cp "$WORK/docker-compose.yml" "$WORK/package.json" "$WORK/package-lock.json" "$TEMP_DIR/wt2/"
  bash "$SCRIPT" --project-root "$WORK" >/dev/null
  run bash "$SCRIPT" --project-root "$TEMP_DIR/wt2"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Present:"* ]]
  [ "$(_installs)" -eq 2 ]
}

@test "a changed lockfile names new volumes, which get their own install" {
  use_fake_docker
  bash "$SCRIPT" --project-root "$WORK" >/dev/null
  first="$(vol_dir)"
  echo '{"changed":true}' > "$WORK/package-lock.json"
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == "Running: docker compose run"* ]]
  [ "$(vol_dir)" != "$first" ]
  [ "$(_installs)" -eq 2 ]
  [ -f "$first/.crew-stamp" ] && [ -f "$(vol_dir)/.crew-stamp" ]
}

@test "--force deletes the stamp and reinstalls" {
  use_fake_docker
  bash "$SCRIPT" --project-root "$WORK" >/dev/null
  [ -f "$(vol_dir)/.crew-stamp" ]
  run bash "$SCRIPT" --project-root "$WORK" --force
  [ "$status" -eq 0 ]
  [[ "$output" != *"Present:"* ]]
  [ "$(_installs)" -eq 2 ]
  [ -f "$(vol_dir)/.crew-stamp" ]
}

@test "a failed install writes no stamp, removes the override, and is exit 3 naming service and step" {
  use_fake_docker
  export FAKE_NPM_RC=1
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 3 ]
  [[ "$output" == *"npm ERR! boom"* ]]
  [[ "${lines[${#lines[@]}-1]}" == "docker-install: failed — service app, step install, exit 3" ]]
  [ ! -f "$OVERRIDE" ]
  [ -z "$(find "$FAKE/vols" -name .crew-stamp)" ]
}

@test "a failed --force reinstall leaves no stamp behind" {
  use_fake_docker
  bash "$SCRIPT" --project-root "$WORK" >/dev/null
  stamp="$(vol_dir)/.crew-stamp"
  FAKE_NPM_RC=1 run bash "$SCRIPT" --project-root "$WORK" --force
  [ "$status" -eq 3 ]
  [ ! -e "$stamp" ]
}

@test "an install command that runs docker itself runs on the host, its compose call given the override, then stamps the volume" {
  printf 'deps:\n\tdocker compose run --rm app npm ci\n' > "$WORK/Makefile"
  _cache '{"install": "make deps"}'
  use_fake_docker
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Running on the host, as it runs docker itself: make deps"* ]]
  # the recipe's own call went through the shim: the override is its last -f
  grep -q -- "-f $OVERRIDE run --rm app npm ci" "$FAKE/docker.calls"
  [ "$(_installs)" -eq 1 ]
  [ -f "$(vol_dir)/.crew-stamp" ]

  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Present:"* ]]
  [ "$(_installs)" -eq 1 ]
}

@test "a failed host-run install writes no stamp, removes the override, and is exit 3" {
  printf 'deps:\n\tdocker compose run --rm app npm ci\n' > "$WORK/Makefile"
  _cache '{"install": "make deps"}'
  use_fake_docker
  bash "$SCRIPT" --project-root "$WORK" >/dev/null
  stamp="$(vol_dir)/.crew-stamp"
  FAKE_NPM_RC=1 run bash "$SCRIPT" --project-root "$WORK" --force
  [ "$status" -eq 3 ]
  [[ "$output" == *"failed on the host ('make deps'"* ]]
  [[ "${lines[${#lines[@]}-1]}" == "docker-install: failed — service app, step install, exit 3" ]]
  [ ! -e "$stamp" ]
  [ ! -f "$OVERRIDE" ]
}

@test "no compose file is exit 2, not a failure" {
  rm -f "$WORK/docker-compose.yml"
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 2 ]
  [[ "$output" == *"step detect, exit 2"* ]]
}

@test "a compose file with no supported ecosystem manifest is exit 2" {
  rm -f "$WORK/package.json" "$WORK/package-lock.json"
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 2 ]
}

@test "an install that fails inside the container is exit 3 with the tail on stderr" {
  stub_docker 1 "npm ERR! boom"
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 3 ]
  [[ "$output" == *"npm ERR! boom"* ]]
}

# ─── .env and registry_auth ──────────────────────────────────────────────

@test "a missing .env is generated in the checkout itself" {
  echo "FOO=bar" > "$WORK/.env.example"
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ ! -L "$WORK/.env" ]
  diff "$WORK/.env.example" "$WORK/.env"
}

@test "the cached registry_auth runs before the install" {
  cat > "$WORK/Makefile" <<'MK'
.npmrc:
	echo "TOKEN=x" > .npmrc
MK
  stub_docker 0
  _cache '{"registry_auth": "make .npmrc"}'
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ -f "$WORK/.npmrc" ]
}

@test "--skip-env runs neither env nor registry_auth and expands no template" {
  stub_docker 0
  printf 'x=${NPM_TOKEN}\n' > "$WORK/.npmrc.tpl"
  _cache '{"env": "touch env-ran && touch .env", "registry_auth": "touch registry-auth-ran"}'
  NPM_TOKEN=secret run bash "$SCRIPT" --project-root "$WORK" --skip-env
  [ "$status" -eq 0 ]
  [ ! -e "$WORK/env-ran" ]
  [ ! -e "$WORK/.env" ]
  [ ! -e "$WORK/registry-auth-ran" ]
  [ ! -e "$WORK/.npmrc" ]
  # Without the flag, as before.
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ -e "$WORK/env-ran" ]
  [ -e "$WORK/registry-auth-ran" ]
}

@test "no registry_auth leaves ensure-env.sh to its own template-only fallback" {
  stub_docker 0
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ ! -f "$WORK/.npmrc" ]
}

# ─── usage ────────────────────────────────────────────────────────────────────

@test "--project-root is required" {
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "the script is shipped executable" {
  [ -x "$SCRIPT" ]
}
