#!/usr/bin/env bats

# Tracer bullet test - verify basic install creates expected file

load helpers/platforms

setup() {
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "install skill creates SKILL.md at expected path" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd

  # Verify the skill file was created
  [ -f "$TEMP_DIR/.claude/skills/tdd/SKILL.md" ]
}

@test "manifest contains correct skill name and version after install" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd

  # Verify manifest was created
  [ -f "$TEMP_DIR/.coding-crew/manifest.json" ]

  # Verify skill entry exists
  run jq -r '.skills["tdd"].version' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]
}

# ─── nothing installed that no agent runs ────────────────────────────────────
#
# Every installed word is a word some agent may read at runtime, so a developer
# README and a retired reference are not inert: they are exploration bait in a
# directory the model lists. These assert the crew-afk install ships neither, and
# that an older install's copies are swept rather than left to contradict the body.

@test "crew-afk install ships no developer README in the skill tree" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk

  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/README.md" ]
}

@test "crew-afk install ships no verification reference (verify-worktree.sh is the policy)" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk

  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/references/verification.md" ]
  # solve-issue's own verification reference is a different file and still ships.
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue
  [ -f "$TEMP_DIR/.claude/skills/solve-issue/references/verification.md" ]
}

@test "to-issues installs references/ beside SKILL.md for every platform" {
  cd "$SCRIPT_DIR"
  local platform skill_md dir count=0
  for platform in "${PLATFORMS[@]}"; do
    TARGET_REPO="$TEMP_DIR" ./install.sh "$platform" --skill to-issues > /dev/null
  done
  while IFS= read -r skill_md; do
    dir=$(dirname "$skill_md")
    [ ! -e "$dir/references/github-publish.md" ]
    [ ! -e "$dir/references/rerun.md" ]
    [ -f "$dir/references/expand-contract.md" ]
    count=$((count + 1))
  done < <(find "$TEMP_DIR" -path '*/skills/to-issues/SKILL.md')
  [ "$count" -eq "${#PLATFORMS[@]}" ]
}

@test "install sweeps retired files an earlier version left in the skill tree" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk

  # Simulate an install from before these were retired.
  mkdir -p "$TEMP_DIR/.claude/skills/crew-afk/references" \
           "$TEMP_DIR/.claude/skills/crew-afk/scripts"
  echo "stale policy" > "$TEMP_DIR/.claude/skills/crew-afk/references/verification.md"
  echo "stale readme" > "$TEMP_DIR/.claude/skills/crew-afk/scripts/README.md"
  echo "stale tracker setup" > "$TEMP_DIR/.claude/skills/crew-afk/scripts/configure-tracker-auto.sh"
  echo "stale audit" > "$TEMP_DIR/.claude/skills/crew-afk/scripts/coverage-validation.sh"
  echo "stale audit" > "$TEMP_DIR/.claude/skills/crew-afk/scripts/prd-audit.sh"

  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk

  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/references/verification.md" ]
  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/README.md" ]
  # Tracker configuration was a step in the prose orchestrator; the program does its own
  # issue discovery (orchestrator/lib/tracker.mjs), so crew-afk shipped a script no agent
  # ran.
  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/configure-tracker-auto.sh" ]
  # The PRD audit's script, under its old name and its last.
  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/coverage-validation.sh" ]
  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/prd-audit.sh" ]
  # The skill itself is intact.
  [ -f "$TEMP_DIR/.claude/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/verify-worktree.sh" ]
}

@test "configure-tracker-auto.sh ships with no skill, and an older install's copy is removed" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk
  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/configure-tracker-auto.sh" ]
  # configure-tracker offers its two backends itself; an earlier version's script is swept.
  mkdir -p "$TEMP_DIR/.claude/skills/configure-tracker/scripts"
  echo "stale tracker setup" > "$TEMP_DIR/.claude/skills/configure-tracker/scripts/configure-tracker-auto.sh"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill configure-tracker
  [ ! -e "$TEMP_DIR/.claude/skills/configure-tracker/scripts" ]
  [ -f "$TEMP_DIR/.claude/skills/configure-tracker/SKILL.md" ]
}

