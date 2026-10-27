#!/usr/bin/env bats

# install.sh and uninstall.sh behaviour. Tests that only read what an install leaves behind read
# the installs setup_file makes; the rest install into their own TEMP_DIR.

load helpers/platforms
load helpers/shared-install

setup_file() {
  shared_install all
  shared_install to-issues claude --skill to-issues
  shared_install upgrade-deps claude --skill upgrade-deps
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

@test "the manifest records the platforms and the skills, with no versions and no libs" {
  local m="$ALL/.coding-crew/manifest.json"
  [ -f "$m" ]
  [ "$(jq -c '.platforms' "$m")" = '["all"]' ]
  [ "$(jq -c '.skills' "$m")" = "$(jq -c '.skills | keys' "$SCRIPT_DIR/registry.json")" ]
  [ "$(jq 'has("libs")' "$m")" = false ]
  ! grep -q '"version"' "$m"
}

@test "a skill installed alone brings the skills it invokes: to-issues brings to-prd and configure-tracker, upgrade-deps brings to-issues" {
  local dir s
  dir="$(shared_installed to-issues)"
  for s in to-issues to-prd configure-tracker; do
    [ -f "$dir/.claude/skills/$s/SKILL.md" ] || { echo "to-issues: no $s"; return 1; }
  done
  dir="$(shared_installed upgrade-deps)"
  for s in upgrade-deps to-issues dep-install; do
    [ -f "$dir/.claude/skills/$s/SKILL.md" ] || { echo "upgrade-deps: no $s"; return 1; }
  done
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
  [ -f "$TEMP_DIR/.claude/skills/coding-crew-lib/scripts/tracker/cli.mjs" ]
  [ ! -e "$dir/scripts" ]
  [ ! -e "$TEMP_DIR/.claude/skills/gone-skill" ]
  [ "$(jq -c '.skills' "$m")" = '["coding-crew-lib","configure-tracker","to-issues","to-prd"]' ]
  [ "$(jq 'has("libs")' "$m")" = false ]
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

# What an older install.sh left behind: a manifest with one `platform` and skills keyed by name with a
# version each (today's lists `platforms` and skill names only), scripts copied into each skill, a skill's own
# scripts/<lib> library copies (before coding-crew-lib held them), and a skill (crew-address-findings) the registry no longer has.
_old_main_install() {
  local root="$1"
  mkdir -p "$root/.claude/skills/tdd" "$root/.claude/skills/crew-address-findings/scripts" "$root/.claude/skills/solve-issue/scripts" "$root/.coding-crew"
  echo old > "$root/.claude/skills/tdd/SKILL.md"
  echo old > "$root/.claude/skills/crew-address-findings/SKILL.md"
  echo old > "$root/.claude/skills/crew-address-findings/scripts/triage.sh"
  echo old > "$root/.claude/skills/solve-issue/SKILL.md"
  echo old > "$root/.claude/skills/solve-issue/scripts/run-checks.sh"
  mkdir -p "$root/.claude/skills/solve-issue/scripts/tracker" "$root/.claude/skills/solve-issue/scripts/checks"
  echo old > "$root/.claude/skills/solve-issue/scripts/tracker/cli.mjs"
  echo old > "$root/.claude/skills/solve-issue/scripts/checks/run.sh"
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

@test "--update over an install an older install.sh made uninstalls the skills it lists and leaves a working new layout" {
  _old_main_install "$TEMP_DIR"
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -e "$TEMP_DIR/.claude/skills/crew-address-findings" ]
  [[ "$output" == *"crew-address-findings: removed from the registry — uninstalled"* ]]
  [ ! -e "$TEMP_DIR/.claude/skills/solve-issue/scripts/run-checks.sh" ]
  [ ! -e "$TEMP_DIR/.claude/skills/solve-issue/scripts/tracker" ]
  [ ! -e "$TEMP_DIR/.claude/skills/solve-issue/scripts/checks" ]
  [ -f "$TEMP_DIR/.claude/skills/coding-crew-lib/scripts/checks/run-checks.sh" ]
  [ -f "$TEMP_DIR/.claude/skills/tdd/SKILL.md" ]
  [ "$(cat "$TEMP_DIR/.claude/skills/tdd/SKILL.md")" != old ]
  cd "$TEMP_DIR"
  git init -q .
  run node .claude/skills/coding-crew-lib/scripts/tracker/cli.mjs config
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

@test "the prune keeps every library copy coding-crew-lib ships, and drops a planted file, link or per-skill library" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  local dir="$TEMP_DIR/.claude/skills/solve-issue"
  echo stale > "$dir/scripts/retired.sh"
  ln -s ../../../../elsewhere/nope "$dir/scripts/nope"
  mkdir -p "$dir/scripts/checks" && echo old > "$dir/scripts/checks/run.sh"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  [ ! -e "$dir/scripts/retired.sh" ]
  [ ! -L "$dir/scripts/nope" ]
  [ ! -e "$dir/scripts/checks" ]
  diff -r "$SCRIPT_DIR/skills/solve-issue" "$dir"
  diff -r "$SCRIPT_DIR/skills/coding-crew-lib" "$TEMP_DIR/.claude/skills/coding-crew-lib"
  [ -x "$dir/scripts/preflight.sh" ]
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

# _skills_copied <skills-dir> — every installed skill is a byte-for-byte copy of skills/<name>/, links none.
_skills_copied() {
  local dir="$1" skill
  while IFS= read -r skill; do
    diff -r "$SCRIPT_DIR/skills/$skill" "$dir/$skill" >&2 || { echo "$skill is not a copy of skills/$skill" >&2; return 1; }
  done < <(jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json")
  [ -z "$(find "$dir" -type l)" ] || { find "$dir" -type l >&2; return 1; }
}

@test "every installed skill is a copy of skills/<name>/, coding-crew-lib's scripts/<lib> a real directory equal to lib/<lib>" {
  _skills_copied "$ALL/.claude/skills"
  local lib
  for lib in tracker checks git-workflow; do
    # One source per library, under lib/: coding-crew-lib's committed scripts/<lib> is a link to it
    # (tests/rendered-tree.bats checks each one), and the install copies through the link.
    [ -L "$SCRIPT_DIR/skills/coding-crew-lib/scripts/$lib" ]
    [ -d "$ALL/.claude/skills/coding-crew-lib/scripts/$lib" ] && [ ! -L "$ALL/.claude/skills/coding-crew-lib/scripts/$lib" ]
    diff -r "$SCRIPT_DIR/lib/$lib" "$ALL/.claude/skills/coding-crew-lib/scripts/$lib"
  done
  [ -z "$(find "$ALL/.claude/skills" -path '*/scripts/*' \( -name write-commands-cache.sh -o -name cli.mjs \) | grep -v '/coding-crew-lib/scripts/')" ]
}

@test "the Actions workflow's skill subset installs coding-crew-lib with it, on every platform" {
  cd "$SCRIPT_DIR"
  local p
  for p in "${PLATFORMS[@]}"; do
    mkdir -p "$TEMP_DIR/$p" && TARGET_REPO="$TEMP_DIR/$p" ./install.sh "$p" --skills solve-feature,crew-review,address-pr-comments >/dev/null
    [ -f "$TEMP_DIR/$p/$(platform_field "$p" projectSkills)/coding-crew-lib/scripts/tracker/cli.mjs" ] || { echo "$p: no coding-crew-lib"; return 1; }
  done
}

@test "HOME=<tmp> ./install.sh claude installs at user level: each skill a copy of skills/<name>/, no .coding-crew/lib" {
  local home="$TEMP_DIR/home"
  mkdir -p "$home"
  cd "$SCRIPT_DIR"
  run env -u TARGET_REPO -u CLAUDE_CONFIG_DIR HOME="$home" ./install.sh claude
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  local skills="$home/$(platform_field claude userSkills)" lib
  [ -f "$skills/solve-feature/SKILL.md" ]
  _skills_copied "$skills"
  [ ! -e "$home/.coding-crew/lib" ]
  [ "$(jq 'has("libs")' "$home/.coding-crew/manifest.json")" = false ]

  # From inside a repo, the installed CLI runs from coding-crew-lib, and preflight finds the checks library there.
  mkdir -p "$TEMP_DIR/repo" && git -C "$TEMP_DIR/repo" init -q -b feat
  cd "$TEMP_DIR/repo"
  run env HOME="$home" node "$skills/coding-crew-lib/scripts/tracker/cli.mjs" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracker="* ]]
  [[ "$output" == *"configured="* ]]
  run bash "$skills/solve-issue/scripts/preflight.sh" --project-root "$TEMP_DIR/repo"
  [ "$status" -eq 0 ] && [ "${lines[0]}" = OK ] || { echo "$output"; return 1; }

  cd "$SCRIPT_DIR"
  run env -u TARGET_REPO -u CLAUDE_CONFIG_DIR HOME="$home" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ ! -e "$skills/solve-feature" ]
  [ ! -e "$home/.coding-crew" ]
}

@test "--project <repo> writes the same copies under the repo, no .coding-crew/lib, and a copy of the repo still runs" {
  local repo="$TEMP_DIR/repo" home="$TEMP_DIR/home"
  mkdir -p "$repo" "$home" && git -C "$repo" init -q
  cd "$SCRIPT_DIR"
  run env -u TARGET_REPO HOME="$home" ./install.sh claude --project "$repo"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -z "$(ls -A "$home")" ]
  _skills_copied "$repo/.claude/skills"
  # The libraries once, in coding-crew-lib, not a copy per skill.
  [ "$(find "$repo/.claude/skills" -type f | wc -l | tr -d ' ')" -eq 67 ] || { find "$repo/.claude/skills" -type f | wc -l; return 1; }
  [ ! -e "$repo/.coding-crew/lib" ]
  [ "$(jq 'has("libs")' "$repo/.coding-crew/manifest.json")" = false ]

  cp -a "$repo" "$TEMP_DIR/moved"
  rm -rf "$repo"
  cd "$TEMP_DIR/moved"
  run node .claude/skills/coding-crew-lib/scripts/tracker/cli.mjs config
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
  hits=$(cd "$ALL" && find . \( -name SKILL.md -o -path '*/references/*' -o -path '*/scripts/*' \) -type f -print0 \
    | xargs -0 grep -nF -e '.coding-crew/tracker/' -e '.coding-crew/dep-install/' -e '.coding-crew/solve-issue/' \
        -e '../solve-issue/' -e '../dep-install/' -e '{{' || true)
  [ -z "$hits" ] || { echo "$hits" >&2; return 1; }
}

@test "uninstall --skill drops the skill from the manifest, and a manifest an older install wrote with libs is accepted" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skills tdd,crew-review,configure-tracker >/dev/null
  local m="$TEMP_DIR/.coding-crew/manifest.json"
  jq '.libs = ["tracker"]' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill crew-review
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -e "$TEMP_DIR/.claude/skills/crew-review" ]
  [ -f "$TEMP_DIR/.claude/skills/coding-crew-lib/scripts/tracker/cli.mjs" ]
  [ "$(jq -c '.skills' "$m")" = '["coding-crew-lib","configure-tracker","tdd"]' ]
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ "$(jq 'has("libs")' "$m")" = false ]
}

