#!/usr/bin/env bats

# prune-volumes.sh — docker-install.sh's call after writing an override: it removes the repo's
# dependency volumes no live checkout's override names. `docker` is a stub that logs `volume rm`.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"
SCRIPT="$SCRIPTS_DIR/prune-volumes.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  WORK=$(cd "$(mktemp -d)" && pwd -P)
  git init -q "$WORK"
  printf 'services:\n  app:\n    volumes: [".:/opt/app"]\n' > "$WORK/docker-compose.yml"
  echo '{"name":"fixture"}' > "$WORK/package.json"
  echo '{}' > "$WORK/package-lock.json"
  git -C "$WORK" add -A
  git -C "$WORK" -c user.name=t -c user.email=t@t commit -qm init
  mkdir -p "$TEMP_DIR/stub"
  # rm fails for a volume listed in in-use, as docker refuses one a container has mounted
  cat > "$TEMP_DIR/stub/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TEMP_DIR/docker.calls"
[ "\$1 \$2" = "volume rm" ] || exit 0
! grep -qxF "\${@: -1}" "$TEMP_DIR/in-use" 2>/dev/null
EOF
  chmod +x "$TEMP_DIR/stub/docker"
  export PATH="$TEMP_DIR/stub:$PATH"
}

teardown() {
  rm -rf "$TEMP_DIR" "$WORK" "$WORK-wt"
}

_volumes() { sed -nE 's/^    name: (wt_[^[:space:]]+)$/\1/p' "$1/crew-compose.override.yml"; }
_install() { # <checkout> — what docker-install.sh does: write the override, then prune
  bash "$SCRIPTS_DIR/gen-override.sh" --project-root "$1" >/dev/null
  bash "$SCRIPT" --project-root "$1"
}
_removed() { grep -c "^volume rm -f $1\$" "$TEMP_DIR/docker.calls" 2>/dev/null || true; }

@test "a lockfile change removes the checkout's volumes from before it and keeps the new ones" {
  _install "$WORK"
  old=$(_volumes "$WORK/.git")
  echo '{"lockfileVersion":3}' > "$WORK/package-lock.json"
  _install "$WORK"
  new=$(_volumes "$WORK/.git")
  [ "$old" != "$new" ]
  [ "$(_removed "$old")" = 1 ]
  [ "$(_removed "$new")" = 0 ]
  [ "$(cat "$WORK/.git/crew-volumes")" = "$new" ]
}

@test "a removed worktree's volumes go on the next install; the main checkout's and other repos' stay" {
  git -C "$WORK" worktree add -q --detach "$WORK-wt"
  _install "$WORK"
  _install "$WORK-wt"
  main=$(_volumes "$WORK/.git")
  wt=$(_volumes "$(git -C "$WORK-wt" rev-parse --path-format=absolute --git-dir)")
  [ "$main" != "$wt" ]
  git -C "$WORK" worktree remove "$WORK-wt"
  : > "$TEMP_DIR/docker.calls"
  _install "$WORK"
  [ "$(_removed "$wt")" = 1 ]
  [ "$(_removed "$main")" = 0 ]
  [ "$(grep -c '^volume rm' "$TEMP_DIR/docker.calls")" = 1 ]
}

@test "a volume a container still has mounted stays listed for the next call" {
  _install "$WORK"
  old=$(_volumes "$WORK/.git")
  echo "$old" > "$TEMP_DIR/in-use"
  echo '{"lockfileVersion":3}' > "$WORK/package-lock.json"
  _install "$WORK"
  grep -qxF "$old" "$WORK/.git/crew-volumes"
  rm "$TEMP_DIR/in-use"
  _install "$WORK"
  ! grep -qxF "$old" "$WORK/.git/crew-volumes"
}