@test "solve-issue ships no feature-branch-setup.sh: its step 0 is a guard, not a branch creation" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue

  # The script only acts when on the default branch — which the guard above it already
  # refuses — so the call was dead. crew-afk still uses it, via session-init.sh.
  [ ! -f "$TEMP_DIR/.claude/skills/solve-issue/scripts/feature-branch-setup.sh" ]
  [ -f "$TEMP_DIR/.claude/skills/solve-issue/scripts/commit-changes.sh" ]
  ! grep -q 'feature-branch-setup\.sh' "$TEMP_DIR/.claude/skills/solve-issue/SKILL.md"
}

@test "crew-afk ships no feature-branch-setup.sh, and --update removes an older install's copy" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  # session-init.sh names the feature branch itself (feature_branch_name).
  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/feature-branch-setup.sh" ]

  # An install from before it was retired: the script beside session-init.sh, an older version.
  echo "stale branch setup" > "$TEMP_DIR/.claude/skills/crew-afk/scripts/feature-branch-setup.sh"
  local m="$TEMP_DIR/.coding-crew/manifest.json"
  jq '.skills["crew-afk"].version = "0.0.0"' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/feature-branch-setup.sh" ]
  [ -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/session-init.sh" ]
}

# ─── an installed tree is an exact copy of what the install wrote ────────────
#
# No hand list of retired files: whatever a skill root or asset tree holds that this
# run did not write is removed, then any directory left empty.

@test "--update prunes a file to-issues no longer ships, keeping every shipped file" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  local dir="$TEMP_DIR/.claude/skills/to-issues"
  echo "raw gh publish path" > "$dir/references/github-publish.md"
  local m="$TEMP_DIR/.coding-crew/manifest.json"
  jq '.skills["to-issues"].version = "0.0.0"' "$m" > "$m.tmp" && mv "$m.tmp" "$m"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  [ ! -e "$dir/references/github-publish.md" ]
  [ -f "$dir/SKILL.md" ]
  [ -f "$dir/references/expand-contract.md" ]
  [[ "$output" == *".claude/skills/to-issues/references/github-publish.md (removed)"* ]]
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

@test "the prune keeps every scripts[] file a skill declares" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  echo stale > "$TEMP_DIR/.claude/skills/solve-issue/scripts/retired.sh"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  [ ! -e "$TEMP_DIR/.claude/skills/solve-issue/scripts/retired.sh" ]
  local script
  while IFS= read -r script; do
    [ -x "$TEMP_DIR/.claude/skills/solve-issue/scripts/$script" ]
  done < <(jq -r '.skills["solve-issue"].scripts[]' registry.json)
}

@test "re-installing crew-afk prunes its asset tree" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  echo "// deleted module" > "$TEMP_DIR/.coding-crew/crew-afk/lib/retired.mjs"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/.coding-crew/crew-afk/lib/retired.mjs" ]
  [ -f "$TEMP_DIR/.coding-crew/crew-afk/lib/dispatch.mjs" ]
  [[ "$output" == *".coding-crew/crew-afk/lib/retired.mjs (removed)"* ]]
}

