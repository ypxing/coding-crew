#!/usr/bin/env bats

# install-cmd.sh — the one lockfile/manifest → install-command table, shared by host-install.sh and
# docker-install.sh. For Python with no uv/poetry lockfile, `pip install .` / `-r requirements.txt`
# alone left the dev tools the checks run (pytest, ruff, mypy…) uninstalled (#273).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SCRIPT="$SCRIPT_DIR/lib/checks/install-cmd.sh"

setup() {
  PROJECT=$(mktemp -d)
}

teardown() {
  rm -rf "$PROJECT"
}

@test "requirements.txt alone installs only it" {
  touch "$PROJECT/requirements.txt"
  run bash "$SCRIPT" "$PROJECT"
  [ "$status" -eq 0 ]
  [ "$output" = "pip install -r requirements.txt --quiet" ]
}

@test "requirements-dev.txt and dev-requirements.txt are installed with requirements.txt" {
  touch "$PROJECT/requirements.txt" "$PROJECT/requirements-dev.txt" "$PROJECT/dev-requirements.txt"
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "pip install -r requirements.txt -r requirements-dev.txt -r dev-requirements.txt --quiet" ]
}

@test "a pyproject.toml with no dev list installs the project alone" {
  printf '[project]\nname = "x"\ndependencies = []\n' > "$PROJECT/pyproject.toml"
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "pip install --quiet ." ]
}

@test "a dev optional-dependencies extra is installed as .[dev]" {
  cat > "$PROJECT/pyproject.toml" <<'TOML'
[project]
name = "x"

[project.optional-dependencies]
docs = ["mkdocs"]
dev = ["pytest", "ruff"]
TOML
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "pip install --quiet '.[dev]'" ]
}

@test "a dev dependency group is installed with --group dev" {
  cat > "$PROJECT/pyproject.toml" <<'TOML'
[project]
name = "x"

[dependency-groups]
dev = [
  "pytest>=8",
  "mypy",
]
TOML
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "pip install --quiet . --group dev" ]
}

@test "a dev extra and a dev group are both installed" {
  printf '[project.optional-dependencies]\ndev = ["ruff"]\n\n[dependency-groups]\ndev = ["pytest"]\n' > "$PROJECT/pyproject.toml"
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "pip install --quiet '.[dev]' --group dev" ]
}

@test "a dev key in another table is not a dev list" {
  cat > "$PROJECT/pyproject.toml" <<'TOML'
[project]
name = "x"

[tool.something]
dev = true
TOML
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "pip install --quiet ." ]
}

@test "requirements.txt wins over pyproject.toml, as before" {
  touch "$PROJECT/requirements.txt"
  printf '[dependency-groups]\ndev = ["pytest"]\n' > "$PROJECT/pyproject.toml"
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "pip install -r requirements.txt --quiet" ]
}

@test "prints nothing for a directory with neither file" {
  run bash "$SCRIPT" "$PROJECT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a lockfile names its own installer, ahead of a Python manifest beside it" {
  touch "$PROJECT/package-lock.json" "$PROJECT/requirements.txt"
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "npm ci" ]
  touch "$PROJECT/uv.lock"
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "uv sync --frozen" ]
}

@test "with no ecosystem named, go.mod wins over a Python manifest beside it, as on the host" {
  touch "$PROJECT/go.mod" "$PROJECT/requirements.txt"
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "go mod download" ]
}

@test "a named ecosystem uses only its own rows" {
  touch "$PROJECT/go.mod" "$PROJECT/requirements.txt" "$PROJECT/Gemfile.lock" "$PROJECT/Cargo.toml" "$PROJECT/composer.json"
  run bash "$SCRIPT" "$PROJECT" python
  [ "$output" = "pip install -r requirements.txt --quiet" ]
  run bash "$SCRIPT" "$PROJECT" ruby
  [ "$output" = "bundle install" ]
  run bash "$SCRIPT" "$PROJECT" rust
  [ "$output" = "cargo fetch" ]
  run bash "$SCRIPT" "$PROJECT" php
  [ "$output" = "composer install --no-interaction" ]
  run bash "$SCRIPT" "$PROJECT" go
  [ "$output" = "go mod download" ]
  run bash "$SCRIPT" "$PROJECT" node
  [ -z "$output" ]
}

@test "a .NET project nested one level down installs with dotnet restore" {
  mkdir "$PROJECT/App"
  touch "$PROJECT/App/App.csproj"
  run bash "$SCRIPT" "$PROJECT"
  [ "$output" = "dotnet restore" ]
}
