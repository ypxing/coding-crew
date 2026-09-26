#!/usr/bin/env bats
# install-dir-registry.bats — orchestrator/lib/install-dir.mjs's ASSET_DIRS against registry.json.
#
# A run resolves CREW_INSTALL_DIR once and reads every asset at a fixed sub-path of it. Those
# sub-paths are a constant, not a runtime registry read (registry.json is not installed into
# consuming repos), so this is what keeps the constant equal to where install.sh puts them.

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
}

asset_dir() {
  (cd "$REPO_ROOT" && node --input-type=module -e \
    "import('./orchestrator/lib/install-dir.mjs').then((m) => console.log(m.ASSET_DIRS['$1']))")
}

@test "install-dir: the reviewer's assets are where install.sh puts crew-reviewer's" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  dest="$(jq -r '.agents["crew-reviewer"].install.assets.dest' "$REPO_ROOT/registry.json")"
  [ "$(asset_dir reviewer)" = "${dest#.coding-crew/}" ]
}

@test "install-dir: dep-install's scripts are where install.sh puts dep-install's" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  dest="$(jq -r '.skills["dep-install"].assets.dest' "$REPO_ROOT/registry.json")"
  [ "$(asset_dir depInstall)" = "${dest#.coding-crew/}" ]
}

@test "install-dir: crew-afk's orchestrator sits one level under the same .coding-crew/" {
  # CREW_INSTALL_DIR defaults to the parent of main.mjs's own dir.
  dest="$(jq -r '.skills["crew-afk"].assets.dest' "$REPO_ROOT/registry.json")"
  [ "$(dirname "$dest")" = ".coding-crew" ]
}
