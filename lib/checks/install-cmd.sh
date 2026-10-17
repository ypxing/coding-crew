#!/usr/bin/env bash
# install-cmd.sh <dir> [<ecosystem>] — print the command that installs the dependencies of the project
# in <dir>, from its lockfile or manifest (first match in the table below), or nothing when none matches.
# The one table host-install.sh and docker-install.sh both install from. docker-install.sh names the
# container's ecosystem (gen-override.sh's: node, python, ruby, rust, php, go) and gets only its rows,
# so a stray go.mod beside a pyproject.toml never picks `go mod download` for a container with no Go.
# Python with no uv/poetry lockfile gets pip, dev tools included: plain `pip install -r
# requirements.txt` / `pip install .` skip the dev tools the checks run:
#   requirements.txt  also -r requirements-dev.txt / dev-requirements.txt when present
#   pyproject.toml    '.[dev]' for a `dev` key under [project.optional-dependencies], and
#                     --group dev (pip >= 25.1) for one under [dependency-groups]

set -euo pipefail

d="${1:?usage: install-cmd.sh <dir> [<ecosystem>]}"
eco="${2:-}"

# _row <ecosystem> — true when that ecosystem's rows are in play.
_row() { [[ -z "$eco" || "$eco" == "$1" ]]; }

_pip_cmd() {
  local cmd f extra group
  if [[ -f "$d/requirements.txt" ]]; then
    cmd="pip install -r requirements.txt"
    for f in requirements-dev.txt dev-requirements.txt; do
      [[ -f "$d/$f" ]] && cmd+=" -r $f"
    done
    echo "$cmd --quiet"
    return
  fi

  # "<extra> <group>", each 0/1: a `dev =` key directly under the table that names it.
  read -r extra group < <(awk '
    /^[[:space:]]*\[/ { table = $0; gsub(/[[:space:]]/, "", table); next }
    /^[[:space:]]*"?dev"?[[:space:]]*=/ {
      if (table == "[project.optional-dependencies]") e = 1
      if (table == "[dependency-groups]") g = 1
    }
    END { print e + 0, g + 0 }
  ' "$d/pyproject.toml")

  cmd="pip install --quiet"
  [[ "$extra" -eq 1 ]] && cmd+=" '.[dev]'" || cmd+=" ."
  [[ "$group" -eq 1 ]] && cmd+=" --group dev"
  echo "$cmd"
}

if   _row python && [[ -f "$d/uv.lock"           ]]; then echo "uv sync --frozen"
elif _row node   && [[ -f "$d/bun.lockb"         ]]; then echo "bun install --frozen-lockfile"
elif _row node   && [[ -f "$d/pnpm-lock.yaml"    ]]; then echo "pnpm install --frozen-lockfile"
elif _row node   && [[ -f "$d/package-lock.json" ]]; then echo "npm ci"
elif _row node   && [[ -f "$d/yarn.lock"         ]]; then echo "yarn install --frozen-lockfile"
elif _row python && [[ -f "$d/poetry.lock"       ]]; then echo "poetry install --no-root"
elif _row go     && [[ -f "$d/go.sum" || -f "$d/go.mod" ]]; then echo "go mod download"
elif _row python && [[ -f "$d/requirements.txt" || -f "$d/pyproject.toml" ]]; then _pip_cmd
elif _row ruby   && [[ -f "$d/Gemfile.lock"      ]]; then echo "bundle install"
elif _row rust   && [[ -f "$d/Cargo.toml"        ]]; then echo "cargo fetch"
elif _row php    && [[ -f "$d/composer.json"     ]]; then echo "composer install --no-interaction"
elif [[ -z "$eco" ]]; then
  if   [[ -f "$d/pom.xml" ]]; then echo "mvn dependency:resolve dependency:resolve-plugins -q"
  elif [[ -f "$d/mix.exs" ]]; then echo "mix deps.get"
  elif [[ -n "$(find "$d" -maxdepth 2 -name '*.csproj' | head -1)" ]]; then echo "dotnet restore"
  fi
fi
