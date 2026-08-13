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

# ─── agent bodies ────────────────────────────────────────────────────────────
# An agent body is assembled at install time too: install.sh substitutes {{PROTOCOL}}
# with agents/<agent>/protocol.md. crew-coder's four platform files are therefore a
# frontmatter block plus a short platform block, and the instructions a worker actually
# receives exist only after that substitution — so body assertions run against the
# *installed* file, exactly as for skills.
#
# The rendering is done by running install.sh, not by re-implementing its substitution:
# a second inliner is a second thing to drift. One install per bats run, cached.

# installed_agents_root — prints a dir containing one full install of every platform
installed_agents_root() {
  local cache="${BATS_SUITE_TMPDIR:-${BATS_FILE_TMPDIR:-${TMPDIR:-/tmp}}}/installed-agents"
  if [ ! -d "$cache/.claude/agents" ]; then
    mkdir -p "$cache"
    git -C "$cache" init -q 2>/dev/null || true
    ( cd "$RENDER_HELPER_REPO_ROOT" && TARGET_REPO="$cache" ./install.sh >/dev/null ) || return 1
  fi
  printf '%s\n' "$cache"
}

# coder_variant <platform> — prints the path to the installed crew-coder body
coder_variant() {
  local platform="$1" root
  root=$(installed_agents_root) || return 1
  case "$platform" in
    claude)  printf '%s\n' "$root/.claude/agents/crew-coder.md" ;;
    copilot) printf '%s\n' "$root/.github/agents/crew-coder.agent.md" ;;
    pi)      printf '%s\n' "$root/.pi/agents/crew-coder.md" ;;
    codex)   printf '%s\n' "$root/.codex/agents/crew-coder.toml" ;;
    *) echo "coder_variant: unknown platform '$platform'" >&2; return 1 ;;
  esac
}

# The one list of platforms crew-coder is built for, read by tests/crew-coder-protocol.bats
# and by every suite that asserts on a worker body.
CODER_VARIANTS=(pi codex claude copilot)

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
