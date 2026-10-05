#!/usr/bin/env bats

# Copilot platform support: the install locations Copilot actually scans.
#
# They were wrong once, which is why a project-level Copilot install looked installed and
# did nothing: resources landed in .copilot/ (which Copilot never reads at project scope).
# Verified against Copilot CLI 1.0.77: a skill under .copilot/skills/ is absent from
# `copilot skill list`, and an agent under .copilot/agents/ does not resolve, while the same
# file under .github/agents/ does.
#
# Dispatch is not asserted here: every role runs as `copilot -p` in its worktree with the
# role's protocol prepended to the prompt and no agent file (orchestrator/lib/adapters/copilot.mjs),
# which tests/orchestrator/dispatch.test.mjs pins.

load helpers/render

setup() {
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# ─── install locations ────────────────────────────────────────────────────────

@test "copilot project install writes skills to .github/skills, not .copilot/skills" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-afk

  [ -f "$TEMP_DIR/.github/skills/crew-afk/SKILL.md" ]
  [ ! -d "$TEMP_DIR/.copilot/skills/crew-afk" ]
  # no .copilot/ tree at all: an empty one only invites a hand-copied file back into it
  [ ! -d "$TEMP_DIR/.copilot" ]
}

@test "copilot project install renders crew-afk at .github/skills with no placeholder left" {
  cd "$SCRIPT_DIR"
  TARGET_REPO="$TEMP_DIR" ./install.sh copilot --skill crew-afk

  [ -f "$TEMP_DIR/.github/skills/crew-afk/SKILL.md" ]
  ! grep -q '{{' "$TEMP_DIR/.github/skills/crew-afk/SKILL.md"
  [ ! -e "$TEMP_DIR/.github/agents" ]
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
#
# See the header: these six tests moved to tests/orchestrator/dispatch.test.mjs, which
# exercises the argv and the preflight instead of grepping a body for the promise of them.
# What stays here is the one dispatch fact that is still the *body's* to carry.

@test "the launcher pre-approves the shell on every platform, and no longer the task tool" {
  body=$(afk_variant copilot)
  run grep -m1 '^allowed-tools:' "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"shell"* ]] || { echo "an unattended sprint would stall on a permission prompt" >&2; return 1; }
  # `task` is the in-session subagent tool. A worker is its own process now, so a body that
  # still pre-approves it is a body that still believes it dispatches.
  [[ "$output" != *"task"* ]]
  ! grep -q 'task(agent_type' "$body"
}

