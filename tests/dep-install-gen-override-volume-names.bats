#!/usr/bin/env bats

# gen-override.sh: the dependency volume names, `wt_<proj>_<owner4>_<eco>_<dir>_<lock8>`.
#
# <owner4> hashes the host and the checkout's path, so two worktrees, clones or hosts never share a
# volume; <lock8> makes a changed lockfile name fresh volumes. Each is an explicit top-level `name:`,
# so the compose project name does not rename it.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/lib/checks"
SCRIPT="$SCRIPTS_DIR/gen-override.sh"

setup() {
  PARENT=$(mktemp -d)
}

teardown() {
  [ -n "${PARENT:-}" ] && rm -rf "$PARENT"
  return 0
}

# fixture <dir> — a minimal node project (one manifest, one lockfile) in <dir>, a git checkout to hold its override
fixture() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  printf 'services:\n  app:\n    build: .\n    volumes:\n      - .:/opt/app\n' > "$dir/docker-compose.yml"
  echo '{"name":"fixture"}' > "$dir/package.json"
  echo '{"lock":"A"}' > "$dir/package-lock.json"
}

# override <project-root> — writes the override and prints it
override() {
  bash "$SCRIPT" --project-root "$1" >/dev/null || return 1
  cat "$1/.git/crew-compose.override.yml"
}

# names <project-root> — the dependency volume names the override carries, one per line
names() {
  override "$1" | sed -n 's/^    name: //p'
}

@test "every dependency volume is named wt_<proj>_<owner4>_<eco>_<dir>_<lock8>, as an explicit name:" {
  fixture "$PARENT/product-services"
  mkdir -p "$PARENT/product-services/packages/web"
  echo '{"name":"web"}' > "$PARENT/product-services/packages/web/package.json"

  run names "$PARENT/product-services"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  root="${lines[0]}"
  [[ "$root" =~ ^wt_product_services_[0-9a-f]{4}_nm_root_[0-9a-f]{8}$ ]]
  [[ "${lines[1]}" =~ ^wt_product_services_[0-9a-f]{4}_nm_packages_web_[0-9a-f]{8}$ ]]
  # one install writes every volume, so every name carries the same lock hash
  [ "${root##*_}" = "${lines[1]##*_}" ]
  # the services mount the same name
  run override "$PARENT/product-services"
  grep -qx "      - $root:/opt/app/node_modules" <<<"$output"
}

@test "<owner4> differs for two checkouts with the same basename, and is stable for one" {
  fixture "$PARENT/a/proj"
  fixture "$PARENT/b/proj"
  a="$(names "$PARENT/a/proj" | head -1)"
  b="$(names "$PARENT/b/proj" | head -1)"
  [ -n "$a" ] && [ "$a" != "$b" ]
  [ "$(names "$PARENT/a/proj" | head -1)" = "$a" ]
}

@test "<lock8> changes when the lockfile changes" {
  fixture "$PARENT/proj"
  before="$(names "$PARENT/proj")"
  echo '{"lock":"B"}' > "$PARENT/proj/package-lock.json"
  [ "$(names "$PARENT/proj")" != "$before" ]
}

@test "<lock8> changes when the manifest changes" {
  fixture "$PARENT/proj"
  before="$(names "$PARENT/proj")"
  echo '{"name":"fixture","dependencies":{"left-pad":"1"}}' > "$PARENT/proj/package.json"
  [ "$(names "$PARENT/proj")" != "$before" ]
}

@test "<lock8> changes when a manifest appears in a sub-package, for the root volume too" {
  fixture "$PARENT/proj"
  before="$(names "$PARENT/proj" | grep nm_root_)"
  mkdir -p "$PARENT/proj/packages/web"
  echo '{"name":"web"}' > "$PARENT/proj/packages/web/package.json"
  after="$(names "$PARENT/proj" | grep nm_root_)"
  # one install writes every volume, so all of them name the new hash
  [ -n "$after" ] && [ "$after" != "$before" ]
}

@test "<lock8> ignores unrelated files" {
  fixture "$PARENT/one"
  before="$(names "$PARENT/one")"
  echo 'console.log(1)' > "$PARENT/one/index.js"
  echo '# docs' > "$PARENT/one/README.md"
  [ "$(names "$PARENT/one")" = "$before" ]
}

@test "<lock8> and the volume names ignore manifests under dot-directories, as the manifest scan does" {
  fixture "$PARENT/proj"
  before="$(names "$PARENT/proj")"
  mkdir -p "$PARENT/proj/.output/server" "$PARENT/proj/.claude/worktrees/x" "$PARENT/proj/packages/.cache/y"
  echo '{"name":"built"}' > "$PARENT/proj/.output/server/package.json"
  echo '{"name":"other"}' > "$PARENT/proj/.claude/worktrees/x/package.json"
  echo '{"name":"cached"}' > "$PARENT/proj/packages/.cache/y/package.json"
  [ "$(names "$PARENT/proj")" = "$before" ]
  [ "$(bash "$SCRIPT" --project-root "$PARENT/proj" --query manifest-dirs)" = "$PARENT/proj" ]
}

@test "the volume key and the explicit name are the same, and the git hooks/info volumes are not hashed" {
  fixture "$PARENT/proj"
  run override "$PARENT/proj"
  [ "$status" -eq 0 ]
  name="$(sed -n 's/^    name: //p' <<<"$output" | head -1)"
  grep -qx "  $name:" <<<"$output"
  grep -qx "  wt_proj_git_hooks:" <<<"$output"
  grep -qx "  wt_proj_git_info:" <<<"$output"
}
