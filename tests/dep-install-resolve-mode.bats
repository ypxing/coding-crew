#!/usr/bin/env bats

# resolve-mode.sh — the install mode run.sh and run-checks.sh act on: the checkout's dev commands file
# (commands-file.sh), and nothing else.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks/resolve-mode.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK"
  git -C "$WORK" init -q
}

teardown() {
  rm -rf "$TEMP_DIR"
}

_cache() {
  mkdir -p "$WORK/.coding-crew"
  printf '%s\n' "$1" > "$WORK/.coding-crew/dev-commands.json"
}

@test "no dev-commands.json is host" {
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ "$output" = $'INSTALL_MODE=host\nDOCKER_SERVICE=' ]
}

@test "a dev-commands.json with no install_mode is host, even with a docker Makefile, git config and compose file" {
  _cache '{"test": "npm test"}'
  printf 'install:\n\tdocker compose run --rm app npm ci\n' > "$WORK/Makefile"
  printf 'services:\n  app:\n    image: node\n' > "$WORK/docker-compose.yml"
  git -C "$WORK" config --local agent.install-mode docker
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$output" = $'INSTALL_MODE=host\nDOCKER_SERVICE=' ]
}

@test "install_mode docker and its docker_service are read from the checkout's dev-commands.json" {
  _cache '{"test": "npm test", "install_mode": "docker", "docker_service": "web"}'
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$output" = $'INSTALL_MODE=docker\nDOCKER_SERVICE=web' ]
}

@test "an unknown install_mode is host, and host mode reports no service" {
  _cache '{"install_mode": "podman", "docker_service": "web"}'
  run bash "$SCRIPT" --project-root "$WORK"
  [ "$output" = $'INSTALL_MODE=host\nDOCKER_SERVICE=' ]
}

@test "dep-install's recorded answer lands in a tracked file in the current checkout, keeps the discovered checks, and is what this reads" {
  local write="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks/write-commands-cache.sh"
  git -C "$WORK" -c user.email=t@t -c user.name=T commit -q --allow-empty -m init
  git -C "$WORK" worktree add -q "$TEMP_DIR/wt" -b wt
  mkdir -p "$TEMP_DIR/wt/.coding-crew"
  printf '{"test": "npm test", "lint": null}\n' > "$TEMP_DIR/wt/.coding-crew/dev-commands.json"
  printf '{"install_mode": "docker", "docker_service": "web"}\n' > "$TEMP_DIR/answer.json"
  (cd "$TEMP_DIR/wt" && bash "$write" --response-file "$TEMP_DIR/answer.json") >/dev/null
  [ ! -e "$WORK/.coding-crew/dev-commands.json" ]
  grep -q '"test": "npm test"' "$TEMP_DIR/wt/.coding-crew/dev-commands.json"
  grep -q '"lint": null' "$TEMP_DIR/wt/.coding-crew/dev-commands.json"
  run bash "$SCRIPT" --project-root "$TEMP_DIR/wt"
  [ "$output" = $'INSTALL_MODE=docker\nDOCKER_SERVICE=web' ]
}
