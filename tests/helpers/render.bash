# Shared bats helper: paths to *rendered* skill bodies.
#
# Rendering is what a consuming repo actually receives, so body assertions run against the
# rendered result rather than the source file: `render-skill.sh` inlines any
# `{{FRAGMENT:...}}`. Every platform receives the same body.
#
# Caching: keyed by a content hash of everything that can change a rendered result
# (skills/, scripts/ and the renderer, registry.json, install.sh), stored under a fixed path
# outside any single bats run's own tmpdir. `install.sh` alone spawns ~84 `jq` calls, and
# on Git Bash (no real fork()) that dwarfs everything else the suite does — so a cache
# keyed to *bats' own tmpdir* (as this used to be) paid that cost again on every separate
# `bats` invocation, which is most of them in a local edit/run/edit loop. A content hash is
# a few file reads, not a process per source file: `find | sort | xargs sha256sum` batches
# every file into one or two spawns. A hash miss (something actually changed) still pays
# the real cost once; a hit — the common case when re-running tests without touching the
# rendered inputs — costs nothing. CI is unaffected: every job starts from a fresh clone,
# so it is a hash miss exactly as often as before. Stale generations are left under
# /tmp rather than pruned here, to avoid a concurrent bats run racing a delete against a
# reader; ordinary OS tmp cleanup (or a manual `rm -rf`) reclaims them.

RENDER_HELPER_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_render_cache_key() {
  local root="$RENDER_HELPER_REPO_ROOT" hasher
  if command -v sha256sum >/dev/null 2>&1; then hasher=(sha256sum); else hasher=(shasum -a 256); fi
  { find "$root/skills" "$root/scripts" -type f 2>/dev/null
    printf '%s\n' "$root/registry.json" "$root/install.sh"
  } | LC_ALL=C sort | xargs "${hasher[@]}" | "${hasher[@]}" | awk '{print $1}'
}

# _render_cache_root — prints (and creates) the cache dir for the current source state
_render_cache_root() {
  local base="${CODING_CREW_RENDER_CACHE:-${TMPDIR:-/tmp}/coding-crew-render-cache}"
  local key
  key=$(_render_cache_key) || return 1
  printf '%s\n' "$base/$key"
}

# rendered_skill <skill> — prints the path to the rendered SKILL.md
rendered_skill() {
  local skill="$1"
  local cache="$(_render_cache_root)/rendered-skills"
  local out="$cache/$skill.SKILL.md"
  if [ ! -f "$out" ]; then
    mkdir -p "$cache"
    # Rendered beside and renamed into place: CI runs bats files concurrently, and a
    # reader must never see a half-written body.
    bash "$RENDER_HELPER_REPO_ROOT/scripts/render-skill.sh" "$skill" "$out.$$" || return 1
    mv -f "$out.$$" "$out"
  fi
  printf '%s\n' "$out"
}

# The platform list, from platforms.json (helpers/platforms.bash).
source "$(dirname "${BASH_SOURCE[0]}")/platforms.bash"
