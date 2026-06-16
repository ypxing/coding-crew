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
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-tdd

  # Verify the skill file was created
  [ -f "$TEMP_DIR/.claude/skills/crew-tdd/SKILL.md" ]
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
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-tdd

  # Verify manifest was created
  [ -f "$TEMP_DIR/.coding-crew.manifest.json" ]

  # Verify skill entry exists
  run jq -r '.skills["crew-tdd"].version' "$TEMP_DIR/.coding-crew.manifest.json"
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
  TARGET_REPO="$temp1" ./install.sh claude --skill crew-tdd > /dev/null
  TARGET_REPO="$temp2" ./install.sh claude --skill crew-tdd > /dev/null

  cmp -s "$temp1/.claude/skills/crew-tdd/SKILL.md" "$temp2/.claude/skills/crew-tdd/SKILL.md"
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

@test "registry.json skill keys use crew- prefix" {
  cd "$SCRIPT_DIR"

  run jq -r '.skills | keys[]' registry.json
  [ "$status" -eq 0 ]
  # All keys must use crew- (no colon form)
  ! echo "$output" | grep -q 'crew:'
  [[ "$output" == *"crew-afk"* ]]
  [[ "$output" == *"crew-tdd"* ]]
}

@test "install skill creates SKILL.md at crew- path" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-tdd

  # Verify the skill file was created at the new crew- path
  [ -f "$TEMP_DIR/.claude/skills/crew-tdd/SKILL.md" ]
}

@test "installing crew-afk installs agent-deps with crew- names" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk

  # Verify both agent files were installed at crew- paths
  [ -f "$TEMP_DIR/.claude/agents/crew-coder.md" ]
  [ -f "$TEMP_DIR/.claude/agents/crew-code-reviewer.md" ]

  # Verify manifest contains both agents under crew- keys
  run jq -r '.agents["crew-coder"].version' "$TEMP_DIR/.coding-crew.manifest.json"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]

  run jq -r '.agents["crew-code-reviewer"].version' "$TEMP_DIR/.coding-crew.manifest.json"
  [ "$status" -eq 0 ]
  [ "$output" != "null" ]
}

@test "reinstalling modified skill produces diff output" {
  cd "$SCRIPT_DIR"

  # First install
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-tdd > /dev/null

  # Modify the installed file
  echo "# Modified by test" >> "$TEMP_DIR/.claude/skills/crew-tdd/SKILL.md"

  # Reinstall and capture output
  run bash -c "cd '$SCRIPT_DIR' && TARGET_REPO='$TEMP_DIR' ./install.sh claude --skill crew-tdd"

  # Verify diff markers appear in stdout
  [[ "$output" =~ "---" ]]
  [[ "$output" =~ "+++" ]]
}
