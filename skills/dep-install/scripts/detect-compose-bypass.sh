#!/usr/bin/env bash
# True (exit 0) if <cmd> — or the `make <target>` recipe it runs, expanded by `make -n` — calls
# docker in a way that would not load the generated docker-compose.override.yml; false (exit 1)
# when no such call is found. Each reason is printed on stdout, one per line.
#
# A command that runs docker itself is run on the host rather than nested (see
# detect-docker-nesting.sh), and it reaches the shared dep volumes only through compose's own
# discovery of docker-compose.override.yml beside the project's compose file. These bypass that:
#   - `docker run` / `docker exec`   no compose file is loaded at all
#   - `-f` / `--file`                explicit files replace discovery; bypasses unless one of
#                                    them names docker-compose.override.yml
#   - `COMPOSE_FILE=`                the same, set in the command, the environment or the
#                                    project's .env
#   - `-p` / `--project-name`,       renames the compose project, and with it every named volume
#     `COMPOSE_PROJECT_NAME=`
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
OVERRIDE="docker-compose.override.yml"

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

# _env_setting <NAME> — where NAME is set so that compose would read it, if anywhere.
_env_setting() {
  local name="$1" v
  v="$(printf '%s\n' "$text" | grep -oE "(^|[[:space:];&|])$name=[^[:space:];&|]*" | head -1 | sed -E "s/^[[:space:];&|]?$name=//")"
  if [[ -n "$v" ]]; then printf 'the command sets %s=%s' "$name" "$v"; return; fi
  v="$(printenv "$name" 2>/dev/null || true)"
  if [[ -n "$v" ]]; then printf 'the environment sets %s=%s' "$name" "$v"; return; fi
  if [[ -f "$DIR/.env" ]]; then
    v="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$name=" "$DIR/.env" | tail -1 |
      sed -E "s/^[[:space:]]*(export[[:space:]]+)?$name=//; s/^[\"']//; s/[\"']$//")"
    [[ -n "$v" ]] && printf '.env sets %s=%s' "$name" "$v"
  fi
}

# One docker call per segment: lines are split on shell separators first, so the docker part
# of `cd x && docker compose ...` is judged on its own.
while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"
  read -r -a words <<<"$seg"
  n=${#words[@]}
  for ((i = 0; i < n; i++)); do
    if [[ "${words[i]}" == "docker" && "${words[i + 1]:-}" =~ ^(run|exec)$ ]]; then
      _add "\`docker ${words[i + 1]}\` loads no compose file, so none of $OVERRIDE's volumes: $seg"
      break
    fi
    j=-1
    if [[ "${words[i]}" == "docker" && "${words[i + 1]:-}" == "compose" ]]; then
      j=$((i + 2))
    elif [[ "${words[i]}" == "docker-compose" ]]; then
      j=$((i + 1))
    fi
    ((j < 0)) && continue
    # Global flags only — they stop at the subcommand, after which `-p` is `run`'s port publish.
    files=()
    for (( ; j < n; j++)); do
      w="${words[j]}"
      case "$w" in
        -f | --file) files+=("${words[j + 1]:-}"); j=$((j + 1)) ;;
        --file=*) files+=("${w#--file=}") ;;
        -p | --project-name)
          _add "\`$w ${words[j + 1]:-}\` renames the compose project, so its volumes are not the shared ones: $seg"
          j=$((j + 1))
          ;;
        --project-name=*) _add "\`$w\` renames the compose project, so its volumes are not the shared ones: $seg" ;;
        --env-file | --project-directory | --profile | --ansi | --progress | --parallel) j=$((j + 1)) ;;
        -*) ;;
        *) break ;;
      esac
    done
    if ((${#files[@]})); then
      reaches=0
      for f in "${files[@]}"; do [[ "$(basename "$f")" == "$OVERRIDE" ]] && reaches=1; done
      ((reaches)) || _add "\`-f ${files[*]}\` replaces compose's file discovery, so $OVERRIDE is never loaded: $seg"
    fi
    break
  done
done < <(printf '%s\n' "$text" | sed -E 's/(&&|\|\||;|\|)/\n/g' | grep -E 'docker(-compose|[[:space:]]+(compose|run|exec))')

if printf '%s\n' "$text" | grep -qE 'docker(-compose|[[:space:]]+compose)'; then
  cf="$(_env_setting COMPOSE_FILE)"
  if [[ -n "$cf" && "$cf" != *"$OVERRIDE"* ]]; then
    _add "$cf, which replaces compose's file discovery, so $OVERRIDE is never loaded"
  fi
  pn="$(_env_setting COMPOSE_PROJECT_NAME)"
  [[ -n "$pn" ]] && _add "$pn, which renames the compose project, so its volumes are not the shared ones"
fi

((${#REASONS[@]})) || exit 1
printf '%s\n' "${REASONS[@]}"
exit 0
