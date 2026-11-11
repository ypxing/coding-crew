# Shared bats helper: a fake `docker compose config --format json`, for machines with no docker (macOS CI).
#
#   fake_compose_config            print, from the compose file in $PWD, the JSON compose would
#   stub_compose_config <stub-dir> write <stub-dir>/docker answering only `compose … config …`
#
# It knows only the short volume form, block (`- .:/opt/app`) or inline (`volumes: [".:/opt/app"]`),
# and prints each mount as compose resolves it: a source of `.` or `./…` becomes an absolute bind under
# $PWD, `/…` a bind, any other name a named volume. The long form, ${VAR} and extends need real compose:
# tests/dep-install-gen-override-container-src.bats runs those against it.

FAKE_COMPOSE_CONFIG_HELPER="${BASH_SOURCE[0]}"

fake_compose_config() {
  local f="" n line svc="" first_svc=1 first_vol=1 src tgt type
  for n in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [ -f "$n" ] && { f="$n"; break; }
  done
  [ -n "$f" ] || { echo "no configuration file provided: not found" >&2; return 1; }

  _fcc_mount() { # <src:tgt[:mode]>
    src="${1%%:*}"; tgt="${1#*:}"; tgt="${tgt%%:*}"
    case "$src" in
      .|./) type=bind; src="$PWD" ;;
      ./*)  type=bind; src="$PWD/${src#./}" ;;
      /*)   type=bind ;;
      *)    type=volume ;;
    esac
    [ "$first_vol" -eq 1 ] || printf ',\n'
    first_vol=0
    printf '        {\n          "type": "%s",\n          "source": "%s",\n          "target": "%s"\n        }' "$type" "${src%/}" "${tgt%/}"
  }
  _fcc_close_vols() { [ "$first_vol" -eq 2 ] || { printf '\n      ]'; first_vol=2; }; }

  printf '{\n  "services": {\n'
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]{2}([a-zA-Z0-9_.-]+):[[:space:]]*$ ]]; then
      [ -z "$svc" ] || { _fcc_close_vols; printf '\n    }'; }
      svc="${BASH_REMATCH[1]}"
      [ "$first_svc" -eq 1 ] || printf ',\n'
      first_svc=0
      printf '    "%s": {\n      "image": "x"' "$svc"
      first_vol=2
    elif [ -n "$svc" ] && [[ "$line" =~ ^[[:space:]]{4}volumes:[[:space:]]*\[(.*)\][[:space:]]*$ ]]; then
      printf ',\n      "volumes": [\n'; first_vol=1
      local IFS=,
      for n in ${BASH_REMATCH[1]}; do
        n="${n//\"/}"; n="${n// /}"
        _fcc_mount "$n"
      done
      unset IFS
      _fcc_close_vols
    elif [ -n "$svc" ] && [[ "$line" =~ ^[[:space:]]{4}volumes:[[:space:]]*$ ]]; then
      printf ',\n      "volumes": [\n'; first_vol=1
    elif [ -n "$svc" ] && [ "$first_vol" -ne 2 ] && [[ "$line" =~ ^[[:space:]]+-[[:space:]]+\"?([^\"]+)\"?[[:space:]]*$ ]]; then
      _fcc_mount "${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^[a-zA-Z] ]] && [ -n "$svc" ]; then
      _fcc_close_vols; printf '\n    }'; svc=""
      [[ "$line" =~ ^services: ]] || break
    elif [ "$first_vol" -ne 2 ] && [[ "$line" =~ ^[[:space:]]{4}[a-z_]+: ]]; then
      _fcc_close_vols
    fi
  done < "$f"
  [ -z "$svc" ] || { _fcc_close_vols; printf '\n    }'; }
  printf '\n  }\n}\n'
}

stub_compose_config() {
  mkdir -p "$1"
  cat > "$1/docker" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" compose "*"config "*) . "$FAKE_COMPOSE_CONFIG_HELPER"; fake_compose_config; exit \$? ;;
esac
exit 0
STUB
  chmod +x "$1/docker"
}
