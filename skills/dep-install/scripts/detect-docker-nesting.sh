#!/usr/bin/env bash
# True (exit 0) if <cmd> already invokes docker itself — directly, or via a bare
# `make <target>` recipe whose fully-expanded form does (`make -n` expands variables
# too, e.g. `$(DOCKER) run ...`) — false (exit 1) otherwise.
#
# Shared by docker-install.sh (--install-cmd override) and crew-afk's
# verify-worktree.sh (discovered test/lint/typecheck commands): a command that
# already manages its own docker call must never be nested inside an outer
# `docker compose run`, which has no docker CLI of its own to nest into.
#
# Usage: detect-docker-nesting.sh --dir <path> --cmd <cmd>
# Exit codes:
#   0  <cmd> (or its make recipe) already invokes docker
#   1  it does not
#   2  argument error

set -uo pipefail

DIR=""
CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --cmd) CMD="$2"; shift 2 ;;
    --help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DIR" || -z "$CMD" ]]; then
  echo "Error: --dir and --cmd are required" >&2
  exit 2
fi

if printf '%s' "$CMD" | grep -qE 'docker (compose|run|exec)'; then
  exit 0
fi

target="$(printf '%s' "$CMD" | grep -oE 'make[[:space:]]+[A-Za-z0-9_.:-]+' | head -1 | awk '{print $2}')"
[[ -n "$target" && -f "$DIR/Makefile" ]] || exit 1

recipe="$(cd "$DIR" && make -n "$target" 2>/dev/null || true)"
printf '%s' "$recipe" | grep -qE 'docker (compose|run|exec)'
