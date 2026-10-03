#!/usr/bin/env bats

# crew-afk's roles (coder, reviewer, triage) used to install as per-platform agent files, and
# crew-reviewer was crew-code-reviewer before that. An install from either era must not leave
# those files behind: a host keeps listing each as a stale agent that nothing updates any more.
# registry.json `retired-agents` names them; install.sh (crew-afk) and uninstall.sh remove them.

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export TEMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# _old_install — what an install from before the roles moved into crew-afk left behind
_old_install() {
  mkdir -p "$TEMP_DIR/.claude/agents" "$TEMP_DIR/.github/agents" "$TEMP_DIR/.pi/agents" \
    "$TEMP_DIR/.codex/agents" "$TEMP_DIR/.coding-crew/agents/crew-coder" "$TEMP_DIR/.coding-crew/code-review"
  echo old > "$TEMP_DIR/.claude/agents/crew-code-reviewer.md"
  echo old > "$TEMP_DIR/.claude/agents/crew-coder.md"
  echo old > "$TEMP_DIR/.github/agents/crew-reviewer.agent.md"
  echo old > "$TEMP_DIR/.pi/agents/crew-triage.md"
  echo old > "$TEMP_DIR/.codex/agents/crew-coder.toml"
  echo old > "$TEMP_DIR/.coding-crew/agents/crew-coder/protocol.md"
  echo mine > "$TEMP_DIR/.claude/agents/my-own.md"
  cat > "$TEMP_DIR/.coding-crew/manifest.json" <<'EOF'
{"platform": "all", "agents": {"crew-coder": {"version": "1.10.8", "platform": "all"}, "crew-code-reviewer": {"version": "1.7.6", "platform": "all"}}, "skills": {}}
EOF
}

_retired_left() {
  find "$TEMP_DIR" \( -name 'crew-code-reviewer*' -o -name 'crew-coder*' -o -name 'crew-reviewer*' -o -name 'crew-triage*' \) -type f
}

@test "registry: the retired agents include every role and the pre-rename reviewer" {
  run jq -r '."retired-agents".names[]' "$SCRIPT_DIR/registry.json"
  for n in crew-coder crew-reviewer crew-triage crew-code-reviewer; do
    [[ "$output" == *"$n"* ]] || { echo "missing $n"; return 1; }
  done
  run jq -r 'has("agents")' "$SCRIPT_DIR/registry.json"
  [ "$output" = "false" ]
}

@test "installing crew-afk for one platform removes only that platform's retired files" {
  _old_install
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill crew-afk >/dev/null
  [ ! -f "$TEMP_DIR/.claude/agents/crew-code-reviewer.md" ]
  [ ! -f "$TEMP_DIR/.claude/agents/crew-coder.md" ]
  [ -f "$TEMP_DIR/.claude/agents/my-own.md" ]
  [ -f "$TEMP_DIR/.codex/agents/crew-coder.toml" ]
  [ ! -d "$TEMP_DIR/.coding-crew/agents" ]
  [ ! -d "$TEMP_DIR/.coding-crew/code-review" ]
  [ -f "$TEMP_DIR/.coding-crew/crew-afk/roles/coder.md" ]
}

@test "--update of an install that lists agents installs crew-afk, prunes them and drops them from the manifest" {
  _old_install
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh --update
  [ "$status" -eq 0 ]
  [[ "$output" == *"now part of crew-afk"* ]]
  [ -z "$(_retired_left)" ] || { echo "left behind: $(_retired_left)"; return 1; }
  [ -f "$TEMP_DIR/.claude/agents/my-own.md" ]
  run jq -r 'has("agents")' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$output" = "false" ]
  run jq -r '.skills | has("crew-afk")' "$TEMP_DIR/.coding-crew/manifest.json"
  [ "$output" = "true" ]
}

@test "install.sh <platform> <retired agent> installs crew-afk, which now holds the role" {
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude crew-coder
  [ "$status" -eq 0 ]
  [[ "$output" == *"crew-coder is now a role inside crew-afk"* ]]
  [ -f "$TEMP_DIR/.claude/skills/crew-afk/SKILL.md" ]
}

@test "install.sh names an unknown argument" {
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh claude no-such-agent
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument 'no-such-agent'"* ]]
}

@test "uninstall --agent is refused and removes nothing" {
  _old_install
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --agent crew-coder
  [ "$status" -eq 1 ]
  [[ "$output" == *"--skill crew-afk"* ]]
  [ -f "$TEMP_DIR/.claude/agents/crew-coder.md" ]
}

@test "uninstall of an unknown argument is refused rather than removing everything" {
  _old_install
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --no-such-flag
  [ "$status" -ne 0 ]
  [ -f "$TEMP_DIR/.claude/agents/crew-coder.md" ]
}

@test "a full uninstall removes every retired file on every platform, and the user's own stay" {
  _old_install
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ -z "$(_retired_left)" ] || { echo "left behind: $(_retired_left)"; return 1; }
  [ ! -d "$TEMP_DIR/.coding-crew/agents" ]
  [ -f "$TEMP_DIR/.claude/agents/my-own.md" ]
}

@test "uninstall --skill crew-afk removes the retired files too" {
  _old_install
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh --skill crew-afk
  [ "$status" -eq 0 ]
  [ -z "$(_retired_left)" ] || { echo "left behind: $(_retired_left)"; return 1; }
}

@test "a project install warns about a user-level copy of a retired agent" {
  local home="$TEMP_DIR/home" repo="$TEMP_DIR/repo"
  mkdir -p "$home/.claude/agents" "$repo"
  echo old > "$home/.claude/agents/crew-code-reviewer.md"
  cd "$SCRIPT_DIR"
  run env HOME="$home" CLAUDE_CONFIG_DIR= TARGET_REPO="$repo" ./install.sh claude --skill crew-afk
  [ "$status" -eq 0 ]
  [[ "$output" == *"may shadow"* ]]
  [[ "$output" == *"$home/.claude/agents/crew-code-reviewer"* ]]
}