@test "installing crew-afk prunes an older install's common/ and per-platform fragment dirs" {
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/.coding-crew/skills/_shared/fragments/common" "$TEMP_DIR/.coding-crew/skills/_shared/fragments/claude"
  echo "old" > "$TEMP_DIR/.coding-crew/skills/_shared/fragments/common/a.md"
  echo "old" > "$TEMP_DIR/.coding-crew/skills/_shared/fragments/claude/b.md"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  [ ! -e "$TEMP_DIR/.coding-crew/skills/_shared/fragments/common" ]
  [ ! -e "$TEMP_DIR/.coding-crew/skills/_shared/fragments/claude" ]
  [ -f "$TEMP_DIR/.coding-crew/skills/_shared/fragments/design-standard.md" ]
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


@test "solve-issue and crew-afk both get write-commands-cache.sh; only crew-afk gets discover-commands.sh" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk

  # solve-issue's own agent turn already *is* the model, so it never dispatches a
  # separate prompt-building call — only the shared write side is needed.
  [ -f "$TEMP_DIR/.claude/skills/solve-issue/scripts/write-commands-cache.sh" ]
  [ ! -f "$TEMP_DIR/.claude/skills/solve-issue/scripts/discover-commands.sh" ]

  # crew-afk dispatches an agent-less model call (orchestrator/lib/commands.mjs) and
  # needs both halves.
  [ -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/write-commands-cache.sh" ]
  [ -f "$TEMP_DIR/.claude/skills/crew-afk/scripts/discover-commands.sh" ]

  # Canonical source is scripts/skill-utils/git-workflow/ for both, not duplicated by
  # hand in either skill's own source-dir.
  [ ! -f "$SCRIPT_DIR/skills/solve-issue/scripts/write-commands-cache.sh" ]
  [ ! -f "$SCRIPT_DIR/skills/crew-afk/scripts/discover-commands.sh" ]
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

@test "registry.json has no agents: the roles ship inside crew-afk" {
  cd "$SCRIPT_DIR"
  run jq -r 'has("agents")' registry.json
  [ "$output" = "false" ]
}

@test "registry.json skill keys crew-afk and crew-grill are present; crew-plan must not exist" {
  cd "$SCRIPT_DIR"

  run jq -r '.skills | keys[]' registry.json
  [ "$status" -eq 0 ]
  # crew-afk and crew-grill must be present
  [[ "$output" == *"crew-afk"* ]]
  [[ "$output" == *"crew-grill"* ]]
  # tdd must exist without crew- prefix
  [[ "$output" == *"tdd"* ]]
  # crew-tdd must not be present
  ! echo "$output" | grep -qxF "crew-tdd"
  # crew-plan must not be present (renamed to crew-grill)
  ! echo "$output" | grep -qxF "crew-plan"
}

@test "crew-grill skill is installed to correct directory" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-grill

  [ -f "$TEMP_DIR/.claude/skills/crew-grill/SKILL.md" ]
}

@test "crew-grill SKILL.md contains correct name field" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-grill

  grep -q 'name: crew-grill' "$TEMP_DIR/.claude/skills/crew-grill/SKILL.md"
}

@test "crew-grill copilot skill is installed to correct directory" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-grill

  # Copilot scans .github/skills at project scope, never .copilot/skills
  [ -f "$TEMP_DIR/.github/skills/crew-grill/SKILL.md" ]
  [ ! -d "$TEMP_DIR/.copilot" ]
}

@test "crew-brainstorm skill is installed to correct directory (claude)" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-brainstorm

  [ -f "$TEMP_DIR/.claude/skills/crew-brainstorm/SKILL.md" ]
}

@test "crew-brainstorm skill is installed to correct directory (copilot)" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-brainstorm

  [ -f "$TEMP_DIR/.github/skills/crew-brainstorm/SKILL.md" ]
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
  run jq -r '.skills | has("to-prd")' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$output" == "true" ]

  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skills tdd,to-issues"

  [[ "$output" =~ "pruning to-prd" ]]
  [ ! -d "$TEMP_DIR/.claude/skills/to-prd" ]
  [ -d "$TEMP_DIR/.claude/skills/tdd" ]
  [ -d "$TEMP_DIR/.claude/skills/to-issues" ]
  run jq -r '.skills | has("to-prd")' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$output" == "false" ]
}

