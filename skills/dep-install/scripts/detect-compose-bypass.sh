#!/usr/bin/env bash
# True (exit 0) if <cmd>, or the `make <target>` recipe it runs as `make -n` expands it, runs
# `docker run` / `docker exec`, printing each reason on stdout; false (exit 1) otherwise.
#
# A command running docker itself runs on the host, and its `docker compose` calls get the crew
# override from the shim whatever -f/COMPOSE_FILE/-p they use; only `docker run`/`exec` loads none.
# A recipe this cannot expand is exit 1: docker-install.sh's volume probe afterwards catches those.
# Usage: detect-compose-bypass.sh --dir <path> --cmd <cmd>
# Exit codes: 0 a bypass was found (reasons on stdout), 1 none found, 2 argument error

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

text="$CMD"
target="$(printf '%s' "$CMD" | grep -oE 'make[[:space:]]+[A-Za-z0-9_.:-]+' | head -1 | awk '{print $2}')"
if [[ -n "$target" && -f "$DIR/Makefile" ]]; then
  text="$text"$'\n'"$(cd "$DIR" && make -n "$target" 2>/dev/null || true)"
fi

REASONS=()
_add() {
  local r
  for r in "${REASONS[@]+"${REASONS[@]}"}"; do [[ "$r" == "$1" ]] && return; done
  REASONS+=("$1")
}

# Split on shell separators first, so the docker part of `cd x && docker run ...` is judged alone.
while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"
  read -r -a words <<<"$seg"
  n=${#words[@]}
  for ((i = 0; i < n; i++)); do
    if [[ "${words[i]}" == "docker" && "${words[i + 1]:-}" =~ ^(run|exec)$ ]]; then
      _add "\`docker ${words[i + 1]}\` loads no compose file, so none of the crew override's volumes: $seg"
      break
    fi
  done
done < <(printf '%s\n' "$text" | sed -E 's/(&&|\|\||;|\|)/\n/g' | grep -E 'docker[[:space:]]+(run|exec)')

((${#REASONS[@]})) || exit 1
printf '%s\n' "${REASONS[@]}"
exit 0
