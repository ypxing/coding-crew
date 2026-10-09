# Shared bats helper: a fake `docker` that plays named volumes with temp dirs.
#
#   install_fake_docker <stub-dir> <state-dir>
#
# writes <stub-dir>/docker (put <stub-dir> first on PATH) and an `npm` stub beside it. State, all
# under <state-dir>:
#   docker.calls   one line per docker call: its argv, space-joined
#   install.calls  one line per `npm …` call the fake containers made
#   vols/<name>/   one dir per named volume the fake has seen mapped by an override
#   app/           the container's /opt/app; its dependency dirs are symlinks into vols/
#
# `docker compose [-f F]… run [opts] <service> <cmd…>` runs <cmd> for real, on the host, with the
# container's /opt/app rewritten to <state-dir>/app. The last `-f` that is a
# crew-compose.override.yml says which volume sits at which container path: each `- wt_…:/opt/app/…`
# line becomes a symlink app/… -> vols/<name>, so a second run with the same override sees what the
# first one wrote, and one with a different volume name sees an empty dir.
#   `docker volume ls -q --filter name=^<prefix>`  lists vols/ matching the prefix
#   `docker volume rm <name>`                      removes it (exit 1 when FAKE_DOCKER_RM_FAIL=1)
#   anything else                                  exits 0
# FAKE_NPM_RC is the exit code of the `npm` stub (default 0); FAKE_PROBE_RC, when set, is the exit
# code of every container run that carries the empty-volume probe.

install_fake_docker() {
  local stub="$1" state="$2"
  mkdir -p "$stub" "$state/vols" "$state/app"
  : > "$state/docker.calls"
  : > "$state/install.calls"
  cat > "$stub/docker" <<EOF
#!/usr/bin/env bash
STATE="$state"
all="\$*"
printf '%s\n' "\${all//\$'\n'/ }" >> "\$STATE/docker.calls"
args=("\$@")
if [ "\${args[0]:-}" = volume ]; then
  case "\${args[1]:-}" in
    ls)
      prefix=""
      for a in "\${args[@]}"; do case "\$a" in name=*) prefix="\${a#name=^}" ;; esac; done
      for d in "\$STATE"/vols/*; do
        [ -d "\$d" ] || continue
        n="\$(basename "\$d")"
        case "\$n" in "\$prefix"*) echo "\$n" ;; esac
      done
      exit 0 ;;
    rm)
      [ "\${FAKE_DOCKER_RM_FAIL:-}" = 1 ] && { echo "volume in use" >&2; exit 1; }
      rm -r "\$STATE/vols/\${args[2]}"
      exit \$? ;;
  esac
  exit 0
fi
[ "\${args[0]:-}" = compose ] || exit 0

# the last -f naming a crew override, and the index of the compose subcommand
override=""
i=1
while [ "\$i" -lt "\${#args[@]}" ]; do
  case "\${args[\$i]}" in
    -f) case "\${args[\$((i + 1))]}" in *crew-compose.override.yml) override="\${args[\$((i + 1))]}" ;; esac; i=\$((i + 2)) ;;
    -p|--project-name|--project-directory|--env-file|--profile) i=\$((i + 2)) ;;
    -*) i=\$((i + 1)) ;;
    *) break ;;
  esac
done
[ "\${args[\$i]:-}" = run ] || exit 0
i=\$((i + 1))
entrypoint=""
while [ "\$i" -lt "\${#args[@]}" ]; do
  case "\${args[\$i]}" in
    --entrypoint) entrypoint="\${args[\$((i + 1))]}"; i=\$((i + 2)) ;;
    -*) i=\$((i + 1)) ;;
    *) break ;;
  esac
done
i=\$((i + 1))   # the service
cmd=("\${args[@]:\$i}")
[ -z "\$entrypoint" ] || cmd=("\$entrypoint" "\${cmd[@]}")

# map the override's volumes into the fake /opt/app
if [ -n "\$override" ] && [ -f "\$override" ]; then
  while IFS= read -r line; do
    if [[ "\$line" =~ ^[[:space:]]+-[[:space:]]+(wt_[A-Za-z0-9_]+):/opt/app/(.+)\$ ]]; then
      name="\${BASH_REMATCH[1]}"; rel="\${BASH_REMATCH[2]}"
      mkdir -p "\$STATE/vols/\$name" "\$(dirname "\$STATE/app/\$rel")"
      ln -sfn "\$STATE/vols/\$name" "\$STATE/app/\$rel"
    fi
  done < "\$override"
fi

case "\$all" in *"exit 7"*) [ -z "\${FAKE_PROBE_RC:-}" ] || exit "\$FAKE_PROBE_RC" ;; esac
out=()
for a in "\${cmd[@]}"; do out+=("\${a//\/opt\/app/\$STATE/app}"); done
cd "\$STATE/app" || exit 1
exec "\${out[@]}"
EOF
  chmod +x "$stub/docker"
  cat > "$stub/npm" <<EOF
#!/usr/bin/env bash
printf 'npm %s\n' "\$*" >> "$state/install.calls"
[ "\${FAKE_NPM_RC:-0}" = 0 ] || { echo "npm ERR! boom" >&2; exit "\$FAKE_NPM_RC"; }
mkdir -p node_modules && : > node_modules/pkg
EOF
  chmod +x "$stub/npm"
}