@test "reinstalling an unmodified install reports no updates" {
  cd "$SCRIPT_DIR"

  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk > /dev/null

  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skill crew-afk"

  # Nothing changed on disk, so nothing should be reported as updated
  [[ ! "$output" =~ "(updated)" ]]
}

# ── tracker config: legacy issue-tracker.md → config.json ──────────────────────
# The fixtures are copies of this repo's own pre-migration files.

TRACKER_FIXTURES="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/fixtures/tracker-config"

_legacy_tracker_repo() {  # <issue-tracker.md fixture> [config.json fixture]
  mkdir -p "$TEMP_DIR/.coding-crew/docs/templates/trackers"
  cp "$TRACKER_FIXTURES/$1" "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
  cp "$SCRIPT_DIR/tracker/docs/local.md" "$SCRIPT_DIR/tracker/docs/github.md" "$TEMP_DIR/.coding-crew/docs/templates/trackers/"
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
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude > /dev/null
  [ ! -e "$TEMP_DIR/.coding-crew/docs" ]
  if [ -f "$TEMP_DIR/.coding-crew/config.json" ]; then
    run jq -e 'has("tracker")' "$TEMP_DIR/.coding-crew/config.json"
    [ "$status" -ne 0 ]
  fi
  cmp "$SCRIPT_DIR/tracker/docs/local.md" "$TEMP_DIR/.coding-crew/tracker/docs/local.md"
  cmp "$SCRIPT_DIR/tracker/docs/github.md" "$TEMP_DIR/.coding-crew/tracker/docs/github.md"
}

@test "install --update overwrites the tracker docs when a source doc changed" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null
  echo "stale prose" > "$TEMP_DIR/.coding-crew/tracker/docs/github.md"
  echo "stale prose" > "$TEMP_DIR/.coding-crew/tracker/docs/local.md"
  TARGET_REPO="$TEMP_DIR" ./install.sh --update > /dev/null
  cmp "$SCRIPT_DIR/tracker/docs/local.md" "$TEMP_DIR/.coding-crew/tracker/docs/local.md"
  cmp "$SCRIPT_DIR/tracker/docs/github.md" "$TEMP_DIR/.coding-crew/tracker/docs/github.md"
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

@test "install --user is rejected with an invalid platform error" {
  run ./install.sh --user claude
  [ "$status" -ne 0 ]
}

@test "registry.json registers no doc templates: tracker docs ship in the tracker tree" {
  cd "$SCRIPT_DIR"

  run jq -r '.docs.templates // empty' registry.json
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(jq -r '.docs.trees.tracker.source' registry.json)" = "tracker" ]
}

@test "install does not create triage-labels.md in target repo" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude > /dev/null

  [ ! -f "$TEMP_DIR/docs/agents/triage-labels.md" ]
}

@test "crew-address-findings skill is installed to correct directory" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-address-findings

  # Verify the skill file was created at the correct path
  [ -f "$TEMP_DIR/.claude/skills/crew-address-findings/SKILL.md" ]
}

@test "crew-address-findings SKILL.md contains correct name field" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-address-findings

  # Verify the installed SKILL.md has name: crew-address-findings
  grep -q 'name: crew-address-findings' "$TEMP_DIR/.claude/skills/crew-address-findings/SKILL.md"
}

@test "address-code-review directory is absent after crew-address-findings install" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-address-findings

  # Verify the old address-code-review directory does not exist
  [ ! -d "$TEMP_DIR/.claude/skills/address-code-review/" ]
}

@test "uninstall leaves no empty platform directories behind" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh >/dev/null
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]

  # Every top-level dir any platform installs into or keeps config in, from platforms.json.
  local dirs=() p f
  for p in "${PLATFORMS[@]}"; do
    for f in projectSkills userSkills configDir; do dirs+=("$(platform_field "$p" "$f" | cut -d/ -f1)"); done
  done
  for dir in $(printf '%s\n' "${dirs[@]}" | sort -u); do
    if [ -d "$TEMP_DIR/$dir" ]; then
      echo "REPO_ROOT was: $TEMP_DIR"
      echo "--- uninstall output ---"
      echo "$output"
      echo "--- leftover $dir ---"
      find "$TEMP_DIR/$dir" | head -5
    fi
    [ ! -d "$TEMP_DIR/$dir" ]
  done
  # Everything under .coding-crew/ is mechanism install owns, so nothing is left of it.
  [ ! -e "$TEMP_DIR/.coding-crew/docs" ]
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

