#!/usr/bin/env bash
# python-install-cmd.sh <dir> — print the pip command that installs a Python project with no
# uv/poetry lockfile, dev tools included, or nothing without requirements.txt or pyproject.toml.
# Plain `pip install -r requirements.txt` / `pip install .` skip the dev tools the checks run:
#   requirements.txt  also -r requirements-dev.txt / dev-requirements.txt when present
#   pyproject.toml    '.[dev]' for a `dev` key under [project.optional-dependencies], and
#                     --group dev (pip >= 25.1) for one under [dependency-groups]

set -euo pipefail

d="${1:?usage: python-install-cmd.sh <dir>}"

if [[ -f "$d/requirements.txt" ]]; then
  cmd="pip install -r requirements.txt"
  for f in requirements-dev.txt dev-requirements.txt; do
    [[ -f "$d/$f" ]] && cmd+=" -r $f"
  done
  echo "$cmd --quiet"
  exit 0
fi

[[ -f "$d/pyproject.toml" ]] || exit 0

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
