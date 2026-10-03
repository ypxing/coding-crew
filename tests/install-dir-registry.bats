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

@test "install-dir: the reviewer's assets are where crew-afk's orchestrator asset puts roles/reviewer" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  dest="$(jq -r '.skills["crew-afk"].assets.dest' "$REPO_ROOT/registry.json")"
  [ "$(asset_dir reviewer)" = "${dest#.coding-crew/}/roles/reviewer" ]
}

@test "install-dir: dep-install's scripts are where install.sh puts dep-install's" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  dest="$(jq -r '.skills["dep-install"].assets.dest' "$REPO_ROOT/registry.json")"
  [ "$(asset_dir depInstall)" = "${dest#.coding-crew/}" ]
}

@test "install-dir: solve-issue's scripts are where install.sh puts solve-issue's" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  dest="$(jq -r '.skills["solve-issue"].assets.dest' "$REPO_ROOT/registry.json")"
  [ "$(asset_dir solveIssue)" = "${dest#.coding-crew/}" ]
}

@test "install-dir: to-issues' scripts are where install.sh puts to-issues'" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  dest="$(jq -r '.skills["to-issues"].assets.dest' "$REPO_ROOT/registry.json")"
  [ "$(asset_dir toIssues)" = "${dest#.coding-crew/}" ]
}

@test "install-dir: write-pr's SKILL.md is where install.sh puts write-pr's assets" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  dest="$(jq -r '.skills["write-pr"].assets.dest' "$REPO_ROOT/registry.json")"
  [ "$(asset_dir writePr)" = "${dest#.coding-crew/}" ]
}

@test "install-dir: crew-afk installs write-pr, whose SKILL.md its PR writer follows" {
  jq -e '.skills["crew-afk"].deps | index("write-pr")' "$REPO_ROOT/registry.json" >/dev/null
}

@test "install-dir: crew-afk installs to-issues, whose lint-issues.sh its preflight runs" {
  jq -e '.skills["crew-afk"].deps | index("to-issues")' "$REPO_ROOT/registry.json" >/dev/null
}

@test "install-dir: crew-afk's orchestrator sits one level under the same .coding-crew/" {
  # CREW_INSTALL_DIR defaults to the parent of main.mjs's own dir.
  dest="$(jq -r '.skills["crew-afk"].assets.dest' "$REPO_ROOT/registry.json")"
  [ "$(dirname "$dest")" = ".coding-crew" ]
}
