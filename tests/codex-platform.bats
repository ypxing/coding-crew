#!/usr/bin/env bats

# codex platform support: install paths, agent TOML shims, skill variants, dispatch script

load helpers/render

setup() {
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

@test "codex is an accepted platform and skills land in .agents/skills" {
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill tdd
  [ "$status" -eq 0 ]
  # Codex scans .agents/skills, never .codex/skills
  [ -f "$TEMP_DIR/.agents/skills/tdd/SKILL.md" ]
  [ ! -d "$TEMP_DIR/.codex/skills" ]
}

@test "codex crew-afk SKILL.md is the codex variant with no leftover variants" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk

  grep -q "run --platform codex " "$TEMP_DIR/.agents/skills/crew-afk/SKILL.md"
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/codex.SKILL.md" ]
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/pi.SKILL.md" ]
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/copilot.SKILL.md" ]
}

@test "uninstall removes codex-installed skills and agents" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk
  [ -d "$TEMP_DIR/.agents/skills/crew-afk" ]

  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill crew-afk
  TARGET_REPO="$TEMP_DIR" ./uninstall.sh --agent crew-coder

  [ ! -d "$TEMP_DIR/.agents/skills/crew-afk" ]
  [ ! -f "$TEMP_DIR/.codex/agents/crew-coder.toml" ]
}

@test "squash-commits.sh accepts --platform codex" {
  cd "$SCRIPT_DIR"
  run grep -n 'PLATFORM" = "codex"' skills/crew-afk/scripts/squash-commits.sh
  [ "$status" -eq 0 ]
}

@test "codex crew-afk skill does not reference pi paths or the pi dispatch script" {
  cd "$SCRIPT_DIR"
  run grep -n '\.pi/\|dispatch-agent\.sh\|pi -p' "$(afk_variant codex)"
  [ "$status" -ne 0 ]
}

@test "codex install ships no bash dispatcher, and an update prunes one an older install left" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" ]
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-agent.sh" ]
  touch "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-agent.sh"

  TARGET_REPO="$TEMP_DIR" ./install.sh codex --skill crew-afk
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-codex-agent.sh" ]
  [ ! -f "$TEMP_DIR/.agents/skills/crew-afk/scripts/dispatch-agent.sh" ]
}
