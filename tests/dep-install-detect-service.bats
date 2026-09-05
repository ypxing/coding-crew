#!/usr/bin/env bats

# detect-service.sh — best-effort signal for which compose service a project's own Makefile
# recipes use, so ensure-deps.sh can cache it as "docker_service" ahead of gen-override.sh's
# own file-order guess among several declared services.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts"
SCRIPT="$SCRIPTS_DIR/detect-service.sh"

setup() {
  MAIN=$(mktemp -d)
  WORK=$(mktemp -d)
  export MAIN WORK
  cat > "$WORK/docker-compose.yml" <<'YML'
services:
  node:
    build: .
    volumes:
      - .:/opt/app
  compass:
    image: some/other-image
YML
  cat > "$WORK/package.json" <<'JSON'
{"name":"fixture"}
JSON
  cat > "$WORK/package-lock.json" <<'JSON'
{}
JSON
}

teardown() {
  rm -rf "$MAIN" "$WORK"
}

@test "extracts the service after flags in a docker compose run recipe" {
  cat > "$WORK/Makefile" <<'MK'
lint:
	docker compose run --rm --remove-orphans node make _lintFix
MK

  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "node" ]
}

@test "ignores a token that is not a real compose service and keeps looking" {
  cat > "$WORK/Makefile" <<'MK'
lint:
	docker compose run --rm -e FOO=bar node make _lintFix
MK

  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "node" ]
}

@test "prints nothing when no target's recipe invokes docker" {
  cat > "$WORK/Makefile" <<'MK'
lint:
	npx eslint .
MK

  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints nothing when there is no Makefile at all" {
  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "skips a value-taking flag's own value (not a real service) and finds the actual service after it" {
  cat > "$WORK/Makefile" <<'MK'
lint:
	docker compose run --rm --entrypoint sh compass -c "true"
MK

  run bash "$SCRIPT" --project-root "$WORK" --main-root "$MAIN"
  [ "$status" -eq 0 ]
  [ "$output" = "compass" ]
}
