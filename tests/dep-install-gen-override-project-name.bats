#!/usr/bin/env bats

# gen-override.sh: the compose project name (`--query project-name`, the override's `name:`).
#
# In the main checkout the override's `name:` is the one compose itself would have picked, or the
# project's own `docker compose up` (run without our override) creates `<name>_default` while our
# invocations create a second network — e.g. a checkout named shop-api got
# `shop_api_default` alongside compose's own `shop-api_default`. A linked worktree
# appends its <owner4>, so each worktree is a compose project of its own.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"
SCRIPT="$SCRIPTS_DIR/gen-override.sh"

setup() {
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
  run bash "$SCRIPT" --project-root "$1" --query project-name
  [ "$status" -eq 0 ]
}

@test "a dashed directory name keeps its dashes, as compose's own default does" {
  fixture "$PARENT/shop-api"
  project_name "$PARENT/shop-api"
  [ "$output" = "shop-api" ]
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
  fixture "$PARENT/checkout" "name: shop-api"
  project_name "$PARENT/checkout"
  [ "$output" = "shop-api" ]
}

@test "a quoted top-level name: is unquoted" {
  fixture "$PARENT/checkout" 'name: "shop-api"'
  project_name "$PARENT/checkout"
  [ "$output" = "shop-api" ]
}

@test "an interpolated top-level name: falls back to the directory name" {
  fixture "$PARENT/checkout" 'name: ${STACK:-shop-api}'
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
  fixture "$PARENT/shop-api"
  git init -q "$PARENT/shop-api"
  bash "$SCRIPT" --project-root "$PARENT/shop-api" >/dev/null
  [ "$(head -1 "$PARENT/shop-api/.git/crew-compose.override.yml")" = "name: shop-api" ]
}

@test "each linked worktree is a compose project of its own; the main checkout keeps compose's name" {
  fixture "$PARENT/app"
  git -C "$PARENT/app" init -q -b main
  git -C "$PARENT/app" -c user.email=t@t -c user.name=T commit -q --allow-empty -m init
  git -C "$PARENT/app" worktree add -q "$PARENT/wt1" -b one
  git -C "$PARENT/app" worktree add -q "$PARENT/wt2" -b two
  fixture "$PARENT/wt1"
  fixture "$PARENT/wt2"
  project_name "$PARENT/app"
  [ "$output" = "app" ]
  project_name "$PARENT/wt1"
  local one="$output"
  project_name "$PARENT/wt2"
  [[ "$one" =~ ^wt1-[0-9a-f]{4}$ ]]
  [[ "$output" =~ ^wt2-[0-9a-f]{4}$ ]]
  # a literal name: is suffixed too, so two worktrees never share it
  printf 'name: shop\n' | cat - "$PARENT/wt1/docker-compose.yml" > "$PARENT/x" && mv "$PARENT/x" "$PARENT/wt1/docker-compose.yml"
  printf 'name: shop\n' | cat - "$PARENT/wt2/docker-compose.yml" > "$PARENT/x" && mv "$PARENT/x" "$PARENT/wt2/docker-compose.yml"
  project_name "$PARENT/wt1"
  one="$output"
  project_name "$PARENT/wt2"
  [[ "$one" == shop-* && "$output" == shop-* && "$one" != "$output" ]]
}