# ── retired tracker wrappers (.coding-crew/scripts/) ──────────────────────────
# tracker-config.sh and mark-issue-done.sh no longer ship: every caller runs tracker/cli.mjs. A copy
# an older install left is a second answer that can go stale, so install, --update and uninstall
# delete each (registry.json `retired-scripts`), then the directory once nothing else is in it.

# plant_retired_scripts <root> [extra-file] — the two wrappers an older install wrote.
plant_retired_scripts() {
  mkdir -p "$1/.coding-crew/scripts"
  echo "# old" > "$1/.coding-crew/scripts/tracker-config.sh"
  echo "# old" > "$1/.coding-crew/scripts/mark-issue-done.sh"
  [ -z "${2:-}" ] || echo "mine" > "$1/.coding-crew/scripts/$2"
}

@test "registry.json ships no docs.scripts and retires both tracker wrappers" {
  run jq -e '.docs | has("scripts") | not' "$SCRIPT_DIR/registry.json"
  [ "$status" -eq 0 ]
  run jq -r '."retired-scripts"[]' "$SCRIPT_DIR/registry.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *".coding-crew/scripts/tracker-config.sh"* ]]
  [[ "$output" == *".coding-crew/scripts/mark-issue-done.sh"* ]]
}

@test "a fresh install into an empty repo writes no .coding-crew/scripts/" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude >/dev/null
  [ -f "$TEMP_DIR/.coding-crew/tracker/cli.mjs" ]
  [ ! -e "$TEMP_DIR/.coding-crew/scripts" ]
}

@test "install deletes the retired wrappers, then the emptied .coding-crew/scripts/" {
  cd "$SCRIPT_DIR"
  plant_retired_scripts "$TEMP_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed .coding-crew/scripts/tracker-config.sh"* ]]
  [ ! -e "$TEMP_DIR/.coding-crew/scripts" ]
}

@test "install --update deletes the retired wrappers even when every entry is up to date" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd >/dev/null
  plant_retired_scripts "$TEMP_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/.coding-crew/scripts" ]
}

@test "uninstall deletes the retired wrappers, then the emptied .coding-crew/scripts/" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd >/dev/null
  printf '{"tracker": {"kind": "github"}}\n' > "$TEMP_DIR/.coding-crew/config.json"
  plant_retired_scripts "$TEMP_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/.coding-crew/scripts" ]
  [ -f "$TEMP_DIR/.coding-crew/config.json" ]
}

@test "uninstall --skill deletes the retired wrappers too" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd >/dev/null
  plant_retired_scripts "$TEMP_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill tdd
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/.coding-crew/scripts" ]
}

@test "install, --update and uninstall leave another file in .coding-crew/scripts/, and the directory" {
  cd "$SCRIPT_DIR"
  local step
  for step in install update uninstall; do
    plant_retired_scripts "$TEMP_DIR" notes.sh
    case "$step" in
      install) run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd ;;
      update) run env TARGET_REPO="$TEMP_DIR" ./install.sh --update ;;
      uninstall) run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh ;;
    esac
    echo "$step: $output"
    [ "$status" -eq 0 ]
    [ ! -e "$TEMP_DIR/.coding-crew/scripts/tracker-config.sh" ]
    [ ! -e "$TEMP_DIR/.coding-crew/scripts/mark-issue-done.sh" ]
    [ "$(cat "$TEMP_DIR/.coding-crew/scripts/notes.sh")" = mine ]
  done
}

