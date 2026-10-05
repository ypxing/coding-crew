#!/usr/bin/env bats

# pi platform support: install paths, agent shims, skill variants, dispatch script

setup() {
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "pi is an accepted platform" {
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill tdd
  [ "$status" -eq 0 ]
  [ -f "$TEMP_DIR/.pi/skills/tdd/SKILL.md" ]
}

@test "invalid platform is still rejected" {
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh nonsense --skill tdd
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid platform"* ]]
}

@test "pi crew-afk SKILL.md is the pi variant, not the claude or copilot one" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk

  grep -q "run --platform pi " "$TEMP_DIR/.pi/skills/crew-afk/SKILL.md"
  # no unselected platform variants left behind
  [ ! -f "$TEMP_DIR/.pi/skills/crew-afk/pi.SKILL.md" ]
  [ ! -f "$TEMP_DIR/.pi/skills/crew-afk/copilot.SKILL.md" ]
}

@test "claude install is unaffected by the pi variant" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk

  grep -q "run --platform claude " "$TEMP_DIR/.claude/skills/crew-afk/SKILL.md"
  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/pi.SKILL.md" ]
}

@test "uninstall removes the pi-installed crew-afk" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk
  [ -d "$TEMP_DIR/.pi/skills/crew-afk" ]

  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill crew-afk

  [ ! -d "$TEMP_DIR/.pi/skills/crew-afk" ]
  [ ! -d "$TEMP_DIR/.coding-crew/crew-afk" ]
  [ ! -f "$TEMP_DIR/.pi/agents/crew-coder.md" ]
}

@test "squash-commits.sh accepts --platform pi" {
  cd "$SCRIPT_DIR"
  run grep -n "PLATFORM\" = \"pi\"" skills/crew-afk/scripts/squash-commits.sh
  [ "$status" -eq 0 ]
}

@test "pi install ships no bash dispatcher, and an update prunes one an older install left" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk
  [ ! -f "$TEMP_DIR/.pi/skills/crew-afk/scripts/dispatch-agent.sh" ]
  touch "$TEMP_DIR/.pi/skills/crew-afk/scripts/dispatch-agent.sh"

  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk
  [ ! -f "$TEMP_DIR/.pi/skills/crew-afk/scripts/dispatch-agent.sh" ]
}