@test "uninstall --skill coding-crew-lib keeps it while an installed skill needs it, and removes it with them" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skills tdd,crew-review >/dev/null
  local m="$TEMP_DIR/.coding-crew/manifest.json"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill coding-crew-lib
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [[ "$output" == *"coding-crew-lib: kept, still needed by crew-review"* ]] || { echo "$output" >&2; return 1; }
  [ -f "$TEMP_DIR/.claude/skills/coding-crew-lib/scripts/tracker/cli.mjs" ]
  [ "$(jq -c '.skills' "$m")" = '["coding-crew-lib","crew-review","tdd"]' ]
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skills crew-review,coding-crew-lib
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -e "$TEMP_DIR/.claude/skills/coding-crew-lib" ] && [ ! -e "$TEMP_DIR/.claude/skills/crew-review" ]
  [ "$(jq -c '.skills' "$m")" = '["tdd"]' ]
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

  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skills tdd,to-issues,crew-review > /dev/null
  [ -d "$TEMP_DIR/.claude/skills/crew-review" ]
  run jq -r '.skills | index("crew-review") != null' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$output" == "true" ]

  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skills tdd,to-issues"

  [[ "$output" =~ "pruning crew-review" ]]
  [ ! -d "$TEMP_DIR/.claude/skills/crew-review" ]
  [ -d "$TEMP_DIR/.claude/skills/tdd" ]
  [ -d "$TEMP_DIR/.claude/skills/to-issues" ]
  run jq -r '.skills | index("crew-review") != null' "$TEMP_DIR/.coding-crew/manifest.json"
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

