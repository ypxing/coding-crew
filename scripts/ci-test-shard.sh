#!/usr/bin/env bash
# ci-test-shard.sh <index> <total> — print the test files belonging to one CI shard.
# Longest-processing-time-first over scripts/ci-weights.sh's weights in measured seconds, since
# @test counts misweigh files that run for minutes; deterministic for a given (index, total).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { echo "Usage: ci-test-shard.sh <index> <total>   (1-based index)" >&2; exit 2; }

[[ $# -eq 2 ]] || usage
INDEX="$1"
TOTAL="$2"
[[ "$INDEX" =~ ^[0-9]+$ && "$TOTAL" =~ ^[0-9]+$ ]] || usage
(( TOTAL >= 1 )) || usage
(( INDEX >= 1 && INDEX <= TOTAL )) || { echo "Error: index $INDEX out of range 1..$TOTAL" >&2; exit 2; }

shopt -s nullglob
files=("$REPO_ROOT"/tests/*.bats)
(( ${#files[@]} > 0 )) || { echo "Error: no test files found under tests/" >&2; exit 1; }

bash "$REPO_ROOT/scripts/ci-weights.sh" "${files[@]}" | sort -rn -k1,1 -k2,2 | awk -F'\t' -v idx="$INDEX" -v total="$TOTAL" '
{
  best = 1
  for (i = 2; i <= total; i++) if (load[i] < load[best]) best = i
  load[best] += $1
  if (best == idx) print $2
}
'
