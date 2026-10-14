#!/usr/bin/env bats

# install.sh and uninstall.sh behaviour. Tests that only read what an install leaves behind read
# the installs setup_file makes; the rest install into their own TEMP_DIR.

load helpers/platforms
load helpers/shared-install

setup_file() {
  shared_install all
  shared_install to-issues claude --skill to-issues
  bg_wait
}

setup() {
  ALL="$(shared_installed all)"
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "the manifest records the platforms, the skills and the libraries, with no versions" {
  local m="$ALL/.coding-crew/manifest.json"
  [ -f "$m" ]
  [ "$(jq -c '.platforms' "$m")" = '["all"]' ]
  [ "$(jq -c '.skills' "$m")" = "$(jq -c '.skills | keys' "$SCRIPT_DIR/registry.json")" ]
  [ "$(jq -c '.libs' "$m")" = '["checks","git-workflow","tracker"]' ]
  ! grep -q '"version"' "$m"
}

@test "to-issues installs references/ beside SKILL.md for every platform" {
  local skill_md dir count=0
  while IFS= read -r skill_md; do
    dir=$(dirname "$skill_md")
    [ ! -e "$dir/references/github-publish.md" ]
    [ ! -e "$dir/references/rerun.md" ]
    [ -f "$dir/references/expand-contract.md" ]
    count=$((count + 1))
  done < <(find "$ALL" -path '*/skills/to-issues/SKILL.md')
  [ "$count" -eq "${#PLATFORMS[@]}" ]
}

# ─── an installed tree is an exact copy of what the install wrote ────────────
#
# No hand list of retired files: whatever a skill root or asset tree holds that this
# run did not write is removed, then any directory left empty.

@test "--update reinstalls every listed skill though nothing changed, and uninstalls one the registry dropped" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  local dir="$TEMP_DIR/.claude/skills/to-issues" m="$TEMP_DIR/.coding-crew/manifest.json"
  echo "raw gh publish path" > "$dir/references/github-publish.md"
  mkdir -p "$TEMP_DIR/.claude/skills/gone-skill"
  echo old > "$TEMP_DIR/.claude/skills/gone-skill/SKILL.md"
  jq '.skills += ["gone-skill"]' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [[ "$output" == *"removed .claude/skills/to-issues/"* ]]
  [[ "$output" == *"gone-skill: removed from the registry — uninstalled"* ]]
  [ ! -e "$dir/references/github-publish.md" ]
  [ -f "$dir/SKILL.md" ]
  [ -f "$dir/references/expand-contract.md" ]
  [ -f "$dir/scripts/tracker/cli.mjs" ]
  [ ! -e "$TEMP_DIR/.claude/skills/gone-skill" ]
  [ "$(jq -c '.skills' "$m")" = '["to-issues"]' ]
  [ "$(jq -c '.libs' "$m")" = '["tracker"]' ]
}

@test "--update reinstalls for every platform installed into the same root, not only the last one" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd >/dev/null
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill tdd >/dev/null
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -f "$TEMP_DIR/$(platform_field claude projectSkills)/tdd/SKILL.md" ]
  [ -f "$TEMP_DIR/$(platform_field codex projectSkills)/tdd/SKILL.md" ]
  [ "$(jq -c '.platforms' "$TEMP_DIR/.coding-crew/manifest.json")" = '["claude","codex"]' ]
}

# What today's main left behind: per-skill versions in the manifest, scripts copied into each skill,
# and a skill (crew-address-findings) the registry no longer has.
_old_main_install() {
  local root="$1"
  mkdir -p "$root/.claude/skills/tdd" "$root/.claude/skills/crew-address-findings/scripts" "$root/.claude/skills/solve-issue/scripts" "$root/.coding-crew"
  echo old > "$root/.claude/skills/tdd/SKILL.md"
  echo old > "$root/.claude/skills/crew-address-findings/SKILL.md"
  echo old > "$root/.claude/skills/crew-address-findings/scripts/triage.sh"
  echo old > "$root/.claude/skills/solve-issue/SKILL.md"
  echo old > "$root/.claude/skills/solve-issue/scripts/run-checks.sh"
  cat > "$root/.coding-crew/manifest.json" <<'JSON'
{
  "source": "git@github.com:ypxing/coding-crew.git",
  "source_sha": "0000000",
  "installed_at": "2026-10-01T00:00:00Z",
  "platform": "claude",
  "skills": {
    "crew-address-findings": { "version": "1.4.0" },
    "solve-issue": { "version": "1.16.0" },
    "tdd": { "version": "1.2.5" }
  }
}
JSON
}

