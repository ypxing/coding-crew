#!/usr/bin/env bash
# ci-weights.sh <file>... — print "<weight>\t<file>" per bats file, in the order given: the
# file's seconds from tests/ci-shard-weights.tsv (CI_SHARD_WEIGHTS overrides the path), else
# 5 per @test. A file with zero @test lines still costs setup_file and harness time, so floor
# at 1. ci-test-shard.sh balances shards by it; ci-run-bats.sh starts the heaviest first.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEIGHTS="${CI_SHARD_WEIGHTS:-$REPO_ROOT/tests/ci-shard-weights.tsv}"
[[ -f "$WEIGHTS" ]] || WEIGHTS=/dev/null

for f in "$@"; do
  printf '%s\t%s\n' "$(grep -c '^@test' "$f" 2>/dev/null || true)" "$f"
done | awk -F'\t' '
  FILENAME == ARGV[1] { sub(/\r$/, ""); if ($1 ~ /^[0-9]+$/ && $2 != "") w[$2] = $1; next }
  {
    n = split($2, parts, "/"); base = parts[n]
    weight = (base in w) ? w[base] : $1 * 5
    printf "%d\t%s\n", (weight > 0 ? weight : 1), $2
  }
' "$WEIGHTS" -
