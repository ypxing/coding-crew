# Shared bats helper: paths to *rendered* skill bodies.
#
# Rendering is what the consuming repo actually receives, so body assertions run against
# the rendered result rather than the source file: `render-skill.sh` inlines any
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

# afk_variant <platform> — shorthand for the crew-afk orchestrator body
afk_variant() {
  rendered_skill crew-afk "$1"
}

# Which platforms still ship a *prose* orchestrator, and which ship a launcher.
#
# A launcher platform's orchestrator is a program (`orchestrator/`, installed to
# `.coding-crew/crew-afk/`), so the guarantees the prose assertions described — pipeline
# order, the receipt gates, fail-closed review handling, the promotion threshold — are
# asserted against the code in tests/orchestrator/ instead. Its body is a launcher and
# asserting prose against it would be asserting the absence of a state machine that moved,
# not the presence of one.
#
# Every platform is cut over now, so the prose lists are empty and the suites that looped
# over them are gone (tests/shared-dispatch-body.bats retired with its subject). They stay
# declared, and empty, because `tests/crew-afk-launcher.bats` asserts the launcher list is
# non-empty and several suites still ask `afk_is_launcher`.
AFK_PROSE_VARIANTS=()
AFK_PROSE_DISPATCH_VARIANTS=()
AFK_LAUNCHER_VARIANTS=(pi codex claude copilot)

# afk_launcher_body <platform> — true when this platform ships the launcher, not prose
afk_is_launcher() {
  local want="$1" p
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    [ "$p" = "$want" ] && return 0
  done
  return 1
}
