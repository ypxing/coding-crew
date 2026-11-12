#!/usr/bin/env bash
# map-definitions.sh — solve-issue Step 3's map: each file's line count, then its definitions and tests with line
# numbers, so the coder reads only the ranges it needs.
#
# Usage:
#   bash scripts/map-definitions.sh <file>...
#
# Exit 0 when every file was read, matches or not (a file with no definitions is an empty map); non-zero with a usage
# line when given no file, or when a file cannot be read.

set -uo pipefail

if [ $# -eq 0 ]; then
  echo "Usage: map-definitions.sh <file>..." >&2
  exit 2
fi

wc -l -- "$@" || exit
grep -nE '^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(declare[[:space:]]+)?(abstract[[:space:]]+)?(pub(\([a-z]+\))?[[:space:]]+)?(unsafe[[:space:]]+)?(async[[:space:]]+)?(def|class|function\*?|func|fn|interface|type|enum|struct|trait|impl|mod|module)[[:space:]<]|^(export[[:space:]]+)?(const|let|var)[[:space:]]|^[A-Za-z_][A-Za-z0-9_:-]*[[:space:]]*\(\)[[:space:]]*\{|^[[:space:]]+((static|async|get|set|public|private|protected|override|readonly)[[:space:]]+)*\*?[#$A-Za-z_][$A-Za-z0-9_]*[[:space:]]*(<[^>]*>)?\(.*\)[^;]*\{[[:space:]]*$|^[[:space:]]*(await[[:space:]]+)?([A-Za-z_]+\.)?(describe|context|suite|it|test)(\.[A-Za-z]+)?\(|^[[:space:]]*(RSpec\.)?(describe|context|it|specify|test)[[:space:]].*[[:space:]]do[[:space:]]*(\|[^|]*\|)?[[:space:]]*$|^@test' -- "$@"
status=$?
# grep exits 1 when nothing matched, which is an empty map, not a failure.
[ "$status" -eq 1 ] && exit 0
exit "$status"
