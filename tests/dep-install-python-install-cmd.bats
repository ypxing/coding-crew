#!/usr/bin/env bats

# python-install-cmd.sh — the pip command for a Python project with no uv/poetry lockfile,
# shared by host-install.sh and docker-install.sh. `pip install .` / `-r requirements.txt`
# alone left the dev tools the checks run (pytest, ruff, mypy…) uninstalled (#273).

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SCRIPT="$SCRIPT_DIR/skills/dep-install/scripts/python-install-cmd.sh"

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
