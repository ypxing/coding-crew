#!/bin/bash
# The kernel resolves `#!/bin/bash` to macOS's frozen bash 3.2, never a newer one on PATH, and the
# registry cache below needs `declare -A` (bash >= 4): re-exec under a newer bash before anything runs.
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 && -z "${_CODING_CREW_REEXEC:-}" ]]; then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/local/opt/bash/bin/bash $(command -v bash 2>/dev/null); do
    [[ -x "$_candidate" ]] || continue
    _candidate_major=$("$_candidate" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null) || continue
    if [[ "$_candidate_major" =~ ^[0-9]+$ && "$_candidate_major" -ge 4 ]]; then
      export _CODING_CREW_REEXEC=1
      exec "$_candidate" "$0" "$@"
    fi
  done
  echo "Error: coding-crew's install.sh requires bash >= 4 (found bash ${BASH_VERSION:-unknown})." >&2
  echo "On macOS this is Apple's stock /bin/bash. Install a newer bash and re-run, e.g.:" >&2
  echo "  brew install bash" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REPO_ROOT="${TARGET_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

UPDATE_MODE=false
SKILLS_LIST=""  # comma-separated list from --skills a,b,c
if [[ "${1:-}" == "--update" ]]; then
  UPDATE_MODE=true
  PLATFORM="all"
  AGENT="all"
else
  PLATFORM="${1:-all}"    # all | a platform in orchestrator/platforms.json
  AGENT="${2:-all}"       # all | --skill <name> | --skills a,b
fi

if [[ "$AGENT" == "--skills" ]]; then
  SKILLS_LIST="${3:-}"
  if [[ -z "$SKILLS_LIST" ]]; then
    echo "Error: --skills requires a comma-separated list (e.g. --skills tdd,to-issues)" >&2
    usage
  fi
  AGENT="--skill"  # normalise so later dispatch hits the skill path
fi

INSTALLED=""
MANIFEST_SKILL_ENTRIES=()  # each entry: "name version"

