#!/usr/bin/env bats

# A renamed agent (registry.json `replaces`) must not leave its old definition behind: the host
# would keep listing it as a second, stale agent that nothing updates any more.

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export TEMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# _old_install — the four shims and manifest entry an install from before the rename left
_old_install() {
  mkdir -p "$TEMP_DIR/.claude/agents" "$TEMP_DIR/.github/agents" "$TEMP_DIR/.pi/agents" \
    "$TEMP_DIR/.codex/agents" "$TEMP_DIR/.coding-crew"
  echo old > "$TEMP_DIR/.claude/agents/crew-code-reviewer.md"
  echo old > "$TEMP_DIR/.github/agents/crew-code-reviewer.agent.md"
  echo old > "$TEMP_DIR/.pi/agents/crew-code-reviewer.md"
  echo old > "$TEMP_DIR/.codex/agents/crew-code-reviewer.toml"
  cat > "$TEMP_DIR/.coding-crew/manifest.json" <<'EOF'
{"agents": {"crew-code-reviewer": {"version": "1.7.6", "platform": "all"}}, "skills": {}}
EOF
}

_old_shims_left() {
  find "$TEMP_DIR" -name 'crew-code-reviewer*' -type f
}

@test "registry: crew-reviewer replaces crew-code-reviewer" {
  run jq -r '.agents["crew-reviewer"].replaces[]' "$SCRIPT_DIR/registry.json"
  [ "$output" = "crew-code-reviewer" ]
}

@test "installing over a pre-rename install removes the old shims and manifest entry" {
  _old_install
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh all --skill crew-afk
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed .claude/agents/crew-code-reviewer.md (renamed to crew-reviewer)"* ]]
  [ -z "$(_old_shims_left)" ] || { echo "left behind: $(_old_shims_left)"; return 1; }
  [ -f "$TEMP_DIR/.claude/agents/crew-reviewer.md" ]
  [ -f "$TEMP_DIR/.codex/agents/crew-reviewer.toml" ]
  run jq -r '.agents | keys[]' "$TEMP_DIR/.coding-crew/manifest.json"
  [[ "$output" == *"crew-reviewer"* ]]
  [[ "$output" != *"crew-code-reviewer"* ]]
}

@test "installing one platform removes only that platform's old shim" {
  _old_install
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  [ ! -f "$TEMP_DIR/.claude/agents/crew-code-reviewer.md" ]
  [ -f "$TEMP_DIR/.codex/agents/crew-code-reviewer.toml" ]
}

@test "installing one platform keeps the old manifest entry while another platform still has its shim" {
  # The shared orchestrator now dispatches crew-reviewer, which codex/pi/copilot don't have yet;
  # dropping the old entry would leave --update nothing to repair them from.
  _old_install
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"*"crew-code-reviewer"* ]]
  [[ "$output" == *".codex/agents/crew-code-reviewer.toml"* ]]
  [[ "$output" == *"./install.sh --update"* ]]
  run jq -r '.agents | keys[]' "$TEMP_DIR/.coding-crew/manifest.json"
  [[ "$output" == *"crew-code-reviewer"* ]]
}

@test "--update after a one-platform install brings every platform onto the new name" {
  _old_install
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  [ -z "$(_old_shims_left)" ] || { echo "left behind: $(_old_shims_left)"; return 1; }
  [ -f "$TEMP_DIR/.codex/agents/crew-reviewer.toml" ]
  [ -f "$TEMP_DIR/.pi/agents/crew-reviewer.md" ]
  [ -f "$TEMP_DIR/.github/agents/crew-reviewer.agent.md" ]
  run jq -r '.agents | keys[]' "$TEMP_DIR/.coding-crew/manifest.json"
  [[ "$output" == *"crew-reviewer"* ]]
  [[ "$output" != *"crew-code-reviewer"* ]]
}

