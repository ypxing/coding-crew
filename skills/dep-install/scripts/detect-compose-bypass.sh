#!/usr/bin/env bash
# True (exit 0) if <cmd> — or the `make <target>` recipe it runs, expanded by `make -n` — runs
# `docker run` / `docker exec`; false (exit 1) when it does not. Each reason is printed on stdout,
# one per line.
#
# A command that runs docker itself is run on the host rather than nested (see
# detect-docker-nesting.sh), and its `docker compose` calls reach the shared dep volumes because
# the docker shim on PATH adds this worktree's crew override to every one of them — with or
# without `-f`, `COMPOSE_FILE` or `-p`, so none of those is a bypass. These are:
#   - `docker run` / `docker exec`   no compose file is loaded at all, so none of the override's
#                                    volumes
#
# A recipe this cannot expand (a shell script, a failing `make -n`) has nothing to object to and
# is exit 1 — docker-install.sh's probe of the volumes afterwards is what catches those.
#
# Usage: detect-compose-bypass.sh --dir <path> --cmd <cmd>
# Exit codes:
#   0  a bypass was found (reasons on stdout)
#   1  none found
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

# The same expansion detect-docker-nesting.sh uses to decide the command runs docker at all.
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

# One docker call per segment: lines are split on shell separators first, so the docker part
# of `cd x && docker run ...` is judged on its own.
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
