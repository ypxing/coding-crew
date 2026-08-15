#!/usr/bin/env bats

# ensure-env.sh — steps 0b-c of docker-install.md. Pins the "always exits 0, .env exists
# after it runs" contract, including the case a dangling symlink is already at .env (a
# stale .worktreeinclude link whose target no longer resolves): `cp`/`touch` on a dangling
# symlink either refuse ("not writing through dangling symlink") or resurrect whatever the
# broken link used to point at, so the script must clear it before creating .env fresh.

SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts/ensure-env.sh"

setup() {
  PROJECT=$(mktemp -d)
  export PROJECT
}

teardown() {
  rm -rf "$PROJECT"
}

@test "creates .env from .env.example when neither exists yet" {
  echo "FOO=bar" > "$PROJECT/.env.example"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ ! -L "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "creates an empty .env when there is no .env.example" {
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
}

@test "leaves an existing real .env untouched" {
  echo "REAL=1" > "$PROJECT/.env"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ "$(cat "$PROJECT/.env")" = "REAL=1" ]
}

@test "clears a dangling .env symlink and creates a real .env from .env.example" {
  echo "FOO=bar" > "$PROJECT/.env.example"
  ln -s "$PROJECT/nonexistent-target" "$PROJECT/.env"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ ! -L "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
}

@test "clears a dangling .env symlink and creates a real empty .env with no .env.example" {
  ln -s "$PROJECT/nonexistent-target" "$PROJECT/.env"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  [ ! -L "$PROJECT/.env" ]
}

@test "leaves a valid (resolving) .env symlink untouched" {
  echo "REAL=1" > "$PROJECT/.env.actual"
  ln -s "$PROJECT/.env.actual" "$PROJECT/.env"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]]
  [ -L "$PROJECT/.env" ]
  [ "$(cat "$PROJECT/.env")" = "REAL=1" ]
}