# ── the tracker library (<skill-dir>/scripts/tracker/) ────────────────────────
# Copied with any skill that ships it; mechanism, so always overwritten, and removed with the skill.

@test "uninstall removes the skills with their library copies and the manifest, and keeps config.json" {
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

# ── migration: the .coding-crew/lib layout an older install.sh wrote ─────────
# Skills linked scripts/<lib> into <root>/.coding-crew/lib/<lib>; only install.sh ever wrote that dir.

# _old_lib_install <root> [with-libs] — that layout for to-issues, beside a config.json.
_old_lib_install() {
  local root="$1" libs="${2:-}"
  mkdir -p "$root/.coding-crew/lib/tracker" "$root/.claude/skills/to-issues/scripts"
  echo '// old' > "$root/.coding-crew/lib/tracker/cli.mjs"
  ln -s ../../../../.coding-crew/lib/tracker "$root/.claude/skills/to-issues/scripts/tracker"
  echo old > "$root/.claude/skills/to-issues/SKILL.md"
  echo '{"tracker":{"kind":"local"}}' > "$root/.coding-crew/config.json"
  jq -n --arg libs "$libs" '{platforms: ["claude"], skills: ["to-issues"]}
    + (if $libs == "" then {} else {libs: ["tracker"]} end)' > "$root/.coding-crew/manifest.json"
}

_assert_old_lib_gone() {
  [ ! -e "$TEMP_DIR/.coding-crew/lib" ] || { echo ".coding-crew/lib survived" >&2; return 1; }
  [[ "$output" == *".coding-crew/lib/"*"removed"* || "$output" == *"removed .coding-crew/lib/"* ]] || { echo "not reported: $output" >&2; return 1; }
  [ "$(cat "$TEMP_DIR/.coding-crew/config.json")" = '{"tracker":{"kind":"local"}}' ]
}

@test "a plain install over the old layout removes .coding-crew/lib, keeps config.json and leaves a working copy" {
  local libs
  for libs in "" with-libs; do
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    _old_lib_install "$TEMP_DIR" $libs
    cd "$SCRIPT_DIR"
    run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    _assert_old_lib_gone
    diff -r "$SCRIPT_DIR/skills/to-issues" "$TEMP_DIR/.claude/skills/to-issues"
    [ "$(jq 'has("libs")' "$TEMP_DIR/.coding-crew/manifest.json")" = false ]
  done
}

# _old_lib_second_skill <root> — a second old-layout skill (crew-review) linked into .coding-crew/lib.
_old_lib_second_skill() {
  local root="$1"
  mkdir -p "$root/.claude/skills/crew-review/scripts"
  ln -s ../../../../.coding-crew/lib/tracker "$root/.claude/skills/crew-review/scripts/tracker"
  jq '.skills += ["crew-review"]' "$root/.coding-crew/manifest.json" > "$root/m.tmp" && mv "$root/m.tmp" "$root/.coding-crew/manifest.json"
}

@test "a partial install over the old layout removes .coding-crew/lib even while another skill still links there" {
  _old_lib_install "$TEMP_DIR" with-libs
  _old_lib_second_skill "$TEMP_DIR"
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  _assert_old_lib_gone
}

@test "uninstall --skill over the old layout removes .coding-crew/lib even while another skill still links there" {
  _old_lib_install "$TEMP_DIR" with-libs
  _old_lib_second_skill "$TEMP_DIR"
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill to-issues
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  _assert_old_lib_gone
}

@test "install --update over the old layout removes .coding-crew/lib and keeps config.json" {
  local libs
  for libs in "" with-libs; do
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    _old_lib_install "$TEMP_DIR" $libs
    cd "$SCRIPT_DIR"
    run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    _assert_old_lib_gone
    diff -r "$SCRIPT_DIR/skills/to-issues" "$TEMP_DIR/.claude/skills/to-issues"
  done
}

@test "uninstall over the old layout removes .coding-crew/lib, keeps config.json, and .coding-crew/ only goes when empty" {
  local libs
  for libs in "" with-libs; do
    rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
    _old_lib_install "$TEMP_DIR" $libs
    cd "$SCRIPT_DIR"
    run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
    [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
    _assert_old_lib_gone
    [ ! -e "$TEMP_DIR/.coding-crew/manifest.json" ]
  done
  # No config.json: nothing is left, so .coding-crew/ goes too.
  rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR"
  _old_lib_install "$TEMP_DIR" with-libs
  rm "$TEMP_DIR/.coding-crew/config.json"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill to-issues
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -e "$TEMP_DIR/.coding-crew" ]
}
