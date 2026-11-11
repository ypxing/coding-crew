#!/usr/bin/env bats

# gen-override.sh --query container-src: where the project's source sits inside the service's container,
# read from the bind mount of the project root in compose's resolved config, however the compose file
# writes it. Without one it stops and says so: a guessed path puts the dependency volumes and the
# install in an empty dir. The forms only compose resolves (inline, long, ${VAR}) run against real
# docker compose and skip without it; the rest use the fake config (helpers/fake-compose-config).

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"
SCRIPT="$SCRIPTS_DIR/gen-override.sh"
NO_MOUNT="no bind mount of the project root in service app; can't tell where the source is in the container"

load helpers/fake-compose-config

setup() {
  ROOT=$(mktemp -d)
  git init -q "$ROOT"
  echo '{"name":"fixture"}' > "$ROOT/package.json"
  echo '{}' > "$ROOT/package-lock.json"
}

teardown() {
  [ -n "${ROOT:-}" ] && rm -rf "$ROOT"
  return 0
}

_real_compose() {
  docker compose version >/dev/null 2>&1 || skip "needs docker compose"
}

_fake_compose() {
  stub_compose_config "$ROOT/.stub"
  PATH="$ROOT/.stub:$PATH"
}

@test "real compose: the inline form volumes: [\".:/src\"] gives /src" {
  _real_compose
  printf 'services:\n  app:\n    image: node:22-alpine\n    working_dir: /src\n    volumes: [".:/src"]\n' > "$ROOT/compose.yml"
  run bash "$SCRIPT" --project-root "$ROOT" --query container-src
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = /src ]
}

@test "real compose: the long form (type: bind, source: ., target: /src) gives /src" {
  _real_compose
  cat > "$ROOT/compose.yml" <<'YML'
services:
  app:
    image: node:22-alpine
    volumes:
      - type: volume
        source: data
        target: /data
      - type: bind
        source: .
        target: /src
volumes:
  data:
YML
  run bash "$SCRIPT" --project-root "$ROOT" --query container-src
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = /src ]
}

@test "real compose: a \${VAR} source and target are interpolated, a missing env_file does not stop it" {
  _real_compose
  printf 'services:\n  app:\n    image: x\n    env_file: [.env.local]\n    volumes:\n      - ${SRC:-.}/:${TARGET:-/opt/app}/\n' > "$ROOT/compose.yml"
  echo 'TARGET=/work' > "$ROOT/.env"
  run bash "$SCRIPT" --project-root "$ROOT" --query container-src
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = /work ]
}

@test "real compose: no bind mount of the project root stops with the reason, never /app" {
  _real_compose
  printf 'services:\n  app:\n    image: x\n    working_dir: /src\n    volumes: ["./sub:/src", "data:/data"]\nvolumes:\n  data:\n' > "$ROOT/compose.yml"
  run bash "$SCRIPT" --project-root "$ROOT" --query container-src
  [ "$status" -eq 4 ]
  [[ "$output" == *"$NO_MOUNT"* ]]
  [[ "$output" != *"/app"* ]]
}

@test "real compose: --service reads that service's mount" {
  _real_compose
  printf 'services:\n  app:\n    image: x\n    volumes: [".:/src"]\n  worker:\n    image: x\n    volumes: [".:/work"]\n' > "$ROOT/compose.yml"
  run bash "$SCRIPT" --project-root "$ROOT" --service worker --query container-src
  [ "$status" -eq 0 ]
  [ "$output" = /work ]
  run bash "$SCRIPT" --project-root "$ROOT" --query container-src
  [ "$output" = /src ]
}

@test "no bind mount of the project root: container-src, vendor-paths and the override all stop with exit 4" {
  _fake_compose
  printf 'services:\n  app:\n    image: x\n    volumes: ["appdata:/data"]\nvolumes:\n  appdata:\n' > "$ROOT/docker-compose.yml"
  for q in "--query container-src" "--query vendor-paths" ""; do
    # shellcheck disable=SC2086
    run bash "$SCRIPT" --project-root "$ROOT" $q
    [ "$status" -eq 4 ] || { echo "$q: $output"; return 1; }
    [[ "$output" == *"$NO_MOUNT"* ]]
  done
  [ ! -f "$ROOT/.git/crew-compose.override.yml" ]
}

@test "a service the config does not have stops with its name" {
  _fake_compose
  printf 'services:\n  app:\n    image: x\n    volumes:\n      - .:/src\n' > "$ROOT/docker-compose.yml"
  run bash "$SCRIPT" --project-root "$ROOT" --service web --query container-src
  [ "$status" -eq 4 ]
  [[ "$output" == *"no bind mount of the project root in service web"* ]]
}

@test "compose config failing stops with compose's own error" {
  mkdir -p "$ROOT/.stub"
  printf '#!/usr/bin/env bash\necho "yaml: line 3: did not find expected key" >&2\nexit 15\n' > "$ROOT/.stub/docker"
  chmod +x "$ROOT/.stub/docker"
  PATH="$ROOT/.stub:$PATH"
  printf 'services:\n  app:\n    image: x\n' > "$ROOT/docker-compose.yml"
  run bash "$SCRIPT" --project-root "$ROOT" --query container-src
  [ "$status" -eq 4 ]
  [[ "$output" == *"did not find expected key"* ]]
}

@test "the root reached through a symlink still matches compose's source" {
  _fake_compose
  printf 'services:\n  app:\n    image: x\n    volumes:\n      - .:/src\n' > "$ROOT/docker-compose.yml"
  local lnk; lnk="$(mktemp -u)"
  ln -s "$(dirname "$ROOT")" "$lnk"
  run bash "$SCRIPT" --project-root "$lnk/$(basename "$ROOT")" --query container-src
  rm -f "$lnk"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = /src ]
}

@test "services, ecosystem, manifest-dirs and project-name need no docker" {
  mkdir -p "$ROOT/.stub"
  printf '#!/usr/bin/env bash\necho called >> "%s/.stub/calls"\nexit 1\n' "$ROOT" > "$ROOT/.stub/docker"
  chmod +x "$ROOT/.stub/docker"
  PATH="$ROOT/.stub:$PATH"
  printf 'services:\n  app:\n    image: x\n' > "$ROOT/docker-compose.yml"
  for q in services ecosystem manifest-dirs project-name; do
    run bash "$SCRIPT" --project-root "$ROOT" --query "$q"
    [ "$status" -eq 0 ] || { echo "$q: $output"; return 1; }
  done
  [ ! -e "$ROOT/.stub/calls" ]
}
