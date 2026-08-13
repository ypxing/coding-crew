# Shared bats helper: paths to *rendered* skill bodies.
#
# Rendering is what a consuming repo actually receives, so body assertions run against the
# rendered result rather than the source file: `render-skill.sh` inlines any
# `{{FRAGMENT:...}}` and substitutes `{{PLATFORM}}`. crew-afk's bodies are launchers with
# nothing left to vary, but other skills still render, and a launcher must be asserted
# through the same path that installs it. Rendering is cached per bats run.

RENDER_HELPER_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# rendered_skill <skill> <platform> — prints the path to the rendered SKILL.md
rendered_skill() {
  local skill="$1" platform="$2"
  local cache="${BATS_SUITE_TMPDIR:-${BATS_FILE_TMPDIR:-${TMPDIR:-/tmp}}}/rendered-skills"
  local out="$cache/$skill.$platform.SKILL.md"
  if [ ! -f "$out" ]; then
    mkdir -p "$cache"
    bash "$RENDER_HELPER_REPO_ROOT/scripts/render-skill.sh" "$skill" "$platform" "$out" || return 1
  fi
  printf '%s\n' "$out"
}

# afk_variant <platform> — shorthand for the crew-afk launcher body
afk_variant() {
  rendered_skill crew-afk "$1"
}

# Every platform's crew-afk body is a launcher for the orchestrator program
# (`orchestrator/`, installed to `.coding-crew/crew-afk/`), so the guarantees the prose
# bodies used to promise — pipeline order, the receipt gates, fail-closed review handling,
# the promotion threshold — are asserted against that program in tests/orchestrator/
# instead. There is no prose list any more: `AFK_PROSE_VARIANTS` and its dispatch twin were
# deleted with the last prose body, along with the suite that policed the shared-body
# mechanism.
#
# This list is the single place that says which platforms exist as launchers, read by
# tests/crew-afk-launcher.bats and tests/orchestrator/contract.test.mjs.
AFK_LAUNCHER_VARIANTS=(pi codex claude copilot)
