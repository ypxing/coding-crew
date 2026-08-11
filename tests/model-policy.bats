#!/usr/bin/env bats

# Tests for explicit, overridable model policy (D1)
# Asserts that:
# - coder declares sonnet as its default model in Claude frontmatter
# - reviewer declares no model (inherits session model)
# - no model: key survives in files that do not honor one (skills frontmatter)

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export CODER_CLAUDE="$SCRIPT_DIR/agents/crew-coder/claude.agent.md"
  export CODER_COPILOT="$SCRIPT_DIR/agents/crew-coder/copilot.agent.md"
  export REVIEWER_CLAUDE="$SCRIPT_DIR/agents/crew-code-reviewer/claude.agent.md"
  export REVIEWER_COPILOT="$SCRIPT_DIR/agents/crew-code-reviewer/copilot.agent.md"
  export CREW_AFK_SKILL="$SCRIPT_DIR/skills/crew-afk/SKILL.md"
  export CREW_AFK_COPILOT="$(afk_variant copilot)"
}

# Extract YAML frontmatter (between first pair of --- delimiters)
frontmatter() {
  awk 'BEGIN{f=0} /^---/{f++; next} f==1{print}' "$1"
}

# --- Coder declares sonnet as default model ---

@test "crew-coder claude.agent.md declares model: sonnet in frontmatter" {
  # Must have model: sonnet in the YAML frontmatter
  frontmatter "$CODER_CLAUDE" | grep -q '^model: sonnet$'
}

@test "crew-coder copilot.agent.md does not declare a model (Copilot has no model control)" {
  # Copilot's crew-coder frontmatter must not contain a model: key
  run bash -c "$(declare -f frontmatter); frontmatter '$CODER_COPILOT' | grep -q '^model:'"
  [ "$status" -ne 0 ]
}

# --- Reviewer declares no model (inherits session model) ---

@test "crew-code-reviewer claude.agent.md does not declare a model (inherits session model)" {
  # Reviewer should NOT pin a model — it inherits the session model
  run bash -c "$(declare -f frontmatter); frontmatter '$REVIEWER_CLAUDE' | grep -q '^model:'"
  [ "$status" -ne 0 ]
}

@test "crew-code-reviewer copilot.agent.md does not declare a model" {
  run bash -c "$(declare -f frontmatter); frontmatter '$REVIEWER_COPILOT' | grep -q '^model:'"
  [ "$status" -ne 0 ]
}

# --- No dead model: key in skill frontmatter that does not honor it ---

@test "crew-afk SKILL.md does not declare a model: key in frontmatter" {
  # Claude Code skills do not honor a model: key — it is dead config
  run bash -c "$(declare -f frontmatter); frontmatter '$CREW_AFK_SKILL' | grep -q '^model:'"
  [ "$status" -ne 0 ]
}

@test "crew-afk copilot.SKILL.md does not declare a model: key in frontmatter" {
  run bash -c "$(declare -f frontmatter); frontmatter '$CREW_AFK_COPILOT' | grep -q '^model:'"
  [ "$status" -ne 0 ]
}

# --- --model flag is documented ---

@test "crew-afk SKILL.md documents --model flag for sprint command" {
  grep -q '\-\-model' "$CREW_AFK_SKILL"
}

@test "crew-afk copilot.SKILL.md documents --model flag" {
  grep -q '\-\-model' "$CREW_AFK_COPILOT"
}

@test "crew-afk copilot.SKILL.md states --model is ignored on Copilot (model is IDE-selected)" {
  grep -A5 '\-\-model' "$CREW_AFK_COPILOT" | grep -qi 'ignored\|no-op\|ide\|not supported\|cannot'
}

# --- Resolved model is logged in orchestrator trace ---

@test "crew-afk SKILL.md logs resolved model to trace before first dispatch" {
  grep -q 'MODEL\|model.*trace\|\[MODEL\]\|resolved model' "$CREW_AFK_SKILL"
}

@test "crew-afk copilot.SKILL.md logs resolved model to trace before first dispatch" {
  grep -q 'MODEL\|model.*trace\|\[MODEL\]\|resolved model' "$CREW_AFK_COPILOT"
}

# --- Resolved model is printed in sprint summary ---

@test "crew-afk SKILL.md includes model in sprint summary" {
  grep -A30 '### Summary' "$CREW_AFK_SKILL" | grep -qi 'model\|MODEL'
}

@test "crew-afk copilot.SKILL.md includes model in sprint summary" {
  grep -A30 'Sprint:\|Code Review\|Worktree Cleanup' "$CREW_AFK_COPILOT" | grep -qi 'model\|MODEL'
}
