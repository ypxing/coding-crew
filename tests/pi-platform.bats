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

@test "pi crew-afk installs both agent-deps as pi agent files" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk

  [ -f "$TEMP_DIR/.pi/agents/crew-coder.md" ]
  [ -f "$TEMP_DIR/.pi/agents/crew-code-reviewer.md" ]
  [ -f "$TEMP_DIR/.pi/skills/crew-afk/SKILL.md" ]

  # protocol placeholder must be expanded
  ! grep -q '{{PROTOCOL}}' "$TEMP_DIR/.pi/agents/crew-code-reviewer.md"
}

@test "pi crew-afk SKILL.md is the pi variant, not the claude or copilot one" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk

  grep -q "AFK Issue Sprint — pi" "$TEMP_DIR/.pi/skills/crew-afk/SKILL.md"
  # no unselected platform variants left behind
  [ ! -f "$TEMP_DIR/.pi/skills/crew-afk/pi.SKILL.md" ]
  [ ! -f "$TEMP_DIR/.pi/skills/crew-afk/copilot.SKILL.md" ]
}

@test "claude install is unaffected by the pi variant" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk

  grep -q "AFK Issue Sprint — Claude Code" "$TEMP_DIR/.claude/skills/crew-afk/SKILL.md"
  [ ! -f "$TEMP_DIR/.claude/skills/crew-afk/pi.SKILL.md" ]
}

@test "platform=all installs pi alongside claude and copilot" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh all --skill crew-afk

  [ -f "$TEMP_DIR/.claude/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.copilot/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.pi/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.pi/agents/crew-coder.md" ]
}

@test "pi agent definitions declare pi built-in tool names" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk

  run grep -m1 '^tools:' "$TEMP_DIR/.pi/agents/crew-coder.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"read"* ]]
  [[ "$output" == *"bash"* ]]
  # Claude/Copilot-only tool names must not leak into the pi definition
  [[ "$output" != *"Agent"* ]]
  [[ "$output" != *"execute"* ]]
}

@test "crew-afk ships the pi dispatch script, executable" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk

  [ -f "$TEMP_DIR/.pi/skills/crew-afk/scripts/dispatch-agent.sh" ]
  run bash -n "$TEMP_DIR/.pi/skills/crew-afk/scripts/dispatch-agent.sh"
  [ "$status" -eq 0 ]
}

@test "dispatch-agent.sh requires its arguments" {
  cd "$SCRIPT_DIR"
  run bash skills/crew-afk/scripts/dispatch-agent.sh --agent crew-coder
  [ "$status" -ne 0 ]
  [[ "$output" == *"--dir is required"* ]]
}

@test "dispatch-agent.sh reports a missing agent definition" {
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/wt"
  echo "task" > "$TEMP_DIR/prompt.md"
  run env HOME="$TEMP_DIR" MAIN_ROOT="$TEMP_DIR" \
    bash skills/crew-afk/scripts/dispatch-agent.sh \
      --agent does-not-exist --dir "$TEMP_DIR/wt" --prompt-file "$TEMP_DIR/prompt.md"
  [ "$status" -ne 0 ]
  [[ "$output" == *"agent definition not found"* || "$output" == *"pi CLI not found"* ]]
}

@test "user-level pi install uses ~/.pi/agent/ paths" {
  cd "$SCRIPT_DIR"
  # bootstrap installs with TARGET_REPO=$HOME; pi only scans ~/.pi/agent/skills there
  run env HOME="$TEMP_DIR" TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk
  [ "$status" -eq 0 ]
  [ -f "$TEMP_DIR/.pi/agent/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.pi/agent/agents/crew-coder.md" ]
  [ ! -d "$TEMP_DIR/.pi/skills" ]
}

@test "uninstall removes pi-installed skills and agents" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk
  [ -d "$TEMP_DIR/.pi/skills/crew-afk" ]

  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill crew-afk
  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --agent crew-coder

  [ ! -d "$TEMP_DIR/.pi/skills/crew-afk" ]
  [ ! -f "$TEMP_DIR/.pi/agents/crew-coder.md" ]
}

@test "squash-commits.sh accepts --platform pi" {
  cd "$SCRIPT_DIR"
  run grep -n "PLATFORM\" = \"pi\"" skills/crew-afk/scripts/squash-commits.sh
  [ "$status" -eq 0 ]
}

@test "pi install excludes codex's dispatch-codex-agent.sh" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh pi --skill crew-afk

  [ -f "$TEMP_DIR/.pi/skills/crew-afk/scripts/dispatch-agent.sh" ]
  [ ! -f "$TEMP_DIR/.pi/skills/crew-afk/scripts/dispatch-codex-agent.sh" ]
}
