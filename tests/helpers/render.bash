# Shared bats helper: paths to *rendered* skill bodies.
#
# crew-afk's pi/codex/copilot bodies are no longer three files on disk — they are one
# shared body (`dispatch.SKILL.md`) plus per-platform fragments, inlined at install
# time. Prose assertions therefore have to run against the rendered result, which is
# what the consuming repo actually receives. Rendering is cached per bats run.

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