usage() {
  echo "Usage: ./install.sh [platform]"
  echo "       ./install.sh [platform] --skill <skill-name>"
  echo "       ./install.sh [platform] --skills <a,b,c>"
  echo "       ./install.sh --update"
  echo ""
  local known="a platform in orchestrator/platforms.json"
  [[ ${#PLATFORMS[@]} -gt 0 ]] && known=$(platforms_joined ", ")
  echo "  platform:  all (default), $known"
  echo "  --skill:   install a single skill (e.g. to-issues)"
  echo "  --skills:  install multiple skills (comma-separated, e.g. tdd,to-issues,to-prd);"
  echo "             treated as the full desired set — any skill from a prior --skills"
  echo "             install that's missing from this list is uninstalled"
  echo "  --update:  re-install only skills whose version changed since last install"
  echo ""
  echo "Examples:"
  echo "  ./install.sh                                      # install everything into project"
  echo "  ./install.sh claude --skill tdd                   # one skill into project"
  echo "  ./install.sh claude --skills tdd,to-issues          # multiple skills at once"
  echo "  ./install.sh claude --skill crew-afk              # crew-afk and the skills its roles follow"
  echo "  ./install.sh --update                             # update all installed skills"
  echo ""
  echo "Available skills:"
  echo "  $(jq -r '.skills | keys | join(", ")' "$SCRIPT_DIR/registry.json" 2>/dev/null || echo "(needs jq to list)")"
  echo ""
  echo "Set TARGET_REPO to install into a different repo root."
  echo "A user-level install (TARGET_REPO=\$HOME) honors each platform's own config-dir override:"
  local i overrides=""
  for i in "${!PLATFORMS[@]}"; do overrides="${overrides:+$overrides, }${_PF_ENV[$i]} (${PLATFORMS[$i]})"; done
  echo "  ${overrides:-the configDirEnv of each entry in orchestrator/platforms.json}."
  exit 1
}

# Help needs no dependency: usage() says where the platform list lives when jq is missing.
PLATFORMS=(); _PF_ENV=()
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  command -v jq >/dev/null 2>&1 && source "$SCRIPT_DIR/scripts/lib/platforms.sh"
  usage
fi

_required_cmds=("jq" "git")
for cmd in "${_required_cmds[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: required command '$cmd' not found" >&2; exit 1; }
done

# jq on Windows (Git Bash) leaves a trailing \r inside every value, so a skill read as 'tdd\r'
# silently misses registry.json: normalise once, after the dependency check (`command -v jq`).
# Command substitution, not `| tr -d '\r'`: Git Bash emulates fork(), so extra processes over
# ~1,500 jq calls dominate an install; `$?` after the assignment is still jq's own status.
# The probe reads through `read`: `$(…)` strips the CR itself, so it would never see one.
_jq_probe=""
IFS= read -r _jq_probe < <(command jq -rn '"probe"' 2>/dev/null) || true
if [[ "$_jq_probe" == *$'\r' ]]; then
  jq() {
    local _jq_out _jq_rc
    _jq_out=$(command jq "$@")
    _jq_rc=$?
    # No output must stay no output, or every `while read` loop gets one blank iteration.
    [[ -n "$_jq_out" ]] && printf '%s\n' "${_jq_out//$'\r'/}"
    return "$_jq_rc"
  }
fi

source "$SCRIPT_DIR/scripts/lib/platforms.sh"

if [[ "$UPDATE_MODE" == "false" ]]; then
  if [[ "${1:-}" == "--skill" ]]; then
    echo "Error: platform argument required before flag (e.g. ./install.sh claude --skill to-issues)" >&2
    usage
  fi

  if [[ "$PLATFORM" != "all" ]] && ! platform_known "$PLATFORM"; then
    echo "Error: invalid platform '$PLATFORM' — must be: all, $(platforms_joined ", ") (from orchestrator/platforms.json)" >&2
    usage
  fi
fi

if [[ -n "${TARGET_REPO:-}" ]]; then
  [[ "$REPO_ROOT" =~ ^/ ]] || { echo "Error: TARGET_REPO must be an absolute path" >&2; exit 1; }
  [[ -d "$REPO_ROOT" ]] || { echo "Error: TARGET_REPO does not exist: $REPO_ROOT" >&2; exit 1; }
fi

assert_safe_path() {
  local path="$1" label="$2"
  if [[ "$path" == *..* || "$path" == /* ]]; then
    echo "Error: unsafe $label path in registry: $path" >&2
    exit 1
  fi
}

# Copilot does not scan .copilot/ at project scope: remove that dead copy once the resource lands in .github/.
prune_legacy_copilot_path() {
  local platform="$1" original="$2"
  [[ "$platform" == "copilot" ]] || return 0
  [[ "$original" == .copilot/* ]] || return 0
  [[ "$REPO_ROOT" != "$HOME" ]] || return 0
  [[ -e "$REPO_ROOT/$original" ]] || return 0
  rm -rf "$REPO_ROOT/$original"
  echo "  removed legacy $original (Copilot reads .github/ at project scope)"
  rmdir "$REPO_ROOT/.copilot/agents" "$REPO_ROOT/.copilot/skills" "$REPO_ROOT/.copilot" 2>/dev/null || true
}

# Retired role agent files are stale definitions a host still lists: every install removes each,
# on every platform, by exact path (registry.json `retired-agents`), plus their .coding-crew/ dirs.
prune_retired_agents() {
  [[ "$INSTALLED" != *"|retired-agents|"* ]] || return 0
  INSTALLED="${INSTALLED}|retired-agents|"
  local platform name raw dir names
  names=$(jq -r '."retired-agents".names // [] | .[]' "$SCRIPT_DIR/registry.json")
  for platform in "${PLATFORMS[@]}"; do
    raw=$(jq -r --arg p "$platform" '."retired-agents".paths[$p] // empty' "$SCRIPT_DIR/registry.json")
    [[ -n "$raw" ]] || continue
    while IFS= read -r name; do
      name="${name%$'\r'}"
      [[ -n "$name" ]] || continue
      local path="${raw//\{name\}/$name}"
      assert_safe_path "$path" "$platform retired agent"
      prune_legacy_copilot_path "$platform" "$path"
      resolve_dest "$platform" "$(platform_scope_path "$platform" "$path")"
      if [[ -f "$_DEST_ROOT/$_DEST_REL" ]]; then
        rm -f "$_DEST_ROOT/$_DEST_REL"
        echo "  removed $_DEST_REL (agent files are no longer installed)"
        prune_empty_agent_dirs "$_DEST_ROOT" "$_DEST_REL"
      fi
    done <<< "$names"
  done
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    assert_safe_path "$dir" "retired agent dir"
    if [[ -d "$REPO_ROOT/$dir" ]]; then
      rm -rf "$REPO_ROOT/$dir"
      echo "  removed $dir/ (now under .coding-crew/crew-afk/roles/)"
    fi
  done < <(jq -r '."retired-agents".dirs // [] | .[]' "$SCRIPT_DIR/registry.json")
}

# Retired tracker shell wrappers are a second answer that can go stale: every install removes each
# by exact path (registry.json `retired-scripts`), then the directory once nothing else is in it.
prune_retired_scripts() {
  [[ "$INSTALLED" != *"|retired-scripts|"* ]] || return 0
  INSTALLED="${INSTALLED}|retired-scripts|"
  local path
  while IFS= read -r path; do
    path="${path%$'\r'}"
    [[ -n "$path" ]] || continue
    assert_safe_path "$path" "retired script"
    if [[ -f "$REPO_ROOT/$path" ]]; then
      rm -f "$REPO_ROOT/$path"
      echo "  removed $path (callers run tracker/cli.mjs directly)"
      rmdir "$(dirname "$REPO_ROOT/$path")" 2>/dev/null || true
    fi
  done < <(jq -r '."retired-scripts" // [] | .[]' "$SCRIPT_DIR/registry.json")
}

# Drop the agents/ dir an emptied legacy shim left behind (never one with anything else in it).
prune_empty_agent_dirs() {
  local root="$1" rel="$2" d
  d="$(dirname "$rel")"
  while [[ "$d" != "." && "$d" != "/" ]]; do
    rmdir "$root/$d" 2>/dev/null || break
    d="$(dirname "$d")"
  done
}

assert_identifier() {
  local val="$1" label="$2"
  if [[ ! "$val" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "Error: invalid $label name '$val' — must match [a-zA-Z0-9_.-]+" >&2
    exit 1
  fi
}

# install_single_skill recurses once per platform under PLATFORM=all, and most registry fields do
# not vary by platform, so they are memoized by skill: a full install would spawn ~2,400 jq
# processes otherwise, and Git Bash has no real fork().
declare -A _SKILL_META_SCALAR
declare -A _SKILL_META_LIST

# _skill_scalar/_skill_list set a global result rather than print for `$(...)`/`<(...)`: a subshell's
# writes to the cache arrays vanish when it exits, so every call would miss.
#
# _skill_scalar <skill> <cache-suffix> <jq-filter> [<extra-arg-name> <extra-arg-value>]...
# Extra --arg pairs are folded into the cache key, so a per-platform field caches per platform.
_SKILL_SCALAR=""
_skill_scalar() {
  local skill="$1" suffix="$2" filter="$3"; shift 3
  local key="$skill::$suffix" jq_args=(--arg s "$skill")
  while [[ $# -gt 0 ]]; do jq_args+=(--arg "$1" "$2"); key="$key::$2"; shift 2; done
  if [[ -z "${_SKILL_META_SCALAR[$key]+x}" ]]; then
    _SKILL_META_SCALAR[$key]=$(jq -r "${jq_args[@]}" "$filter" "$SCRIPT_DIR/registry.json")
  fi
  _SKILL_SCALAR="${_SKILL_META_SCALAR[$key]}"
}

# _skill_list — same, for a 0+ line list; feed $_SKILL_LIST to `while read` with `<<<`, never `<(...)`.
_SKILL_LIST=""
_skill_list() {
  local skill="$1" suffix="$2" filter="$3"; shift 3
  local key="$skill::$suffix" jq_args=(--arg s "$skill")
  while [[ $# -gt 0 ]]; do jq_args+=(--arg "$1" "$2"); key="$key::$2"; shift 2; done
  if [[ -z "${_SKILL_META_LIST[$key]+x}" ]]; then
    _SKILL_META_LIST[$key]=$(jq -r "${jq_args[@]}" "$filter" "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  fi
  _SKILL_LIST="${_SKILL_META_LIST[$key]}"
}

# Returns 0=new, 1=identical, 2=changed; prints a one-line notice for a changed file.
check_dest_status() {
  local incoming="$1" dest="$2"
  if [[ ! -f "$dest" ]]; then
    return 0  # new file
  fi
  if cmp -s "$incoming" "$dest"; then
    return 1  # identical
  fi
  local rel_dest="${dest#$REPO_ROOT/}"
  echo "  $rel_dest (updated)"
  return 2  # changed
}

# Paths the current copy wrote into the tree being installed; prune_unwritten removes the rest.
declare -A _WRITTEN

# Make an installed tree an exact copy of what this run wrote into it. Prune after copy, never
# wipe-then-copy: a sprint running during an install still finds every file the new version ships.
prune_unwritten() {
  local root="$1" f
  while IFS= read -r -d '' f; do
    [[ -n "${_WRITTEN[$f]+x}" ]] && continue
    rm -f "$f"
    echo "  ${f#"$REPO_ROOT/"} (removed)"
  done < <(find "$root" -mindepth 1 ! -type d -print0)
  find "$root" -mindepth 1 -depth -type d -empty -delete
}

# Assets are platform-neutral runtime files, installed once to a shared path and always
# overwritten; a file the source no longer has is removed so a stale module never shadows its replacement.
install_assets_tree() {
  local src="$1" dest_rel="$2" label="$3"
  [[ -d "$src" ]] || { echo "Error: $label assets source not found: $src" >&2; exit 1; }

  local asset_file rel_path dest_file status
  _WRITTEN=()
  while IFS= read -r -d '' asset_file; do
    rel_path="${asset_file#$src/}"
    dest_file="$REPO_ROOT/$dest_rel/$rel_path"
    mkdir -p "$(dirname "$dest_file")"
    status=0
    check_dest_status "$asset_file" "$dest_file" || status=$?
    cp "$asset_file" "$dest_file"
    # *.sh, and every file under a shim/ directory: a PATH shim has the name of the command it
    # stands in for (`docker`), so there is no extension to go by.
    [[ "$rel_path" == *.sh || "$rel_path" == shim/* || "$rel_path" == */shim/* ]] && chmod +x "$dest_file"
    _WRITTEN["$dest_file"]=1
    if [[ $status -eq 0 ]]; then echo "  $dest_rel/$rel_path"; fi
  done < <(find "$src" -type f -print0)
  prune_unwritten "$REPO_ROOT/$dest_rel"
}

# Installed once per run, not per platform: four platforms launching one program must launch the
# same copy, or a fixed bug is only fixed on one.
install_skill_assets() {
  local skill_name="$1"
  local src_rel dest_rel
  _skill_scalar "$skill_name" assets_source '.skills[$s].assets.source // empty'
  src_rel="$_SKILL_SCALAR"
  _skill_scalar "$skill_name" assets_dest '.skills[$s].assets.dest // empty'
  dest_rel="$_SKILL_SCALAR"
  [[ -n "$src_rel" && -n "$dest_rel" ]] || return 0
  if [[ "$INSTALLED" == *"|assets:skill:$skill_name|"* ]]; then return 0; fi
  INSTALLED="${INSTALLED}|assets:skill:$skill_name|"
  assert_safe_path "$src_rel" "skill assets source"
  assert_safe_path "$dest_rel" "skill assets dest"
  install_assets_tree "$SCRIPT_DIR/$src_rel" "$dest_rel" "skill"
  # `more-assets`: further trees the same way (crew-afk's role protocols render with the shared
  # fragments, which orchestrator/lib/adapters/render.mjs reads from .coding-crew/skills/_shared/).
  _skill_list "$skill_name" more_assets '.skills[$s]["more-assets"] // [] | .[] | "\(.source)\t\(.dest)"'
  local more="$_SKILL_LIST" line
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -n "$line" ]] || continue
    src_rel="${line%%$'\t'*}"; dest_rel="${line#*$'\t'}"
    assert_safe_path "$src_rel" "skill assets source"
    assert_safe_path "$dest_rel" "skill assets dest"
    install_assets_tree "$SCRIPT_DIR/$src_rel" "$dest_rel" "skill"
  done <<< "$more"
}


install_single_skill() {
  local skill_name="$1"
  assert_identifier "$skill_name" "skill"

  if [[ "$PLATFORM" == "all" ]]; then
    local saved_platform="$PLATFORM"
    local fan_platform
    for fan_platform in "${PLATFORMS[@]}"; do
      PLATFORM="$fan_platform"; install_single_skill "$skill_name"
    done
    PLATFORM="$saved_platform"
    return
  fi

  if [[ "$INSTALLED" == *"|skill:$skill_name:$PLATFORM|"* ]]; then
    return
  fi
  INSTALLED="${INSTALLED}|skill:$skill_name:$PLATFORM|"

  _skill_scalar "$skill_name" exists '.skills[$s] | if . == null then empty else "yes" end'
  if [[ -z "$_SKILL_SCALAR" ]]; then
    echo "Error: skill '$skill_name' not found in registry.json"
    echo "Available skills: $(jq -r '.skills | keys | join(", ")' "$SCRIPT_DIR/registry.json")"
    exit 1
  fi
  resolve_skill_dest "$PLATFORM" "$skill_name"
  local skill_dest="$_SKILL_DEST"
  assert_safe_path "$skill_dest" "skill install"
  local skill_root="$_DEST_ROOT/$_DEST_REL"
  platform_skills_dir "$PLATFORM" user
  prune_legacy_copilot_path "$PLATFORM" "$_PLATFORM_SKILLS/$skill_name"

  local source_dir
  _skill_scalar "$skill_name" source_dir '.skills[$s]["source-dir"] // $s'
  source_dir="$_SKILL_SCALAR"

  [[ -d "$SCRIPT_DIR/skills/$source_dir" ]] || { echo "Error: skill source not found: skills/$source_dir" >&2; exit 1; }
  # Remove a stale symlink before mkdir -p; mkdir would succeed but cp into it would fail
  [[ -L "$skill_root" ]] && rm -f "$skill_root"
  mkdir -p "$skill_root"
  _WRITTEN=()

  while IFS= read -r -d '' src_file; do
    local rel_path="${src_file#$SCRIPT_DIR/skills/$source_dir/}"
    local dest_file="$skill_root/$rel_path"
    local rel_dest="${dest_file#$REPO_ROOT/}"
    mkdir -p "$(dirname "$dest_file")"

    local staged="$src_file" render_tmp=""
    if [[ "$rel_path" == "SKILL.md" ]]; then
      render_tmp=$(mktemp)
      bash "$SCRIPT_DIR/scripts/render-skill.sh" "$skill_name" "$PLATFORM" "$render_tmp" || {
        rm -f "$render_tmp"; exit 1; }
      staged="$render_tmp"
    fi

    local status=0
    check_dest_status "$staged" "$dest_file" || status=$?
    cp "$staged" "$dest_file"
    _WRITTEN["$dest_file"]=1
    [[ -n "$render_tmp" ]] && rm -f "$render_tmp"

    if [[ $status -eq 0 ]]; then
      echo "  $rel_dest"
    fi
  done < <(find "$SCRIPT_DIR/skills/$source_dir" -type f -not -name "test-*.sh" -print0)

  local scripts
  _skill_list "$skill_name" scripts '.skills[$s].scripts // [] | .[]'
  scripts="$_SKILL_LIST"
  local scripts_arr=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && scripts_arr+=("$_line"); done <<< "$scripts"
  if [[ "${#scripts_arr[@]}" -gt 0 ]]; then
    mkdir -p "$skill_root/scripts"
    for script in "${scripts_arr[@]}"; do
      local script_src="$SCRIPT_DIR/scripts/skill-utils/git-workflow/$script"
      if [[ ! -f "$script_src" ]]; then
        echo "Error: script source not found: scripts/skill-utils/git-workflow/$script" >&2
        exit 1
      fi
      cp "$script_src" "$skill_root/scripts/$script"
      chmod +x "$skill_root/scripts/$script"
      _WRITTEN["$skill_root/scripts/$script"]=1
    done
    echo "  $skill_dest/scripts/ (${#scripts_arr[@]} scripts from skill-utils/git-workflow)"
  fi
  # Whatever this run did not write is a file an earlier version shipped: an agent listing the directory would read it.
  prune_unwritten "$skill_root"

  local skill_version
  _skill_scalar "$skill_name" version '.skills[$s].version // "unknown"'
  skill_version="$_SKILL_SCALAR"
  MANIFEST_SKILL_ENTRIES+=("$skill_name $skill_version")

  # Runtime files the skill launches rather than reads (the crew-afk orchestrator).
  install_skill_assets "$skill_name"

  local deps
  _skill_list "$skill_name" deps '.skills[$s].deps // [] | .[]'
  deps="$_SKILL_LIST"
  local deps_arr=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && deps_arr+=("$_line"); done <<< "$deps"
  for dep in "${deps_arr[@]+"${deps_arr[@]}"}"; do
    install_single_skill "$dep"
  done

}

# Move a legacy issue-tracker.md front-matter choice into config.json's `tracker` section (an
# existing section wins), then delete the legacy files; at $HOME only the files go. A front matter
# naming `repo:` is left alone: migrating without that override would silently retarget the tracker.
migrate_legacy_tracker_doc() {
  local legacy_rel=".coding-crew/docs/issue-tracker.md"
  local templates_rel=".coding-crew/docs/templates/trackers"
  local legacy="$REPO_ROOT/$legacy_rel"

  if [[ -f "$legacy" ]]; then
    # The front matter: the lines between a leading `---` and the next one, as tracker-config.mjs reads it.
    local front_matter kind
    front_matter=$(awk 'NR == 1 { if ($0 !~ /^---[ \t]*\r?$/) exit; next } /^---[ \t]*\r?$/ { exit } { print }' "$legacy")
    if grep -qE '^repo[[:space:]]*:' <<< "$front_matter"; then
      echo "Warning: $legacy: \`repo\` is no longer supported — gh targets the git remote. Remove the repo: line and re-run install; this file was not migrated." >&2
      return 0
    fi
    kind=$(sed -nE "s/^tracker[[:space:]]*:[[:space:]]*[\"']?([A-Za-z]+).*/\1/p" <<< "$front_matter" | head -1)
    [[ "$kind" == "github" ]] || kind="local"

    if [[ "$REPO_ROOT" != "$HOME" ]]; then
      local config="$REPO_ROOT/.coding-crew/config.json" tmp
      if [[ ! -f "$config" ]]; then
        jq -n --arg k "$kind" '{tracker: {kind: $k}}' > "$config"
        echo "  .coding-crew/config.json (tracker: $kind, from $legacy_rel)"
      elif ! jq -e 'type == "object"' "$config" > /dev/null 2>&1; then
        echo "Warning: $config is not a JSON object; $legacy_rel was not migrated. Fix it and re-run install." >&2
        return 0
      elif ! jq -e 'has("tracker")' "$config" > /dev/null; then
        tmp=$(mktemp "$config.XXXXXX")
        jq --arg k "$kind" '.tracker = {kind: $k}' "$config" > "$tmp" && mv "$tmp" "$config"
        echo "  .coding-crew/config.json (tracker: $kind, from $legacy_rel)"
      fi
    fi
    rm -f "$legacy"
    echo "  $legacy_rel (removed)"
  fi
  if [[ -d "$REPO_ROOT/$templates_rel" ]]; then
    rm -rf "${REPO_ROOT:?}/$templates_rel"
    echo "  $templates_rel/ (removed)"
  fi
  rmdir "$REPO_ROOT/.coding-crew/docs/templates" "$REPO_ROOT/.coding-crew/docs" 2>/dev/null || true
}

install_docs() {
  local docs_header_printed=0
  if [[ -f "$REPO_ROOT/.coding-crew/docs/issue-tracker.md" || -d "$REPO_ROOT/.coding-crew/docs/templates/trackers" ]]; then
    echo "Docs:"; docs_header_printed=1
    migrate_legacy_tracker_doc
  fi

  # The tracker CLI and its backends: installed whichever skill is, and kept an exact copy.
  local trees
  trees=$(jq -r '.docs.trees // {} | keys[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  local trees_arr=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && trees_arr+=("$_line"); done <<< "$trees"

  for tree in "${trees_arr[@]+"${trees_arr[@]}"}"; do
    local tree_src_rel tree_dest_rel
    tree_src_rel=$(jq -r --arg t "$tree" '.docs.trees[$t].source // empty' "$SCRIPT_DIR/registry.json")
    tree_dest_rel=$(jq -r --arg t "$tree" '.docs.trees[$t].dest // empty' "$SCRIPT_DIR/registry.json")
    [[ -z "$tree_src_rel" || -z "$tree_dest_rel" ]] && continue
    assert_safe_path "$tree_src_rel" "doc tree source"
    assert_safe_path "$tree_dest_rel" "doc tree dest"

    [[ "$docs_header_printed" -eq 0 ]] && { echo "Docs:"; docs_header_printed=1; }
    install_assets_tree "$SCRIPT_DIR/$tree_src_rel" "$tree_dest_rel" "doc tree"
  done
}

# A user-level copy of the same skill can take precedence over the project's, and we cannot change
# the host's resolution order, so say so plainly.
warn_shadowing_user_installs() {
  [[ "$REPO_ROOT" == "$HOME" ]] && return 0

  local found=()
  local d
  while IFS= read -r d; do
    [[ -d "$d" ]] || continue
    local name
    # The retired agent names too: nothing cleans a stale user-level copy on a project install.
    for name in crew-afk solve-issue $(jq -r '."retired-agents".names // [] | .[]' "$SCRIPT_DIR/registry.json"); do
      if [[ -e "$d/$name" || -e "$d/$name.md" || -e "$d/$name.toml" || -e "$d/$name.agent.md" ]]; then
        found+=("$d/$name")
      fi
    done
  done < <(platform_user_dirs)

  [[ ${#found[@]} -eq 0 ]] && return 0

  echo "---"
  echo "WARNING: user-level copies exist and may shadow this project install:"
  local f
  for f in "${found[@]}"; do echo "  $f"; done
  echo "  Some hosts (pi included) resolve the user-level definition first, so edits here"
  echo "  can appear to have no effect. Remove or update those copies, or re-run with"
  echo "  TARGET_REPO=\$HOME to install at user level instead."
}

write_manifest() {
  local manifest="$REPO_ROOT/.coding-crew/manifest.json"
  mkdir -p "$(dirname "$manifest")"

  local source_sha source_remote
  source_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
  source_remote=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "local")

  local skills_json="{}"
  for entry in "${MANIFEST_SKILL_ENTRIES[@]+"${MANIFEST_SKILL_ENTRIES[@]}"}"; do
    local name version
    read -r name version <<< "$entry"
    skills_json=$(jq -n --argjson base "$skills_json" --arg n "$name" --arg v "$version" \
      '$base | .[$n] = {version: $v}')
  done

  # Merge with the existing manifest. Its legacy `agents` key is dropped: prune_retired_agents removed their files.
  local existing_skills="{}"
  if [[ -f "$manifest" ]]; then
    existing_skills=$(jq '.skills // {}' "$manifest")
  fi

  jq -n \
    --arg sha "$source_sha" \
    --arg remote "$source_remote" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg platform "$PLATFORM" \
    --argjson existing_skills "$existing_skills" \
    --argjson new_skills "$skills_json" \
    '{
      source: $remote,
      source_sha: $sha,
      installed_at: $ts,
      platform: $platform,
      skills: ($existing_skills * $new_skills)
    }' > "$manifest"

  echo "  .coding-crew/manifest.json"
}

# --skills a,b,c declares the full skill set, but write_manifest's merge never drops a key, so a
# skill left out is removed here through uninstall.sh --skill (the single writer of skill files)
# and its key deleted so the merge below does not resurrect it.
prune_skills_not_in() {
  local requested="$1"
  local manifest="$REPO_ROOT/.coding-crew/manifest.json"
  [[ -f "$manifest" ]] || return 0
  local existing name
  existing=$(jq -r '.skills | keys[]?' "$manifest")
  [[ -n "$existing" ]] || return 0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    grep -qxF "$name" <<< "$requested" && continue
    echo "  pruning $name (not in --skills list)"
    TARGET_REPO="$REPO_ROOT" "$SCRIPT_DIR/uninstall.sh" --skill "$name" | sed 's/^/  /'
    jq --arg n "$name" 'del(.skills[$n])' "$manifest" > "$manifest.tmp" && mv "$manifest.tmp" "$manifest"
  done <<< "$existing"
}

run_update() {
  local manifest="$REPO_ROOT/.coding-crew/manifest.json"
  local legacy_manifest="$REPO_ROOT/.coding-crew.manifest.json"
  if [[ ! -f "$manifest" && -f "$legacy_manifest" ]]; then
    manifest="$legacy_manifest"
  fi
  if [[ ! -f "$manifest" ]]; then
    echo "Error: no manifest found at $REPO_ROOT/.coding-crew/manifest.json (or legacy .coding-crew.manifest.json) — run ./install.sh first" >&2
    exit 1
  fi

  local saved_platform
  saved_platform=$(jq -r '.platform' "$manifest")
  PLATFORM="$saved_platform"

  echo "Platform: $saved_platform (from manifest)"
  echo "Checking for updates..."
  echo "---"

  local updated=0

  # An install from before crew-afk owned its roles lists them as agents; crew-afk now prunes them.
  if [[ -n "$(jq -r '.agents // {} | keys[]' "$manifest")" ]]; then
    echo "  agents (crew-coder, crew-reviewer, crew-triage): now part of crew-afk — installing crew-afk"
    install_single_skill crew-afk
    updated=$((updated + 1))
  fi

  while IFS= read -r name; do
    local installed_version current_version
    installed_version=$(jq -r --arg n "$name" '.skills[$n].version // "unknown"' "$manifest")
    current_version=$(jq -r --arg n "$name" '.skills[$n].version // empty' "$SCRIPT_DIR/registry.json")
    if [[ -z "$current_version" ]]; then
      echo "  $name: removed from registry — skipping"
      continue
    fi
    if [[ "$installed_version" != "$current_version" ]]; then
      echo "  Updating $name: $installed_version → $current_version"
      install_single_skill "$name"
      updated=$((updated + 1))
    else
      echo "  $name $installed_version: up to date"
    fi
  done < <(jq -r '.skills | keys[]' "$manifest")

  echo "---"
  echo "$updated item(s) updated"
}

echo "Target: $REPO_ROOT"

if [[ "$UPDATE_MODE" == "true" ]]; then
  run_update
  prune_retired_agents
  prune_retired_scripts
  # The tracker CLI and docs carry no version of their own, so an update that skipped this would
  # keep a stale gate forever.
  install_docs
  if [[ "${#MANIFEST_SKILL_ENTRIES[@]}" -gt 0 ]]; then
    write_manifest
  fi
  echo "Done."
  exit 0
fi

echo "Platform: $PLATFORM"

if [[ "$AGENT" == "--skill" ]]; then
  if [[ -n "$SKILLS_LIST" ]]; then
    echo "Skills: $SKILLS_LIST"
    echo "---"
    IFS=',' read -ra _skills_arr <<< "$SKILLS_LIST"
    _requested_skills=""
    for _s in "${_skills_arr[@]}"; do
      _s="${_s// /}"  # trim spaces
      if [[ -n "$_s" ]]; then
        install_single_skill "$_s"
        _requested_skills+="$_s"$'\n'
      fi
    done
    prune_skills_not_in "$_requested_skills"
    unset _skills_arr _s _requested_skills
  else
    SKILL_NAME="${3:-}"
    if [[ -z "$SKILL_NAME" ]]; then
      echo "Error: --skill requires a skill name"
      usage
    fi
    echo "Skill: $SKILL_NAME"
    echo "---"
    install_single_skill "$SKILL_NAME"
  fi
elif [[ "$AGENT" == "all" ]]; then
  echo "---"
  skill_names=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && skill_names+=("$_line"); done < <(jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json")
  for skill_name in "${skill_names[@]}"; do
    install_single_skill "$skill_name"
  done
elif jq -e --arg n "$AGENT" '."retired-agents".names | index($n)' "$SCRIPT_DIR/registry.json" >/dev/null; then
  echo "Note: $AGENT is now a role inside crew-afk — installing crew-afk"
  echo "---"
  install_single_skill crew-afk
else
  echo "Error: unknown argument '$AGENT' (expected all, --skill <name> or --skills <a,b>)" >&2
  usage
fi

install_docs
prune_retired_agents
prune_retired_scripts
echo "---"
write_manifest

warn_shadowing_user_installs

echo "Done."
