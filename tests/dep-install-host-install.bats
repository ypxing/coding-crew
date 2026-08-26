#!/usr/bin/env bats

# host-install.sh, the .env half — mirrors docker-install.sh's own ensure-env.sh call
# (steps 0b/0c of docker-install.md), which the host path never had: a repo that needs a
# .env before its tests/lint/typecheck can even run got nothing on the host path, only on
# docker. .env creation is mechanical (cp/touch, no model), so it belongs here regardless
# of whether an install command is found.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SCRIPT="$SCRIPT_DIR/skills/dep-install/scripts/host-install.sh"

setup() {
  PROJECT=$(mktemp -d)
  export PROJECT
}

teardown() {
  rm -rf "$PROJECT"
}

@test "creates .env from .env.example before running a Makefile install target" {
  cat > "$PROJECT/Makefile" <<'MK'
install:
	touch installed.marker
MK
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  [ -f "$PROJECT/.env" ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
  [ -f "$PROJECT/installed.marker" ]
}

@test "creates an empty .env with no .env.example, even when no install method is found" {
  # verify-worktree.sh runs test/lint/typecheck regardless of DEPS: none — a project with
  # no manifest/Makefile can still need a .env before those checks work.
  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 2 ]
  [ -f "$PROJECT/.env" ]
}

@test "leaves an existing .env untouched" {
  echo "REAL=1" > "$PROJECT/.env"
  cat > "$PROJECT/Makefile" <<'MK'
install:
	touch installed.marker
MK

  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/.env")" = "REAL=1" ]
}
