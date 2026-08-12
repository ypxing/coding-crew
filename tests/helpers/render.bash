# Shared bats helper: paths to *rendered* skill bodies.
#
# crew-afk's remaining prose bodies are not one file per platform — they are one shared
# body (`dispatch.SKILL.md`) plus per-platform fragments, inlined at install time. Prose
# assertions therefore have to run against the rendered result, which is what the
# consuming repo actually receives. Rendering is cached per bats run.

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
# `.coding-crew/crew-afk/`), so the guarantees these prose assertions describe — pipeline
# order, the receipt gates, fail-closed review handling, the promotion threshold — are
# asserted against the code in tests/orchestrator/ instead. Its body is a launcher and
# asserting prose against it would be asserting the absence of a state machine that moved,
# not the presence of one.
#
# As each remaining platform cuts over, its name moves from one list to the other, here,
# once — and the assertions it carried are already covered by the node suite.
AFK_PROSE_VARIANTS=(claude copilot)
AFK_PROSE_DISPATCH_VARIANTS=(copilot)
AFK_LAUNCHER_VARIANTS=(pi codex)

# afk_launcher_body <platform> — true when this platform ships the launcher, not prose
afk_is_launcher() {
  local want="$1" p
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    [ "$p" = "$want" ] && return 0
  done
  return 1
}
