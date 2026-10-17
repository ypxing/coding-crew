#!/usr/bin/env bash
# ci-run-bats.sh [--log-dir <dir>] <file>... — run each bats file as its own process, several
# at once and heaviest first, then print every file's output in the order given and exit non-zero if any failed.
# bats' own --jobs needs GNU parallel, which not every runner has; xargs -P is in every base image.
# BATS names the bats binary (default: bats, else the pinned bats-core below); CI_BATS_JOBS the concurrency
# (default: CPUs); CI_BATS_REPO where that bats-core is cloned from (default: GitHub).
set -uo pipefail

usage() { echo "Usage: ci-run-bats.sh [--log-dir <dir>] <file>..." >&2; exit 2; }
LOG_DIR=""
if [[ "${1:-}" == --log-dir ]]; then
  [[ $# -ge 2 ]] || usage
  LOG_DIR="$2"; shift 2
fi
[[ $# -ge 1 ]] || usage
if [[ -z "$LOG_DIR" ]]; then
  LOG_DIR="$(mktemp -d)"
  trap 'rm -rf "$LOG_DIR"' EXIT
fi
mkdir -p "$LOG_DIR"

# A machine with no bats (the solve-feature workflow's runner installs none) gets the bats-core ci.yml pins,
# cloned outside the checkout: a check must leave the tree as it found it.
BATS_REF=v1.13.0
if [[ -z "${BATS:-}" ]] && ! command -v bats >/dev/null 2>&1; then
  bats_dir="${XDG_CACHE_HOME:-$HOME/.cache}/coding-crew/bats-core-$BATS_REF"
  if [[ ! -x "$bats_dir/bin/bats" ]]; then
    rm -rf "$bats_dir"
    if ! out="$(git -c advice.detachedHead=false clone -q --depth 1 --branch "$BATS_REF" \
      "${CI_BATS_REPO:-https://github.com/bats-core/bats-core.git}" "$bats_dir" 2>&1)"; then
      printf '%s\n' "$out" >&2
      echo "ci-run-bats.sh: no bats on PATH, and cloning bats-core $BATS_REF failed" >&2
      exit 1
    fi
  fi
  BATS="$bats_dir/bin/bats"
fi
BATS="${BATS:-bats}"

# The tests see none of this machine's git config or identity, as on a CI runner: a test that commits names its own.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
jobs="${CI_BATS_JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || jobs=2

# Heaviest first by @test count, so the long files are not left to run alone at the end.
# Numbered logs keep the output in the given order and survive two files sharing a basename.
n=0
for f in "$@"; do
  n=$((n + 1))
  tests=$(grep -c '^@test' "$f" 2>/dev/null) || true
  printf '%d\t%d\t%s\n' "${tests:-0}" "$n" "$f"
done \
  | sort -t $'\t' -k1,1rn -k2,2n \
  | while IFS=$'\t' read -r _ i f; do printf '%s\0%s\0' "$i" "$f"; done | BATS="$BATS" LOG_DIR="$LOG_DIR" xargs -0 -n 2 -P "$jobs" bash -c '
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
