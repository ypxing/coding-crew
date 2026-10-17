#!/usr/bin/env bats

# host-install.sh, the .env half — mirrors docker-install.sh's own ensure-env.sh call
# (steps 0b/0c of docker-install.md), which the host path never had: a repo that needs a
# .env before its tests/lint/typecheck can even run got nothing on the host path, only on
# docker. .env creation is mechanical (cp/touch, no model), so it belongs here regardless
# of whether an install command is found.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SCRIPT="$SCRIPT_DIR/lib/checks/host-install.sh"

setup() {
  PROJECT=$(mktemp -d)
  export PROJECT
}

teardown() {
  rm -rf "$PROJECT"
}

# _cache <json> — the checkout's dev commands file (the tracked path: $PROJECT is no git checkout).
_cache() {
  mkdir -p "$PROJECT/.coding-crew"
  printf '%s\n' "$1" > "$PROJECT/.coding-crew/dev-commands.json"
}

# _stub_npm — a fake `npm` on PATH that records its argv, so the lockfile table runs without npm.
_stub_npm() {
  mkdir -p "$PROJECT/.stub"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/npm.calls"\n' "$PROJECT" > "$PROJECT/.stub/npm"
  chmod +x "$PROJECT/.stub/npm"
  export PATH="$PROJECT/.stub:$PATH"
}

@test "creates .env from .env.example before running the cached install command" {
  _cache '{"install": "cp .env installed.marker"}'
  echo "FOO=bar" > "$PROJECT/.env.example"

  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  diff "$PROJECT/.env.example" "$PROJECT/.env"
  diff "$PROJECT/.env.example" "$PROJECT/installed.marker"
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
  _cache '{"install": "touch installed.marker"}'

  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/.env")" = "REAL=1" ]
}

@test "a cached install command runs, and the lockfile table is not consulted" {
  _stub_npm
  _cache '{"install": "touch installed.marker"}'
  echo '{}' > "$PROJECT/package-lock.json"

  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Running: touch installed.marker"* ]]
  [ -f "$PROJECT/installed.marker" ]
  [ ! -e "$PROJECT/npm.calls" ]
}

@test "a failing cached install command exits 3" {
  _cache '{"install": "exit 7"}'

  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 3 ]
}

@test "a cached null install never runs a Makefile install target: the lockfile table decides" {
  _stub_npm
  _cache '{"install": null}'
  printf 'install:\n\ttouch installed.marker\n' > "$PROJECT/Makefile"
  echo '{}' > "$PROJECT/package-lock.json"

  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  [ ! -e "$PROJECT/installed.marker" ]
  [ "$(cat "$PROJECT/npm.calls")" = "ci" ]
}

@test "every run installs: no fingerprint fast path" {
  _cache '{"install": "touch installed.marker"}'

  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  rm -f "$PROJECT/installed.marker"
  run bash "$SCRIPT" --project-root "$PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$PROJECT/installed.marker" ]
  [ ! -e "$PROJECT/.scratch/host-install.done" ]
}

# _stub_pip — a fake `pip` on PATH that records its argv, so the Python fallback runs without
# touching a real interpreter.
_stub_pip() {
  mkdir -p "$PROJECT/.stub"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/pip.calls"\n' "$PROJECT" > "$PROJECT/.stub/pip"
  chmod +x "$PROJECT/.stub/pip"
  export PATH="$PROJECT/.stub:$PATH"
}

@test "a pyproject.toml project with no lockfile gets its dev dependency group installed" {
  _stub_pip
  printf '[project]\nname = "x"\n\n[dependency-groups]\ndev = ["pytest"]\n' > "$PROJECT/pyproject.toml"

  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Running: pip install --quiet . --group dev"* ]]
  [ "$(cat "$PROJECT/pip.calls")" = "install --quiet . --group dev" ]
}

@test "a pyproject.toml dev extra reaches pip as one .[dev] argument" {
  _stub_pip
  printf '[project]\nname = "x"\n\n[project.optional-dependencies]\ndev = ["pytest"]\n' > "$PROJECT/pyproject.toml"

  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/pip.calls")" = "install --quiet .[dev]" ]
}

@test "a requirements.txt project gets requirements-dev.txt installed too" {
  _stub_pip
  touch "$PROJECT/requirements.txt" "$PROJECT/requirements-dev.txt"

  run bash "$SCRIPT" --project-root "$PROJECT"

  [ "$status" -eq 0 ]
  [ "$(cat "$PROJECT/pip.calls")" = "install -r requirements.txt -r requirements-dev.txt --quiet" ]
}