@test "--update installs the agent that replaces an old manifest name" {
  _old_install
  jq '.platform = "all"' "$TEMP_DIR/.coding-crew/manifest.json" > "$TEMP_DIR/m" && mv "$TEMP_DIR/m" "$TEMP_DIR/.coding-crew/manifest.json"
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  [[ "$output" != *"removed from registry"* ]]
  [[ "$output" == *"crew-code-reviewer: renamed to crew-reviewer"* ]]
  [ -z "$(_old_shims_left)" ] || { echo "left behind: $(_old_shims_left)"; return 1; }
  [ -f "$TEMP_DIR/.claude/agents/crew-reviewer.md" ]
  [ -f "$TEMP_DIR/.codex/agents/crew-reviewer.toml" ]
  run jq -r '.agents | keys[]' "$TEMP_DIR/.coding-crew/manifest.json"
  [[ "$output" != *"crew-code-reviewer"* ]]
}

@test "install.sh accepts an agent's old name and installs its replacement" {
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude crew-code-reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"crew-code-reviewer was renamed to crew-reviewer"* ]]
  [ -f "$TEMP_DIR/.claude/agents/crew-reviewer.md" ]
  [ ! -e "$TEMP_DIR/.claude/agents/crew-code-reviewer.md" ]
}

@test "install.sh names an unknown agent instead of failing inside find" {
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude no-such-agent
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown agent 'no-such-agent'"* ]]
  [[ "$output" != *"find:"* ]]
}

@test "uninstall --agent accepts an agent's old name" {
  _old_install
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --agent crew-code-reviewer
  [ "$status" -eq 0 ]
  [[ "$output" == *"crew-code-reviewer was renamed to crew-reviewer"* ]]
  [[ "$output" != *"nothing found to remove"* ]]
  [ -z "$(_old_shims_left)" ] || { echo "left behind: $(_old_shims_left)"; return 1; }
}

@test "full uninstall does not depend on grep's handling of an empty -f pattern" {
  # Older BSD grep (macOS) matches every line with an empty -f pattern even under -x, so
  # `grep -v` over a pattern list ending in "" filtered out every agent. Simulate that grep.
  mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/repo/.claude/agents"
  printf '%s\n' '#!/bin/bash' \
    'if [[ "$1" == -v* && "$2" == "-f" ]] && "$REAL_GREP" -qx "" "$3"; then cat >/dev/null; exit 1; fi' \
    'exec "$REAL_GREP" "$@"' > "$TEMP_DIR/bin/grep"
  chmod +x "$TEMP_DIR/bin/grep"
  echo x > "$TEMP_DIR/repo/.claude/agents/crew-coder.md"
  cd "$SCRIPT_DIR"
  run env REAL_GREP="$(command -v grep)" PATH="$TEMP_DIR/bin:$PATH" TARGET_REPO="$TEMP_DIR/repo" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/repo/.claude/agents/crew-coder.md" ]
}

@test "uninstall removes a pre-rename install's old shims too" {
  _old_install
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ -z "$(_old_shims_left)" ] || { echo "left behind: $(_old_shims_left)"; return 1; }
  [[ "$output" != *"crew-code-reviewer: nothing found to remove"* ]]
}

@test "uninstall --agent crew-reviewer removes the old name's shims as well" {
  _old_install
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --agent crew-reviewer
  [ "$status" -eq 0 ]
  [ -z "$(_old_shims_left)" ] || { echo "left behind: $(_old_shims_left)"; return 1; }
}

@test "a project install warns about a user-level copy under the old name" {
  local home="$TEMP_DIR/home" repo="$TEMP_DIR/repo"
  mkdir -p "$home/.claude/agents" "$repo"
  echo old > "$home/.claude/agents/crew-code-reviewer.md"
  cd "$SCRIPT_DIR"
  run env HOME="$home" CLAUDE_CONFIG_DIR= TARGET_REPO="$repo" ./install.sh claude --skill crew-afk
  [ "$status" -eq 0 ]
  [[ "$output" == *"may shadow"* ]]
  [[ "$output" == *"$home/.claude/agents/crew-code-reviewer"* ]]
}