@test "a user-level install (TARGET_REPO=\$HOME) deletes the retired wrappers there, and so do --update and uninstall" {
  cd "$SCRIPT_DIR"
  local home="$TEMP_DIR/home" step
  mkdir -p "$home"
  for step in install update uninstall; do
    plant_retired_scripts "$home"
    case "$step" in
      install) run env HOME="$home" TARGET_REPO="$home" ./install.sh claude --skill tdd ;;
      update) run env HOME="$home" TARGET_REPO="$home" ./install.sh --update ;;
      uninstall) run env HOME="$home" TARGET_REPO="$home" ./uninstall.sh --user ;;
    esac
    echo "$step: $output"
    [ "$status" -eq 0 ]
    [ ! -e "$home/.coding-crew/scripts" ]
  done
}

# ── the shared tracker CLI (.coding-crew/tracker/) ─────────────────────────────
# Installed on every install, whichever skill, since to-issues / to-prd / solve-issue reach the
# tracker through it without crew-afk; mechanism, so always overwritten, and removed by uninstall.

@test "install of a skill without crew-afk ships the tracker CLI, which runs" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  [ -f "$TEMP_DIR/.coding-crew/tracker/cli.mjs" ]
  [ ! -d "$TEMP_DIR/.coding-crew/crew-afk" ]
  cd "$TEMP_DIR"
  run node .coding-crew/tracker/cli.mjs prd --feature-slug x
  [ "$status" -eq 3 ]
}

@test "re-running install overwrites the tracker tree, dropping files the source no longer has" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  echo "// stale" > "$TEMP_DIR/.coding-crew/tracker/cli.mjs"
  echo "// retired" > "$TEMP_DIR/.coding-crew/tracker/retired.mjs"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  cmp -s "$SCRIPT_DIR/tracker/cli.mjs" "$TEMP_DIR/.coding-crew/tracker/cli.mjs"
  [ ! -e "$TEMP_DIR/.coding-crew/tracker/retired.mjs" ]
}

@test "--update refreshes the tracker tree" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  echo "// stale" > "$TEMP_DIR/.coding-crew/tracker/local.mjs"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  cmp -s "$SCRIPT_DIR/tracker/local.mjs" "$TEMP_DIR/.coding-crew/tracker/local.mjs"
}

@test "uninstall removes the tracker tree" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill to-issues >/dev/null
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/.coding-crew/tracker" ]
}

@test "installed crew-afk imports the one shared tracker copy, and an older install's lib/trackers/ is swept" {
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/.coding-crew/crew-afk/lib/trackers"
  echo "// old" > "$TEMP_DIR/.coding-crew/crew-afk/lib/trackers/github.mjs"
  echo "// old" > "$TEMP_DIR/.coding-crew/crew-afk/lib/tracker-config.mjs"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  [ ! -e "$TEMP_DIR/.coding-crew/crew-afk/lib/trackers" ]
  [ ! -e "$TEMP_DIR/.coding-crew/crew-afk/lib/tracker-config.mjs" ]
  run grep -rl "tracker" "$TEMP_DIR/.coding-crew/crew-afk/lib" --include='tracker*.mjs'
  [ "$output" = "$TEMP_DIR/.coding-crew/crew-afk/lib/tracker.mjs" ]
  # Its imports resolve against .coding-crew/tracker/ — the same module the CLI loads.
  run node --input-type=module -e "
    const a = await import('$TEMP_DIR/.coding-crew/crew-afk/lib/tracker.mjs');
    const b = await import('$TEMP_DIR/.coding-crew/tracker/index.mjs');
    if (a.getTracker !== b.getTracker) process.exit(1);
    const t = await a.getTracker('$TEMP_DIR');
    process.exit(typeof t.listFeatureIssues === 'function' ? 0 : 1);"
  [ "$status" -eq 0 ]
}
