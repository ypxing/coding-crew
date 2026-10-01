#!/usr/bin/env bash
# ci-test-shard.sh <index> <total> — print the test files belonging to one CI shard.
#
# Why shard at all: the suite is ~550 bats tests whose cost is almost entirely process
# spawning (one full install.sh spawns ~1,500 jq calls alone). Git Bash emulates fork(),
# so the Windows job took 27+ minutes for work that takes 2 elsewhere. bats' own
# `--jobs` needs GNU parallel, which is not on the Windows runner, so the parallelism
# has to come from the job matrix instead.
#
# Balancing is longest-processing-time-first: files are ordered by weight descending and
# each is handed to the shard with the least load so far. Deterministic, so every shard of
# a given (index, total) always gets the same files.
#
# Weight is the file's measured seconds on the slowest runner (macOS) from
# tests/ci-shard-weights.tsv, not its @test count: counts put a 1-test file that runs for
# minutes (an orchestrator-sprint topic file) on a par with a 1-test grep, and left one shard at
# 3x another's time. Files run CPU-count at a time within a shard (ci-run-bats.sh), so no
# single file should outweigh a shard's fair share either: that is why the orchestrator's
# sprint suite is ten bats files, not one. An unlisted file is weighted 5s per @test, so a
# new file still lands somewhere sensible.
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

WEIGHTS="$REPO_ROOT/tests/ci-shard-weights.tsv"
[[ -f "$WEIGHTS" ]] || WEIGHTS=/dev/null

# <@test count>\t<path> per file, then the weights file's value replaces the count-based
# estimate where it has one. A file with zero @test lines still counts as work
# (setup_file, harness), so floor at 1.
for f in "${files[@]}"; do
  printf '%s\t%s\n' "$(grep -c '^@test' "$f" || true)" "$f"
done | awk -F'\t' '
  NR == FNR { sub(/\r$/, ""); if ($1 ~ /^[0-9]+$/ && $2 != "") w[$2] = $1; next }
  {
    n = split($2, parts, "/"); base = parts[n]
    weight = (base in w) ? w[base] : $1 * 5
    printf "%d\t%s\n", (weight > 0 ? weight : 1), $2
  }
' "$WEIGHTS" - | sort -rn -k1,1 -k2,2 | awk -F'\t' -v idx="$INDEX" -v total="$TOTAL" '
{
  best = 1
  for (i = 2; i <= total; i++) if (load[i] < load[best]) best = i
  load[best] += $1
  if (best == idx) print $2
}
'