@test "--update over an install made by today's main uninstalls the skills it lists and leaves a working new layout" {
  _old_main_install "$TEMP_DIR"
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -e "$TEMP_DIR/.claude/skills/crew-address-findings" ]
  [[ "$output" == *"crew-address-findings: removed from the registry — uninstalled"* ]]
  [ ! -e "$TEMP_DIR/.claude/skills/solve-issue/scripts/run-checks.sh" ]
  [ -f "$TEMP_DIR/.claude/skills/solve-issue/scripts/checks/run-checks.sh" ]
  [ -f "$TEMP_DIR/.claude/skills/tdd/SKILL.md" ]
  [ "$(cat "$TEMP_DIR/.claude/skills/tdd/SKILL.md")" != old ]
  cd "$TEMP_DIR"
  git init -q .
  run node .claude/skills/solve-issue/scripts/tracker/cli.mjs config
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracker="* ]]
  local m="$TEMP_DIR/.coding-crew/manifest.json"
  [ "$(jq -r '.skills | type' "$m")" = array ]
  [ "$(jq -r '.skills | index("crew-address-findings")' "$m")" = null ]
  [ "$(jq -r '.skills | index("dep-install") != null' "$m")" = true ]
  ! grep -q '"version"' "$m"
}

@test "a plain re-install prunes a planted file and the directory it leaves empty, never the skill root" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd >/dev/null
  local dir="$TEMP_DIR/.claude/skills/tdd"
  echo stale > "$dir/stale.md"
  mkdir -p "$dir/old/deeper"
  echo stale > "$dir/old/deeper/gone.md"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd
  [ "$status" -eq 0 ]
  [ ! -e "$dir/stale.md" ]
  [ ! -e "$dir/old" ]
  [ -f "$dir/SKILL.md" ]
  [[ "$output" == *".claude/skills/tdd/stale.md (removed)"* ]]
  [[ "$output" == *".claude/skills/tdd/old/deeper/gone.md (removed)"* ]]
}

@test "the prune keeps every library link a skill's libs names, and drops a planted one" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  echo stale > "$TEMP_DIR/.claude/skills/solve-issue/scripts/retired.sh"
  ln -s ../../../../.coding-crew/lib/nope "$TEMP_DIR/.claude/skills/solve-issue/scripts/nope"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  [ ! -e "$TEMP_DIR/.claude/skills/solve-issue/scripts/retired.sh" ]
  [ ! -L "$TEMP_DIR/.claude/skills/solve-issue/scripts/nope" ]
  local lib
  while IFS= read -r lib; do
    [ -L "$TEMP_DIR/.claude/skills/solve-issue/scripts/$lib" ] || { echo "no $lib link" >&2; return 1; }
  done < <(jq -r '.skills["solve-issue"].libs[]' registry.json)
  [ -x "$TEMP_DIR/.claude/skills/solve-issue/scripts/preflight.sh" ]
}

@test "re-installing prunes a file planted in a library" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill dep-install >/dev/null
  echo "# deleted script" > "$TEMP_DIR/.coding-crew/lib/checks/retired.sh"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill dep-install
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/.coding-crew/lib/checks/retired.sh" ]
  [ -f "$TEMP_DIR/.coding-crew/lib/checks/run.sh" ]
  [[ "$output" == *".coding-crew/lib/checks/retired.sh (removed)"* ]]
}

