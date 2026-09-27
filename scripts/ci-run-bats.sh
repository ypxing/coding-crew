#!/usr/bin/env bash
# ci-run-bats.sh <log-dir> <file>... — run each bats file as its own process, several at
# once, then print every file's output in the order given and exit non-zero if any failed.
#
# Why: bats runs one file at a time, and its own --jobs needs GNU parallel, which the
# Windows runner lacks — so each Windows job used one of its four cores. xargs -P is in
# every runner's base tools. The files are independent: each makes its own temp dirs, and
# the one cache they share (tests/helpers/render.bash) is written by rename.
#
# BATS names the bats binary (default: bats); CI_BATS_JOBS the concurrency (default: CPUs).
set -uo pipefail

[[ $# -ge 2 ]] || { echo "Usage: ci-run-bats.sh <log-dir> <file>..." >&2; exit 2; }
LOG_DIR="$1"; shift
mkdir -p "$LOG_DIR"

BATS="${BATS:-bats}"
jobs="${CI_BATS_JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || jobs=2

# Numbered logs keep the given order and survive two files sharing a basename.
i=0
for f in "$@"; do
  i=$((i + 1))
  printf '%s\0%s\0' "$i" "$f"
done | BATS="$BATS" LOG_DIR="$LOG_DIR" xargs -0 -n 2 -P "$jobs" bash -c '
  start=$(date +%s)
  "$BATS" --print-output-on-failure "$2" > "$LOG_DIR/$1.log" 2>&1
  echo "$? $(( $(date +%s) - start ))" > "$LOG_DIR/$1.rc"
' _

failed=()
i=0
for f in "$@"; do
  i=$((i + 1))
  read -r rc secs < "$LOG_DIR/$i.rc" 2>/dev/null || { rc=1; secs="?"; }
  echo "::group::$f (${secs}s, exit $rc)"
  cat "$LOG_DIR/$i.log" 2>/dev/null
  echo "::endgroup::"
  [[ "$rc" == 0 ]] || failed+=("$f")
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "Failed files (${#failed[@]}):"
  for f in "${failed[@]}"; do echo "  $f"; done
  exit 1
fi
echo "All $# files passed ($jobs at a time)."
