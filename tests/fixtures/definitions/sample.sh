#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

usage() {
  echo "usage: sample.sh <root>"
}

function fetch_issue {
  cat "$ROOT/$1"
}

_mark-done () {
  mv "$1" "$ROOT/done/"
}

usage
