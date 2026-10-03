#!/usr/bin/env bats

# crew-afk dispatches every role from its rendered protocol, so no platform gets an agent file:
# agents/<name>/ holds protocol.md (and assets/), install writes the protocol under .coding-crew/,
# and an update removes the shims an older install wrote.

load helpers/render

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  T="$(mktemp -d)"
}
teardown() { rm -rf "$T"; }

AGENT_DIRS=(.claude/agents .github/agents .pi/agents .codex/agents .copilot/agents)

@test "agents/*/ contains only protocol.md and assets/" {
  for d in "$REPO_ROOT"/agents/*/; do
    for e in "$d"*; do
      case "$(basename "$e")" in protocol.md|assets) ;; *) echo "unexpected: $e"; return 1 ;; esac
    done
    [ -f "$d/protocol.md" ]
  done
}

@test "a fresh install writes no agent file and installs each protocol under .coding-crew/" {
  (cd "$REPO_ROOT" && TARGET_REPO="$T" ./install.sh all --skill crew-afk >/dev/null)
  for d in "${AGENT_DIRS[@]}"; do
    [ ! -e "$T/$d" ] || { echo "found $d"; return 1; }
  done
  for a in crew-coder crew-reviewer crew-triage; do
    [ -f "$T/.coding-crew/agents/$a/protocol.md" ]
  done
  [ -f "$T/.coding-crew/skills/_shared/fragments/common/findings-rubric.md" ]
}

@test "--update removes the shims an older install wrote and nothing else in those dirs" {
  (cd "$REPO_ROOT" && TARGET_REPO="$T" ./install.sh all --skill crew-afk >/dev/null)
  mkdir -p "$T/.claude/agents" "$T/.github/agents" "$T/.pi/agents" "$T/.codex/agents"
  for a in crew-coder crew-reviewer crew-triage; do
    echo old > "$T/.claude/agents/$a.md"
    echo old > "$T/.github/agents/$a.agent.md"
    echo old > "$T/.pi/agents/$a.md"
    echo old > "$T/.codex/agents/$a.toml"
  done
  echo mine > "$T/.claude/agents/mine.md"
  # An older version in the manifest makes --update reinstall.
  jq '.agents |= with_entries(.value.version = "0.0.1")' "$T/.coding-crew/manifest.json" > "$T/m.json" && mv "$T/m.json" "$T/.coding-crew/manifest.json"
  (cd "$REPO_ROOT" && TARGET_REPO="$T" ./install.sh --update >/dev/null)
  [ "$(ls "$T/.claude/agents")" = "mine.md" ]
  for d in .github/agents .pi/agents .codex/agents; do [ ! -e "$T/$d" ] || { echo "left $d"; return 1; }; done
}

@test "uninstall removes the installed protocols" {
  (cd "$REPO_ROOT" && TARGET_REPO="$T" ./install.sh claude --skill crew-afk >/dev/null)
  (cd "$REPO_ROOT" && TARGET_REPO="$T" ./uninstall.sh claude >/dev/null)
  [ ! -e "$T/.coding-crew/agents" ]
  [ ! -e "$T/.coding-crew/skills/_shared/fragments" ]
}

@test "the rendered crew-afk launchers name no agent file" {
  for p in claude copilot pi codex; do
    run cat "$(afk_variant "$p")"
    if echo "$output" | grep -qE '\.claude/agents|\.github/agents|\.pi/agents|\.codex/agents|--agent|agent definition'; then
      echo "$p launcher names an agent file"; return 1
    fi
  done
}
