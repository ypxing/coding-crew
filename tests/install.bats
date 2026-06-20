#!/usr/bin/env bats

# Tracer bullet test - verify basic install creates expected file

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

@test "protocol substitution removes {{PROTOCOL}} placeholder" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude crew-code-reviewer

  # Verify the agent file exists
  [ -f "$TEMP_DIR/.claude/agents/crew-code-reviewer.md" ]

  # Verify no {{PROTOCOL}} literal remains in the installed file
  ! grep -q '{{PROTOCOL}}' "$TEMP_DIR/.claude/agents/crew-code-reviewer.md"
}

@test "manifest contains correct skill name and version after install" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd

  # Verify manifest was created
  [ -f "$TEMP_DIR/.coding-crew.manifest.json" ]

  # Verify skill entry exists
  run jq -r '.skills["tdd"].version' "$TEMP_DIR/.coding-crew.manifest.json"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ "$output" != "null" ]
}

@test "installing crew-afk installs agent-deps (crew-coder and crew-code-reviewer)" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk

  # Verify both agent files were installed
  [ -f "$TEMP_DIR/.claude/agents/crew-coder.md" ]
  [ -f "$TEMP_DIR/.claude/agents/crew-code-reviewer.md" ]

  # Verify manifest contains both agents
  run jq -r '.agents["crew-coder"].version' "$TEMP_DIR/.coding-crew.manifest.json"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run jq -r '.agents["crew-code-reviewer"].version' "$TEMP_DIR/.coding-crew.manifest.json"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
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

@test "registry.json agent keys use crew- prefix" {
  cd "$SCRIPT_DIR"

  run jq -r '.agents | keys[]' registry.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"crew-coder"* ]]
  [[ "$output" == *"crew-code-reviewer"* ]]
  # Old keys must not be present
  ! echo "$output" | grep -qxF "coder"
  ! echo "$output" | grep -qxF "code-reviewer"
}

@test "registry.json skill keys crew-afk and crew-plan are present; others do not use crew- prefix" {
  cd "$SCRIPT_DIR"

  run jq -r '.skills | keys[]' registry.json
  [ "$status" -eq 0 ]
  # crew-afk and crew-plan must be present
  [[ "$output" == *"crew-afk"* ]]
  [[ "$output" == *"crew-plan"* ]]
  # tdd must exist without crew- prefix
  [[ "$output" == *"tdd"* ]]
  # crew-tdd must not be present
  ! echo "$output" | grep -qxF "crew-tdd"
}

@test "reinstalling modified skill produces diff output" {
  cd "$SCRIPT_DIR"

  # First install
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill tdd > /dev/null

  # Modify the installed file
  echo "# Modified by test" >> "$TEMP_DIR/.claude/skills/tdd/SKILL.md"

  # Reinstall and capture output
  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skill tdd"

  # Verify diff markers appear in stdout
  [[ "$output" =~ "---" ]]
  [[ "$output" =~ "+++" ]]
}

@test "install creates docs/agents/issue-tracker.md in target repo" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude

  [ -f "$TEMP_DIR/docs/agents/issue-tracker.md" ]
}

@test "reinstall does not overwrite existing docs/agents/issue-tracker.md" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude > /dev/null

  # Modify the installed file
  echo "custom content" > "$TEMP_DIR/docs/agents/issue-tracker.md"

  # Reinstall
  TARGET_REPO="$TEMP_DIR" ./install.sh claude > /dev/null

  # Verify custom content was preserved (not overwritten)
  grep -q "custom content" "$TEMP_DIR/docs/agents/issue-tracker.md"
}

@test "install --user creates docs/agents/issue-tracker.md under HOME/.claude, skipping if present" {
  local fake_home
  fake_home=$(mktemp -d)

  # First install: file should be created
  cd "$SCRIPT_DIR"
  HOME="$fake_home" ./install.sh --user claude > /dev/null

  [ -f "$fake_home/.claude/docs/agents/issue-tracker.md" ]

  # Write custom content then reinstall — must not overwrite
  echo "user custom" > "$fake_home/.claude/docs/agents/issue-tracker.md"
  HOME="$fake_home" ./install.sh --user claude > /dev/null

  grep -q "user custom" "$fake_home/.claude/docs/agents/issue-tracker.md"
  rm -rf "$fake_home"
}

@test "registry.json docs section registers tracker template source" {
  cd "$SCRIPT_DIR"

  run jq -r '.docs.templates["issue-tracker"].source // empty' registry.json
  [ "$status" -eq 0 ]
  [ -n "$output" ]
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
