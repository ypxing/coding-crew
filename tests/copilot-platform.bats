#!/usr/bin/env bats

# Copilot platform support: install locations Copilot actually scans, and the dispatch
# mechanism the Copilot CLI actually has.
#
# Both were wrong at the same time, which is why a project-level Copilot install looked
# installed and did nothing: resources landed in .copilot/ (which Copilot never reads at
# project scope) and the orchestrator body told the model to dispatch with
# `#runSubagent` (VS Code Copilot Chat syntax that does not exist in the CLI).
# Verified against Copilot CLI 1.0.77:
#   - a skill under .copilot/skills/ is absent from `copilot skill list`
#   - `task(agent_type=...)` on an agent under .copilot/agents/ answers
#     "Unknown agent_type", while the same file under .github/agents/ resolves

load helpers/render

setup() {
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# ─── install locations ────────────────────────────────────────────────────────

@test "copilot project install writes agents to .github/agents, not .copilot/agents" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-afk

  [ -f "$TEMP_DIR/.github/agents/crew-coder.agent.md" ]
  [ -f "$TEMP_DIR/.github/agents/crew-code-reviewer.agent.md" ]
  [ ! -e "$TEMP_DIR/.copilot/agents/crew-coder.agent.md" ]
}

@test "copilot project install writes skills to .github/skills, not .copilot/skills" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-afk

  [ -f "$TEMP_DIR/.github/skills/crew-afk/SKILL.md" ]
  [ ! -d "$TEMP_DIR/.copilot/skills/crew-afk" ]
  # no .copilot/ tree at all: an empty one only invites a hand-copied file back into it
  [ ! -d "$TEMP_DIR/.copilot" ]
}

@test "copilot project install still expands {{PROTOCOL}} at the new location" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-afk

  ! grep -q '{{PROTOCOL}}' "$TEMP_DIR/.github/agents/crew-code-reviewer.agent.md"
  ! grep -q '{{FRAGMENT' "$TEMP_DIR/.github/skills/crew-afk/SKILL.md"
}

@test "a user-level copilot install keeps ~/.copilot paths" {
  cd "$SCRIPT_DIR"
  # A user-level install is TARGET_REPO=$HOME; fake HOME so the real one is untouched.
  run env HOME="$TEMP_DIR" TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-afk
  [ "$status" -eq 0 ]

  [ -f "$TEMP_DIR/.copilot/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.copilot/agents/crew-coder.agent.md" ]
  [ ! -d "$TEMP_DIR/.github/agents" ]
}

@test "re-install removes a legacy .copilot/ project copy left by an older install" {
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/.copilot/agents" "$TEMP_DIR/.copilot/skills/crew-afk"
  echo "stale agent" > "$TEMP_DIR/.copilot/agents/crew-coder.agent.md"
  echo "stale body" > "$TEMP_DIR/.copilot/skills/crew-afk/SKILL.md"

  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-afk

  [ ! -e "$TEMP_DIR/.copilot/agents/crew-coder.agent.md" ]
  [ ! -e "$TEMP_DIR/.copilot/skills/crew-afk/SKILL.md" ]
  [ -f "$TEMP_DIR/.github/agents/crew-coder.agent.md" ]
}

@test "uninstall sweeps both the current and the legacy copilot locations" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-afk >/dev/null
  mkdir -p "$TEMP_DIR/.copilot/agents" "$TEMP_DIR/.copilot/skills/crew-afk"
  echo "stale agent" > "$TEMP_DIR/.copilot/agents/crew-coder.agent.md"
  echo "stale body" > "$TEMP_DIR/.copilot/skills/crew-afk/SKILL.md"

  run env TARGET_REPO="$TEMP_DIR" ./uninstall.sh
  [ "$status" -eq 0 ]

  [ ! -d "$TEMP_DIR/.copilot" ]
  [ ! -d "$TEMP_DIR/.github/agents" ]
  [ ! -d "$TEMP_DIR/.github/skills" ]
}

# ─── dispatch mechanism ──────────────────────────────────────────────────────

@test "the copilot orchestrator dispatches with the task tool" {
  body=$(afk_variant copilot)
  grep -q 'task(agent_type="crew-coder"' "$body"
  grep -q 'task(agent_type="crew-code-reviewer"' "$body"
}

@test "the copilot orchestrator never instructs a bare #runSubagent dispatch" {
  body=$(afk_variant copilot)
  # The name may appear only where it is being ruled out for the CLI.
  while IFS= read -r line; do
    [[ "$line" == *"VS Code"* ]] && continue
    echo "unqualified #runSubagent instruction: $line" >&2
    return 1
  done < <(grep '#runSubagent' "$body" || true)
}

@test "the copilot orchestrator names the agent locations Copilot scans" {
  body=$(afk_variant copilot)
  grep -q '\.github/agents/' "$body"
  grep -q '~/\.copilot/agents/' "$body"
  # and says plainly that the old project path is dead
  grep -q '\.copilot/agents/` copy is never loaded' "$body"
}

@test "a rejected dispatch is reported, never silently self-implemented" {
  body=$(afk_variant copilot)
  grep -q 'Unknown agent_type' "$body"
  grep -qi 'never implement the issue yourself' "$body"
}

@test "the copilot skill pre-approves the task tool so a sprint cannot stall on a prompt" {
  body=$(afk_variant copilot)
  run grep -m1 '^allowed-tools:' "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"task"* ]]
  [[ "$output" == *"shell"* ]]
}

@test "copilot model resolution describes session selection, not a nonexistent parameter" {
  body=$(afk_variant copilot)
  grep -q 'session-selected' "$body"
  ! grep -q 'IDE-selected' "$body"
}
