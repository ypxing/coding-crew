#!/usr/bin/env bats

# gen-override.sh: the dependency volume names, `wt_<proj>_<owner4>_<eco>_<dir>_<lock8>`.
#
# <owner4> keeps another clone's, host's or sandbox's volumes out of reach (cleanup-worktrees.sh
# removes only this owner's); <lock8> makes a worktree with different lockfiles name different
# volumes, and one with identical lockfiles name the same. Each is an explicit top-level `name:`,
# so neither the compose project name nor the worktree's directory renames it.

SCRIPTS_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/dep-install/scripts"
SCRIPT="$SCRIPTS_DIR/gen-override.sh"

setup() {
  unset MAIN_ROOT
  PARENT=$(mktemp -d)
}

teardown() {
  [ -n "${PARENT:-}" ] && rm -rf "$PARENT"
  return 0
}

# fixture <dir> — a minimal node project (one manifest, one lockfile) in <dir>
fixture() {
  local dir="$1"
  mkdir -p "$dir"
  printf 'services:\n  app:\n    build: .\n    volumes:\n      - .:/opt/app\n' > "$dir/docker-compose.yml"
  echo '{"name":"fixture"}' > "$dir/package.json"
  echo '{"lock":"A"}' > "$dir/package-lock.json"
}

# names <project-root> <main-root> — the dependency volume names the override carries, one per line
names() {
  bash "$SCRIPT" --project-root "$1" --main-root "${2:-$1}" --dry-run | sed -n 's/^    name: //p'
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
  run bash "$SCRIPT" --project-root "$PARENT/product-services" --main-root "$PARENT/product-services" --dry-run
  grep -qx "      - $root:/opt/app/node_modules" <<<"$output"
}

@test "<owner4> differs for two MAIN_ROOTs with the same basename" {
  fixture "$PARENT/a/proj"
  fixture "$PARENT/b/proj"
  a="$(names "$PARENT/a/proj" | head -1)"
  b="$(names "$PARENT/b/proj" | head -1)"
  [ -n "$a" ] && [ "$a" != "$b" ]
  [ "$(bash "$SCRIPT" --project-root "$PARENT/a/proj" --main-root "$PARENT/a/proj" --query owner-prefix)" != \
    "$(bash "$SCRIPT" --project-root "$PARENT/b/proj" --main-root "$PARENT/b/proj" --query owner-prefix)" ]
  # but the same MAIN_ROOT names the same owner, whichever worktree asks
  [ "$(bash "$SCRIPT" --project-root "$PARENT/a/proj" --main-root "$PARENT/a/proj" --query owner-prefix)" = \
    "$(bash "$SCRIPT" --project-root "$PARENT/b/proj" --main-root "$PARENT/a/proj" --query owner-prefix)" ]
}

@test "--query owner-prefix is the prefix every dependency volume name starts with, and needs no compose file" {
  fixture "$PARENT/proj"
  prefix="$(bash "$SCRIPT" --project-root "$PARENT/proj" --main-root "$PARENT/proj" --query owner-prefix)"
  [[ "$prefix" =~ ^wt_proj_[0-9a-f]{4}_$ ]]
  [[ "$(names "$PARENT/proj" | head -1)" == "$prefix"* ]]

  rm -f "$PARENT/proj/docker-compose.yml"
  run bash "$SCRIPT" --project-root "$PARENT/proj" --main-root "$PARENT/proj" --query owner-prefix
  [ "$status" -eq 0 ]
  [ "$output" = "$prefix" ]
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

@test "<lock8> is the same for identical lockfiles in two worktrees, and ignores unrelated files" {
  fixture "$PARENT/one"
  fixture "$PARENT/two"
  mkdir -p "$PARENT/main"
  [ "$(names "$PARENT/one" "$PARENT/main")" = "$(names "$PARENT/two" "$PARENT/main")" ]
  echo 'console.log(1)' > "$PARENT/one/index.js"
  echo '# docs' > "$PARENT/one/README.md"
  [ "$(names "$PARENT/one" "$PARENT/main")" = "$(names "$PARENT/two" "$PARENT/main")" ]
}

@test "the volume key and the explicit name are the same, and the git hooks/info volumes are not hashed" {
  fixture "$PARENT/proj"
  git -C "$PARENT/proj" init -q
  run bash "$SCRIPT" --project-root "$PARENT/proj" --main-root "$PARENT/proj" --dry-run
  [ "$status" -eq 0 ]
  name="$(sed -n 's/^    name: //p' <<<"$output" | head -1)"
  grep -qx "  $name:" <<<"$output"
  grep -qx "  wt_proj_git_hooks:" <<<"$output"
  grep -qx "  wt_proj_git_info:" <<<"$output"
}