@test "the prune leaves files outside the skill root and asset dests alone" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd >/dev/null
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill tdd >/dev/null
  echo '{"tracker":{"kind":"local"}}' > "$TEMP_DIR/.coding-crew/config.json"
  echo keep > "$TEMP_DIR/.coding-crew/user-note.md"
  local other
  other=$(dirname "$(find "$TEMP_DIR" -path '*/tdd/SKILL.md' -not -path '*/.claude/*' | head -1)")
  [ -n "$other" ]
  echo keep > "$other/planted.md"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd >/dev/null
  [ -f "$TEMP_DIR/.coding-crew/config.json" ]
  [ -f "$TEMP_DIR/.coding-crew/manifest.json" ]
  [ -f "$TEMP_DIR/.coding-crew/user-note.md" ]
  [ -f "$other/planted.md" ]
}

# _libs_linked <skills-dir> — every installed skill links exactly the libraries its registry libs names.
_libs_linked() {
  local dir="$1" skill want got
  while IFS= read -r skill; do
    want=$(jq -r --arg s "$skill" '.skills[$s].libs // [] | .[]' "$SCRIPT_DIR/registry.json" | LC_ALL=C sort | paste -sd' ' -)
    got=$(find "$dir/$skill/scripts" -mindepth 1 -maxdepth 1 -type l -exec basename {} \; 2>/dev/null | LC_ALL=C sort | paste -sd' ' -)
    [ "$want" = "$got" ] || { echo "$skill links '$got', registry libs '$want'" >&2; return 1; }
  done < <(jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json" | tr -d '\r')
}

@test "a skill reaches a library only through its own scripts/<lib> link, and the libraries are not in skills/" {
  _libs_linked "$ALL/.claude/skills"
  [ -f "$ALL/.claude/skills/solve-issue/scripts/git-workflow/write-commands-cache.sh" ]
  [ -f "$ALL/.claude/skills/add-tests/scripts/git-workflow/discover-commands.sh" ]
  # One source per library, under lib/: none is copied by hand into a skill's source-dir.
  [ ! -e "$SCRIPT_DIR/skills/solve-issue/scripts/run-checks.sh" ]
  [ ! -e "$SCRIPT_DIR/skills/dep-install/scripts" ]
  [ -z "$(find "$SCRIPT_DIR/skills" -name write-commands-cache.sh -o -name cli.mjs)" ]
}

@test "HOME=<tmp> ./install.sh claude installs at user level: skills, one copy of each library, links only where libs names one" {
  local home="$TEMP_DIR/home"
  mkdir -p "$home"
  cd "$SCRIPT_DIR"
  run env -u TARGET_REPO -u CLAUDE_CONFIG_DIR HOME="$home" ./install.sh claude
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  local skills="$home/$(platform_field claude userSkills)" lib
  [ -f "$skills/solve-feature/SKILL.md" ]
  for lib in tracker checks git-workflow; do
    [ -d "$home/.coding-crew/lib/$lib" ] && [ ! -L "$home/.coding-crew/lib/$lib" ] || { echo "no $lib" >&2; return 1; }
  done
  _libs_linked "$skills"
  [ "$(readlink "$skills/solve-feature/scripts/tracker")" = "$home/.coding-crew/lib/tracker" ]

  # From inside a repo, the installed CLI runs through the link.
  mkdir -p "$TEMP_DIR/repo" && git -C "$TEMP_DIR/repo" init -q
  cd "$TEMP_DIR/repo"
  run env HOME="$home" node "$skills/solve-feature/scripts/tracker/cli.mjs" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracker="* ]]
  [[ "$output" == *"configured="* ]]

  cd "$SCRIPT_DIR"
  run env -u TARGET_REPO -u CLAUDE_CONFIG_DIR HOME="$home" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ ! -e "$skills/solve-feature" ]
  [ ! -e "$home/.coding-crew" ]
}

