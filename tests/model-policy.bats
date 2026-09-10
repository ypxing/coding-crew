#!/usr/bin/env bats

# Tests for explicit, overridable model policy (D1, revised)
# Asserts that:
# - coder, reviewer and triage all declare no model in Claude frontmatter — each inherits
#   the session model unless crew-afk's own model-config.mjs resolves and passes one
#   explicitly (its claude-platform coder default lives in CLAUDE_DEFAULT_CODER_MODEL, not
#   here, so it stays visible to the reviewer/triage "never weaker than coder" check)
# - no model: key survives in files that do not honor one (skills frontmatter)

load helpers/render

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export CODER_CLAUDE="$(coder_variant claude)"
  export CODER_COPILOT="$(coder_variant copilot)"
  export REVIEWER_CLAUDE="$SCRIPT_DIR/agents/crew-code-reviewer/claude.agent.md"
  export REVIEWER_COPILOT="$SCRIPT_DIR/agents/crew-code-reviewer/copilot.agent.md"
  export CREW_AFK_SKILL="$SCRIPT_DIR/skills/crew-afk/claude.SKILL.md"
  export CREW_AFK_COPILOT="$(afk_variant copilot)"
}

# Extract YAML frontmatter (between first pair of --- delimiters)
frontmatter() {
  awk 'BEGIN{f=0} /^---/{f++; next} f==1{print}' "$1"
}

# --- Coder declares no model (crew-afk resolves and passes it explicitly instead) ---

@test "crew-coder claude.agent.md does not declare a model (crew-afk resolves it centrally)" {
  # A default living only in frontmatter would be invisible to model-config.mjs's
  # reviewer/triage "never weaker than coder" check — see CLAUDE_DEFAULT_CODER_MODEL.
  run bash -c "$(declare -f frontmatter); frontmatter '$CODER_CLAUDE' | grep -q '^model:'"
  [ "$status" -ne 0 ]
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

# "--model is ignored on Copilot" was true of the prose body: the model was session-selected
# and `task` took no model argument. A worker is its own `copilot -p` process now, so the flag
# reaches the CLI — asserted in tests/orchestrator/dispatch.test.mjs, "copilot's --model is a
# real flag now, not accepted-and-ignored".

@test "crew-afk copilot.SKILL.md no longer claims --model is ignored" {
  ! grep -qi 'model.*is ignored\|ignored on Copilot\|IDE-selected\|session-selected' "$CREW_AFK_COPILOT"
}

# --- Resolved model is logged in the trace and printed in the summary ---
#
# Both were prose steps in the claude body ("log the resolved model before the first
# dispatch", "include it in the summary"). Every platform is a launcher now, so they are
# code: orchestrator/main.mjs calls sprint.setModel(), which writes the MODEL trace line, and
# crew-summary.sh renders `Model:` from sprint-state.json. Asserted in
# tests/orchestrator/sprint.test.mjs — "the summary names the resolved model, rendered
# from disk". The copilot-body versions of those two greps went with the body.
