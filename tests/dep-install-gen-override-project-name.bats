#!/usr/bin/env bats

# gen-override.sh: the compose project name (`--query project-name`, the override's `name:`).
#
# The generated override pins `name:` so every worktree shares one compose project. That name
# must be the one compose itself would have picked for the main checkout, or the project's own
# `docker compose up` (run without our override) creates `<name>_default` while our invocations
# create a second network, and services started by one cannot reach services started by the
# other — e.g. a checkout named product-services got `product_services_default` alongside
# compose's own `product-services_default`.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts"
SCRIPT="$SCRIPTS_DIR/gen-override.sh"

setup() {
  unset MAIN_ROOT
  PARENT=$(mktemp -d)
}

teardown() {
  [ -n "${PARENT:-}" ] && rm -rf "$PARENT"
  return 0
}

# fixture <dir> [top-level compose lines...] — a minimal node project in <dir>
fixture() {
  local dir="$1"; shift
  mkdir -p "$dir"
  {
    for line in "$@"; do echo "$line"; done
    cat <<'YML'
services:
  app:
    build: .
    volumes:
      - .:/opt/app
YML
  } > "$dir/docker-compose.yml"
  echo '{"name":"fixture"}' > "$dir/package.json"
  echo '{}' > "$dir/package-lock.json"
}

project_name() {
  run bash "$SCRIPT" --project-root "$1" --main-root "$1" --query project-name
  [ "$status" -eq 0 ]
}

@test "a dashed directory name keeps its dashes, as compose's own default does" {
  fixture "$PARENT/product-services"
  project_name "$PARENT/product-services"
  [ "$output" = "product-services" ]
}

@test "the directory name is normalised the way compose does: lowercased, invalid chars dropped" {
  fixture "$PARENT/My.App_v2"
  project_name "$PARENT/My.App_v2"
  [ "$output" = "myapp_v2" ]
}

@test "leading dashes and underscores are trimmed, as compose does" {
  fixture "$PARENT/_-svc"
  project_name "$PARENT/_-svc"
  [ "$output" = "svc" ]
}

@test "the project's own top-level name: wins over its directory name" {
  fixture "$PARENT/checkout" "name: product-services"
  project_name "$PARENT/checkout"
  [ "$output" = "product-services" ]
}

@test "a quoted top-level name: is unquoted" {
  fixture "$PARENT/checkout" 'name: "product-services"'
  project_name "$PARENT/checkout"
  [ "$output" = "product-services" ]
}

@test "an interpolated top-level name: falls back to the directory name" {
  fixture "$PARENT/checkout" 'name: ${STACK:-product-services}'
  project_name "$PARENT/checkout"
  [ "$output" = "checkout" ]
}

@test "a nested name: key is not mistaken for the project name" {
  fixture "$PARENT/checkout"
  printf 'networks:\n  default:\n    name: shared\n' >> "$PARENT/checkout/docker-compose.yml"
  project_name "$PARENT/checkout"
  [ "$output" = "checkout" ]
}

@test "the generated override carries the same name" {
  fixture "$PARENT/product-services"
  run bash "$SCRIPT" --project-root "$PARENT/product-services" --main-root "$PARENT/product-services" --dry-run
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "name: product-services" ]
}