@test "--project <repo> writes the same layout under the repo, every link relative, and a copy of the repo still resolves" {
  local repo="$TEMP_DIR/repo" home="$TEMP_DIR/home" link bad=""
  mkdir -p "$repo" "$home" && git -C "$repo" init -q
  cd "$SCRIPT_DIR"
  run env -u TARGET_REPO HOME="$home" ./install.sh claude --project "$repo"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -z "$(ls -A "$home")" ]
  _libs_linked "$repo/.claude/skills"
  while IFS= read -r link; do
    [[ "$(readlink "$link")" != /* ]] || bad+="$link "
  done < <(find "$repo/.claude/skills" -type l)
  [ -z "$bad" ] || { echo "absolute links: $bad" >&2; return 1; }

  cp -a "$repo" "$TEMP_DIR/moved"
  rm -rf "$repo"
  while IFS= read -r link; do
    [ -e "$link" ] || bad+="$link "
  done < <(find "$TEMP_DIR/moved/.claude/skills" -type l)
  [ -z "$bad" ] || { echo "dangling after the copy: $bad" >&2; return 1; }
  cd "$TEMP_DIR/moved"
  run node .claude/skills/to-issues/scripts/tracker/cli.mjs config
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracker="* ]]

  cd "$SCRIPT_DIR"
  run ./uninstall.sh --project "$TEMP_DIR/moved"
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/moved/.claude/skills" ]
  [ ! -e "$TEMP_DIR/moved/.coding-crew" ]
}

@test "no installed SKILL.md, reference or script names an old install path, a sibling skill's dir or a placeholder" {
  local hits
  hits=$(cd "$ALL" && find . \( -name SKILL.md -o -path '*/references/*' -o -path '*/scripts/*' -o -path './.coding-crew/lib/*' \) -type f -print0 \
    | xargs -0 grep -nF -e '.coding-crew/tracker/' -e '.coding-crew/dep-install/' -e '.coding-crew/solve-issue/' \
        -e '../solve-issue/' -e '../dep-install/' -e '{{' || true)
  [ -z "$hits" ] || { echo "$hits" >&2; return 1; }
}

@test "uninstall --skill removes a library only once no skill left in the manifest uses it" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skills tdd,to-prd,to-issues >/dev/null
  local m="$TEMP_DIR/.coding-crew/manifest.json"
  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill to-prd >/dev/null
  [ -d "$TEMP_DIR/.coding-crew/lib/tracker" ]
  [ "$(jq -c '.skills' "$m")" = '["tdd","to-issues"]' ]
  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill to-issues >/dev/null
  [ ! -e "$TEMP_DIR/.coding-crew/lib" ]
  [ "$(jq -c '.skills' "$m")" = '["tdd"]' ]
  [ "$(jq -c '.libs' "$m")" = '[]' ]
}

@test "direct install is idempotent (produces identical output on repeat runs)" {
  local temp1="$TEMP_DIR/first"
  local temp2="$TEMP_DIR/second"
  mkdir -p "$temp1" "$temp2"
  cd "$SCRIPT_DIR"
  TARGET_REPO="$temp1" ./install.sh claude --skill tdd > /dev/null
  TARGET_REPO="$temp2" ./install.sh claude --skill tdd > /dev/null

  cmp -s "$temp1/.claude/skills/tdd/SKILL.md" "$temp2/.claude/skills/tdd/SKILL.md"
}

@test "registry.json has no crew: strings (colon-form removed)" {
  cd "$SCRIPT_DIR"

  # registry.json must be valid JSON
  run jq . registry.json
  [ "$status" -eq 0 ]

  # No crew: strings anywhere in registry.json
  ! grep -q 'crew:' registry.json
}

@test "registry.json has no agents" {
  cd "$SCRIPT_DIR"
  run jq -r 'has("agents")' registry.json
  [ "$output" = "false" ]
}

@test "registry.json skill keys solve-feature, crew-afk and crew-grill are present; crew-address-findings and crew-plan are not" {
  cd "$SCRIPT_DIR"

  run jq -r '.skills | keys[]' registry.json
  [ "$status" -eq 0 ]
  echo "$output" | grep -qxF "solve-feature"
  echo "$output" | grep -qxF "crew-afk"
  echo "$output" | grep -qxF "crew-grill"
  ! echo "$output" | grep -qxF "crew-address-findings"
  # tdd must exist without crew- prefix
  [[ "$output" == *"tdd"* ]]
  # crew-tdd must not be present
  ! echo "$output" | grep -qxF "crew-tdd"
  # crew-plan must not be present (renamed to crew-grill)
  ! echo "$output" | grep -qxF "crew-plan"
}

@test "reinstalling modified skill reports the update without a diff body" {
  cd "$SCRIPT_DIR"

  # First install
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null

  # Modify the installed file
  echo "# Modified by test" >> "$TEMP_DIR/.claude/skills/tdd/SKILL.md"

  # Reinstall and capture output
  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skill tdd"

  # The changed file is named once, marked (updated)
  [[ "$output" =~ "SKILL.md (updated)" ]]
  # No diff body: no unified-diff headers or hunk markers
  [[ ! "$output" =~ "+++ incoming" ]]
  [[ ! "$output" =~ "@@" ]]
}

@test "--skills is the full desired set: a name dropped from the list is uninstalled" {
  cd "$SCRIPT_DIR"

  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skills tdd,to-issues,to-prd > /dev/null
  [ -d "$TEMP_DIR/.claude/skills/to-prd" ]
  run jq -r '.skills | index("to-prd") != null' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$output" == "true" ]

  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skills tdd,to-issues"

  [[ "$output" =~ "pruning to-prd" ]]
  [ ! -d "$TEMP_DIR/.claude/skills/to-prd" ]
  [ -d "$TEMP_DIR/.claude/skills/tdd" ]
  [ -d "$TEMP_DIR/.claude/skills/to-issues" ]
  run jq -r '.skills | index("to-prd") != null' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$output" == "false" ]
}

@test "reinstalling an unmodified install reports no updates" {
  cd "$SCRIPT_DIR"

  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-feature > /dev/null

  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skill solve-feature"

  # Nothing changed on disk, so nothing should be reported as updated
  [[ ! "$output" =~ "(updated)" ]]
}

# ── tracker config: legacy issue-tracker.md → config.json ──────────────────────
# The fixtures are copies of this repo's own pre-migration files.

TRACKER_FIXTURES="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/tracker-config"

_legacy_tracker_repo() {  # <issue-tracker.md fixture> [config.json fixture]
  mkdir -p "$TEMP_DIR/.coding-crew/docs/templates/trackers"
  cp "$TRACKER_FIXTURES/$1" "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
  cp "$SCRIPT_DIR/lib/tracker/docs/local.md" "$SCRIPT_DIR/lib/tracker/docs/github.md" "$TEMP_DIR/.coding-crew/docs/templates/trackers/"
  [ -z "${2:-}" ] || cp "$TRACKER_FIXTURES/$2" "$TEMP_DIR/.coding-crew/config.json"
}

_assert_legacy_tracker_files_gone() {
  [ ! -e "$TEMP_DIR/.coding-crew/docs/issue-tracker.md" ]
  [ ! -e "$TEMP_DIR/.coding-crew/docs/templates/trackers" ]
  [ ! -e "$TEMP_DIR/.coding-crew/docs" ]
}

@test "install migrates a legacy github issue-tracker.md into config.json, keeping afk, and deletes the legacy files" {
  _legacy_tracker_repo issue-tracker-github.md config-afk-only.json
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd
  [ "$status" -eq 0 ]
  run jq -c --slurpfile afk "$TRACKER_FIXTURES/config-afk-only.json" \
    '. == ($afk[0] + {tracker: {kind: "github"}})' "$TEMP_DIR/.coding-crew/config.json"
  [ "$output" = "true" ]
  _assert_legacy_tracker_files_gone
}

@test "install --update migrates a legacy github issue-tracker.md into config.json and deletes the legacy files" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null
  _legacy_tracker_repo issue-tracker-github.md config-afk-only.json
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  run jq -c --slurpfile afk "$TRACKER_FIXTURES/config-afk-only.json" \
    '. == ($afk[0] + {tracker: {kind: "github"}})' "$TEMP_DIR/.coding-crew/config.json"
  [ "$output" = "true" ]
  _assert_legacy_tracker_files_gone
}

@test "install migrates a legacy issue-tracker.md without front matter to kind local" {
  _legacy_tracker_repo issue-tracker-no-front-matter.md
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null
  run jq -c . "$TEMP_DIR/.coding-crew/config.json"
  [ "$output" = '{"tracker":{"kind":"local"}}' ]
  _assert_legacy_tracker_files_gone
}

@test "install keeps an existing tracker section unchanged and still deletes the legacy files" {
  _legacy_tracker_repo issue-tracker-github.md
  printf '{"tracker": {"kind": "local"}, "afk": {}}\n' > "$TEMP_DIR/.coding-crew/config.json"
  local before; before=$(cat "$TEMP_DIR/.coding-crew/config.json")
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null
  [ "$(cat "$TEMP_DIR/.coding-crew/config.json")" = "$before" ]
  _assert_legacy_tracker_files_gone
}

@test "install leaves a legacy front matter naming repo: in place and says repo is no longer supported" {
  _legacy_tracker_repo issue-tracker-github.md config-afk-only.json
  printf -- '---\ntracker: github\nrepo: owner/name\n---\n' > "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
  local doc_before cfg_before
  doc_before=$(cat "$TEMP_DIR/.coding-crew/docs/issue-tracker.md")
  cfg_before=$(cat "$TEMP_DIR/.coding-crew/config.json")
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd
  [ "$status" -eq 0 ]
  [[ "$output" == *'`repo` is no longer supported'* ]]
  [[ "$output" == *"$TEMP_DIR/.coding-crew/docs/issue-tracker.md"* ]]
  [ "$(cat "$TEMP_DIR/.coding-crew/docs/issue-tracker.md")" = "$doc_before" ]
  [ "$(cat "$TEMP_DIR/.coding-crew/config.json")" = "$cfg_before" ]
}

@test "a fresh install writes no .coding-crew/docs/ and no tracker section, and installs the tracker docs" {
  [ ! -e "$ALL/.coding-crew/docs" ]
  if [ -f "$ALL/.coding-crew/config.json" ]; then
    run jq -e 'has("tracker")' "$ALL/.coding-crew/config.json"
    [ "$status" -ne 0 ]
  fi
  cmp "$SCRIPT_DIR/lib/tracker/docs/local.md" "$ALL/.coding-crew/lib/tracker/docs/local.md"
  cmp "$SCRIPT_DIR/lib/tracker/docs/github.md" "$ALL/.coding-crew/lib/tracker/docs/github.md"
}

@test "install --update overwrites the tracker docs when a source doc changed" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-prd > /dev/null
  echo "stale prose" > "$TEMP_DIR/.coding-crew/lib/tracker/docs/github.md"
  echo "stale prose" > "$TEMP_DIR/.coding-crew/lib/tracker/docs/local.md"
  TARGET_REPO="$TEMP_DIR" ./install.sh --update > /dev/null
  cmp "$SCRIPT_DIR/lib/tracker/docs/local.md" "$TEMP_DIR/.coding-crew/lib/tracker/docs/local.md"
  cmp "$SCRIPT_DIR/lib/tracker/docs/github.md" "$TEMP_DIR/.coding-crew/lib/tracker/docs/github.md"
}

@test "a user-level install deletes the legacy tracker files and writes no tracker section" {
  _legacy_tracker_repo issue-tracker-github.md
  cd "$SCRIPT_DIR"
  HOME="$TEMP_DIR" TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null
  _assert_legacy_tracker_files_gone
  if [ -f "$TEMP_DIR/.coding-crew/config.json" ]; then
    run jq -e 'has("tracker")' "$TEMP_DIR/.coding-crew/config.json"
    [ "$status" -ne 0 ]
  fi
}

@test "install --user is rejected as an unknown argument" {
  cd "$SCRIPT_DIR"
  run ./install.sh --user claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown argument '--user'"* ]]
}

@test "registry.json has no version, scripts, assets, more-assets, docs, retired-agents or retired-scripts key, and every lib is under lib/" {
  cd "$SCRIPT_DIR"
  run jq -r '[paths | .[-1] | strings | select(IN("version", "scripts", "assets", "more-assets", "docs", "retired-agents", "retired-scripts"))] | unique[]' registry.json
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "registry keys: $output" >&2; return 1; }
  [ ! -e tests/registry-version-bump.bats ]
  local lib
  while IFS= read -r lib; do
    [ -d "lib/$lib" ] || { echo "no lib/$lib" >&2; return 1; }
  done < <(jq -r '[.skills[] | (.libs // [])[]] | unique[]' registry.json)
}

@test "install does not create triage-labels.md in target repo" {
  [ -d "$ALL/.coding-crew" ]
  [ ! -f "$ALL/docs/agents/triage-labels.md" ]
}

# ── Windows: jq that emits CRLF ────────────────────────────────────────────────
# Git Bash's jq writes stdout in text mode, so `jq -r '.skills | keys[]'` yields
# "tdd\r". install.sh used to read that straight into a registry lookup, miss, and
# print "Warning: skill 'tdd' not found in registry ... skipping" — exit 0, nothing
# installed. Stub jq the same way so the guard holds on every platform's CI.

_stub_jq_crlf() {  # prints the bin dir holding a CRLF-emitting jq shim
  local bindir="$TEMP_DIR/bin" real
  real=$(command -v jq)
  mkdir -p "$bindir"
  cat > "$bindir/jq" <<STUB
#!/usr/bin/env bash
# awk, not sed: BSD sed does not expand \\r in a replacement.
"$real" "\$@" | awk '{ printf "%s\r\n", \$0 }'
exit \${PIPESTATUS[0]}
STUB
  chmod +x "$bindir/jq"
  echo "$bindir"
}

@test "install survives a jq that emits CRLF (Windows Git Bash)" {
  cd "$SCRIPT_DIR"
  local bindir
  bindir=$(_stub_jq_crlf)

  PATH="$bindir:$PATH" TARGET_REPO="$TEMP_DIR" run ./install.sh pi --skill tdd
  [ "$status" -eq 0 ]
  [[ "$output" != *"not found in registry"* ]]
  [ -f "$TEMP_DIR/.pi/skills/tdd/SKILL.md" ]
  # A \r that survived into a path would install to "tdd?" instead
  run bash -c "ls \"$TEMP_DIR/.pi/skills\" | cat -v"
  [[ "$output" != *'^M'* ]]
}

@test "uninstall removes installed files when jq emits CRLF" {
  cd "$SCRIPT_DIR"
  local bindir
  bindir=$(_stub_jq_crlf)
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill tdd >/dev/null
  [ -f "$TEMP_DIR/.pi/skills/tdd/SKILL.md" ]

  PATH="$bindir:$PATH" run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ ! -d "$TEMP_DIR/.pi" ]
}

# ── Windows: the CR strip must not cost a process per call ─────────────────────
# The wrapper above used to be `command jq "$@" | tr -d '\r'` — three processes per
# lookup (subshell, jq, tr) where one will do. install.sh makes ~1,500 jq calls, and
# Git Bash emulates fork(), so on Windows that pipeline was the single largest cost in
# CI: 27+ minutes for a suite that takes 2 elsewhere. Guard the cheap form.

_jq_wrapper() {  # extracts the jq() wrapper from a script into a sourceable file
  local src="$1" out="$2"
  awk '/^ *jq\(\) \{/,/^ *\}/' "$src" > "$out"
  [ -s "$out" ]
}

@test "every jq wrapper strips CR in-shell instead of spawning tr per call" {
  cd "$SCRIPT_DIR"
  local f
  for f in install.sh uninstall.sh scripts/render-skill.sh; do
    _jq_wrapper "$f" "$TEMP_DIR/wrapper.sh"
    run cat "$TEMP_DIR/wrapper.sh"
    [ "$status" -eq 0 ]
    # A pipeline here is the regression: it re-adds two spawns per lookup.
    [[ "$output" != *"| tr"* ]]
    [[ "$output" == *"//\$'\\r'/"* ]]
    # ...and the wrapper only exists where jq actually appends CR, so a jq that
    # already writes LF is called directly rather than through an extra subshell.
    run grep -c "command jq -rn '\"probe\"'" "$f"
    [ "$output" -eq 1 ]
  done
}

@test "the jq wrapper preserves output, exit status and emptiness" {
  cd "$SCRIPT_DIR"
  _jq_wrapper install.sh "$TEMP_DIR/wrapper.sh"
  printf '{"a":["x","y"]}' > "$TEMP_DIR/j.json"

  cat > "$TEMP_DIR/probe.sh" <<PROBE
source "$TEMP_DIR/wrapper.sh"
echo "lines=\$(jq -r '.a[]' "$TEMP_DIR/j.json" | wc -l | tr -d ' ')"
echo "empty=\$(jq -r '.missing // empty' "$TEMP_DIR/j.json" | wc -l | tr -d ' ')"
jq empty "$TEMP_DIR/nope.json" 2>/dev/null
echo "rc=\$?"
jq -r '.a[0]' "$TEMP_DIR/j.json" >/dev/null
echo "okrc=\$?"
PROBE

  run bash "$TEMP_DIR/probe.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"lines=2"* ]]
  # Not one blank line: a `while read` loop must iterate zero times.
  [[ "$output" == *"empty=0"* ]]
  # jq's own failure still reaches the caller (`if ! jq empty` is a real guard).
  # Match rc=0 on its own line (with leading newline) to avoid matching okrc=0 as a substring.
  [[ "$output" != *$'\nrc=0'* ]]
  [[ "$output" == *"okrc=0"* ]]
}

@test "a fresh install into an empty repo writes the libraries and no .coding-crew/scripts/" {
  [ -f "$ALL/.coding-crew/lib/tracker/cli.mjs" ]
  [ ! -e "$ALL/.coding-crew/scripts" ]
  [ ! -e "$ALL/.coding-crew/tracker" ]
}

# ── the tracker library (.coding-crew/lib/tracker/) ───────────────────────────
# Installed with any skill whose libs names it; mechanism, so always overwritten, and removed by uninstall.

@test "crew-afk installs with its scripts and a tracker link, and its SKILL.md runs nothing outside <skill-dir>" {
  local skill="$ALL/.claude/skills/crew-afk" d
  [ -f "$skill/scripts/crew-afk.sh" ]
  for d in local orca herdr; do [ -f "$skill/scripts/destinations/$d.sh" ] || { echo "no $d" >&2; return 1; }; done
  [ "$(readlink "$skill/scripts/tracker")" = "../../../../.coding-crew/lib/tracker" ]
  [ -f "$skill/scripts/tracker/cli.mjs" ]
  [ -f "$ALL/.claude/skills/solve-feature/SKILL.md" ]
  ! grep -nF -e '{{' -e '.coding-crew' -e '../' "$skill/SKILL.md"
  # Every script path the body names is under <skill-dir>.
  ! grep -nF 'scripts/' "$skill/SKILL.md" | grep -vF '<skill-dir>/scripts/'
}

@test "install of one skill ships the tracker CLI, which runs through the skill's link" {
  local dir; dir="$(shared_installed to-issues)"
  [ -f "$dir/.coding-crew/lib/tracker/cli.mjs" ]
  cd "$dir"
  run node .claude/skills/to-issues/scripts/tracker/cli.mjs prd --feature-slug x
  [ "$status" -eq 3 ]
}

@test "re-running install overwrites the tracker library, dropping files the source no longer has" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  echo "// stale" > "$TEMP_DIR/.coding-crew/lib/tracker/cli.mjs"
  echo "// retired" > "$TEMP_DIR/.coding-crew/lib/tracker/retired.mjs"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  cmp -s "$SCRIPT_DIR/lib/tracker/cli.mjs" "$TEMP_DIR/.coding-crew/lib/tracker/cli.mjs"
  [ ! -e "$TEMP_DIR/.coding-crew/lib/tracker/retired.mjs" ]
}

@test "--update refreshes the tracker library" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  echo "// stale" > "$TEMP_DIR/.coding-crew/lib/tracker/local.mjs"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  cmp -s "$SCRIPT_DIR/lib/tracker/local.mjs" "$TEMP_DIR/.coding-crew/lib/tracker/local.mjs"
}

@test "uninstall removes the libraries, the links and the manifest, and keeps config.json" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  echo '{"tracker":{"kind":"local"}}' > "$TEMP_DIR/.coding-crew/config.json"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/.coding-crew/lib" ]
  [ ! -e "$TEMP_DIR/.claude/skills/to-issues" ]
  [ ! -e "$TEMP_DIR/.coding-crew/manifest.json" ]
  [ -f "$TEMP_DIR/.coding-crew/config.json" ]
}
