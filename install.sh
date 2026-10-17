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

usage() {
  echo "Usage: ./install.sh [platform] [--skill <name> | --skills <a,b,c>] [--project [<path>]]"
  echo "       ./install.sh --update [--project [<path>]]"
  echo ""
  local known="a platform in platforms.json"
  [[ ${#PLATFORMS[@]} -gt 0 ]] && known=$(platforms_joined ", ")
  echo "  platform:   all (default), $known"
  echo "  --skill:    install a single skill (e.g. to-issues) and the skills it uses"
  echo "  --skills:   install multiple skills (comma-separated, e.g. tdd,to-issues,to-prd);"
  echo "              treated as the full desired set — any skill from a prior --skills"
  echo "              install that's missing from this list is uninstalled"
  echo "  --project:  install into a repo (<path>, else the current repo) instead of \$HOME;"
  echo "              TARGET_REPO=<path> does the same"
  echo "  --update:   uninstall every skill the manifest lists, then install"
  echo "              those skills again from this checkout, for the same platform"
  echo ""
  echo "Examples:"
  echo "  ./install.sh                                      # every skill, user level (\$HOME)"
  echo "  ./install.sh claude --skill solve-feature         # solve-feature and the skills it uses"
  echo "  ./install.sh claude --skills tdd,to-issues        # several skills at once"
  echo "  ./install.sh claude --project                     # every skill into the current repo"
  echo "  ./install.sh claude --project /path/to/repo       # every skill into that repo"
  echo "  ./install.sh --update                             # reinstall what \$HOME has"
  echo ""
  echo "Available skills:"
  echo "  $(jq -r '.skills | keys | join(", ")' "$SCRIPT_DIR/registry.json" 2>/dev/null || echo "(needs jq to list)")"
  echo ""
  echo "A user-level install honors each platform's own config-dir override:"
  local i overrides=""
  for i in "${!PLATFORMS[@]}"; do overrides="${overrides:+$overrides, }${_PF_ENV[$i]} (${PLATFORMS[$i]})"; done
  echo "  ${overrides:-the configDirEnv of each entry in platforms.json}."
  exit 1
}

usage_error() { echo "Error: $1" >&2; usage; }

# Help needs no dependency: usage() says where the platform list lives when jq is missing.
PLATFORMS=(); _PF_ENV=()
for _arg in "$@"; do
  if [[ "$_arg" == "-h" || "$_arg" == "--help" ]]; then
    command -v jq >/dev/null 2>&1 && source "$SCRIPT_DIR/scripts/lib/platforms.sh"
    usage
  fi
done

UPDATE_MODE=false
PLATFORM=""
SKILL_MODE="all"   # all | skill | skills
SKILL_NAME=""
SKILLS_LIST=""
PROJECT=false
PROJECT_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --update) UPDATE_MODE=true; shift ;;
    --skill)
      [[ -n "${2:-}" && "${2:-}" != -* ]] || usage_error "--skill requires a skill name"
      SKILL_MODE="skill"; SKILL_NAME="$2"; shift 2 ;;
    --skills)
      [[ -n "${2:-}" && "${2:-}" != -* ]] || usage_error "--skills requires a comma-separated list (e.g. --skills tdd,to-issues)"
      SKILL_MODE="skills"; SKILLS_LIST="$2"; shift 2 ;;
    --project)
      PROJECT=true; shift
      # The next word is the repo when it reads as a path, or when the platform is already named.
      if [[ $# -gt 0 && "$1" != -* ]] && [[ -n "$PLATFORM" || "$1" == */* || "$1" == "." || "$1" == ".." ]]; then
        PROJECT_PATH="$1"; shift
      fi ;;
    -*) usage_error "unknown argument '$1'" ;;
    *)
      [[ -z "$PLATFORM" ]] || usage_error "unexpected argument '$1' (the platform is already '$PLATFORM')"
      PLATFORM="$1"; shift ;;
  esac
done
if [[ "$UPDATE_MODE" == "true" && ( -n "$PLATFORM" || "$SKILL_MODE" != "all" ) ]]; then
  usage_error "--update takes no platform or skill: it reinstalls what the manifest lists"
fi
PLATFORM="${PLATFORM:-all}"

# User level ($HOME) unless --project or TARGET_REPO names a repo.
if [[ "$PROJECT" == "true" ]]; then
  if [[ -n "$PROJECT_PATH" ]]; then
    [[ -d "$PROJECT_PATH" ]] || { echo "Error: --project path does not exist: $PROJECT_PATH" >&2; exit 1; }
    REPO_ROOT="$(cd "$PROJECT_PATH" && pwd)"
  else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
elif [[ -n "${TARGET_REPO:-}" ]]; then
  [[ "$TARGET_REPO" =~ ^/ ]] || { echo "Error: TARGET_REPO must be an absolute path" >&2; exit 1; }
  [[ -d "$TARGET_REPO" ]] || { echo "Error: TARGET_REPO does not exist: $TARGET_REPO" >&2; exit 1; }
  REPO_ROOT="$TARGET_REPO"
else
  REPO_ROOT="$HOME"
fi

INSTALLED=""
MANIFEST_SKILLS=()
MANIFEST_PLATFORMS=()

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

if [[ "$PLATFORM" != "all" ]] && ! platform_known "$PLATFORM"; then
  usage_error "invalid platform '$PLATFORM' — must be: all, $(platforms_joined ", ") (from platforms.json)"
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
# wipe-then-copy: a run during an install still finds every file the new version ships.
prune_unwritten() {
  local root="$1" f
  while IFS= read -r -d '' f; do
    [[ -n "${_WRITTEN[$f]+x}" ]] && continue
    rm -f "$f"
    echo "  ${f#"$REPO_ROOT/"} (removed)"
  done < <(find "$root" -mindepth 1 ! -type d -print0)
  find "$root" -mindepth 1 -depth -type d -empty -delete
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
  # An older install linked scripts/<lib> into .coding-crew/lib: cp would write through the link.
  find "$skill_root" -mindepth 1 -type l -delete
  _WRITTEN=()

  # The committed tree is the installed tree: every file is copied as is, its libraries included.
  while IFS= read -r -d '' src_file; do
    local rel_path="${src_file#$SCRIPT_DIR/skills/$source_dir/}"
    local dest_file="$skill_root/$rel_path"
    local rel_dest="${dest_file#$REPO_ROOT/}"
    mkdir -p "$(dirname "$dest_file")"

    local status=0
    check_dest_status "$src_file" "$dest_file" || status=$?
    cp "$src_file" "$dest_file"
    # cp keeps an existing file's mode: the copy's exec bit must follow the source's.
    if [[ -x "$src_file" && ! -x "$dest_file" ]]; then chmod +x "$dest_file"
    elif [[ ! -x "$src_file" && -x "$dest_file" ]]; then chmod -x "$dest_file"; fi
    _WRITTEN["$dest_file"]=1

    if [[ $status -eq 0 ]]; then
      echo "  $rel_dest"
    fi
  done < <(find -L "$SCRIPT_DIR/skills/$source_dir" -type f -print0)

  # Whatever this run did not write is a file an earlier version shipped: an agent listing the directory would read it.
  prune_unwritten "$skill_root"
  MANIFEST_SKILLS+=("$skill_name")

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

# .coding-crew/lib held the libraries every skill linked to; only install.sh ever wrote it, and each
# skill now carries its own copy, so it is removed wherever it is found.
remove_legacy_lib() {
  [[ -e "$REPO_ROOT/.coding-crew/lib" || -L "$REPO_ROOT/.coding-crew/lib" ]] || return 0
  rm -rf "${REPO_ROOT:?}/.coding-crew/lib"
  echo "  .coding-crew/lib/ (removed: each skill carries its own scripts/<lib>)"
}

migrate_legacy_docs() {
  if [[ -f "$REPO_ROOT/.coding-crew/docs/issue-tracker.md" || -d "$REPO_ROOT/.coding-crew/docs/templates/trackers" ]]; then
    echo "Docs:"
    migrate_legacy_tracker_doc
  fi
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
    for name in solve-feature solve-issue; do
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
  echo "  can appear to have no effect. Remove or update those copies, or re-run without"
  echo "  --project to install at user level instead."
}

MANIFEST="$REPO_ROOT/.coding-crew/manifest.json"

# manifest_list <file> <key> — the names under .skills, one per line. An older install keyed skills by
# name with a version each; both forms read the same.
manifest_list() {
  jq -r --arg k "$2" '.[$k] // [] | if type == "object" then keys[] else .[] end' "$1"
}

# manifest_platforms <file> — the platforms installed into this root, one per line. An install made
# before the list recorded only the last platform, under .platform.
manifest_platforms() {
  jq -r '.platforms // [.platform // empty] | .[]' "$1"
}

# The manifest records the platforms and the skills installed, merged with what an earlier install
# recorded: every platform installs into one root, so --update must reinstall each.
# No versions: --update reinstalls everything it lists.
write_manifest() {
  mkdir -p "$(dirname "$MANIFEST")"

  local source_sha source_remote skills platforms
  source_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
  source_remote=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "local")

  skills=$( { printf '%s\n' "${MANIFEST_SKILLS[@]+"${MANIFEST_SKILLS[@]}"}"
              [[ ! -f "$MANIFEST" ]] || manifest_list "$MANIFEST" skills; } | tr -d '\r' | grep -v '^$' | LC_ALL=C sort -u || true)
  # --update sets MANIFEST_PLATFORMS: its uninstall may have removed the manifest it read them from.
  platforms=$( { printf '%s\n' "${MANIFEST_PLATFORMS[@]:-$PLATFORM}"
                 [[ ! -f "$MANIFEST" ]] || manifest_platforms "$MANIFEST"; } | tr -d '\r' | grep -v '^$' | LC_ALL=C sort -u || true)
  # "all" covers every platform.
  ! grep -qxF all <<< "$platforms" || platforms=all

  jq -n \
    --arg sha "$source_sha" \
    --arg remote "$source_remote" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg platforms "$platforms" \
    --arg skills "$skills" \
    '{
      source: $remote,
      source_sha: $sha,
      installed_at: $ts,
      platforms: ($platforms | split("\n") | map(select(. != ""))),
      skills: ($skills | split("\n") | map(select(. != "")))
    }' > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"

  echo "  .coding-crew/manifest.json"
}

# uninstall.sh is the single remover of skills: it drops each from the manifest.
uninstall_skills() {
  local list="$1"
  [[ -n "$list" ]] || return 0
  TARGET_REPO="$REPO_ROOT" "$SCRIPT_DIR/uninstall.sh" --skills "$list" | sed 's/^/  /'
}

# --skills a,b,c declares the full skill set: a skill a prior install recorded and this list leaves
# out is uninstalled first.
prune_skills_not_in() {
  local requested="$1" name prune=""
  [[ -f "$MANIFEST" ]] || return 0
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [[ -n "$name" ]] || continue
    grep -qxF "$name" <<< "$requested" && continue
    echo "  pruning $name (not in --skills list)"
    prune="${prune:+$prune,}$name"
  done < <(manifest_list "$MANIFEST" skills)
  uninstall_skills "$prune"
}

# --update: uninstall every skill the manifest lists, then install the listed skills the
# registry still has, for each of the manifest's platforms. A skill the registry dropped stays uninstalled.
run_update() {
  if [[ ! -f "$MANIFEST" ]]; then
    echo "Error: no manifest found at $MANIFEST — run ./install.sh first" >&2
    exit 1
  fi
  local platforms=() platform
  while IFS= read -r platform; do
    platform="${platform%$'\r'}"
    [[ -n "$platform" ]] || continue
    if [[ "$platform" != "all" ]] && ! platform_known "$platform"; then
      echo "Error: the manifest's platform '$platform' is not in platforms.json" >&2
      exit 1
    fi
    platforms+=("$platform")
  done < <(manifest_platforms "$MANIFEST")
  [[ ${#platforms[@]} -gt 0 ]] || platforms=(all)
  MANIFEST_PLATFORMS=("${platforms[@]}")

  local names=() name
  while IFS= read -r name; do
    name="${name%$'\r'}"
    [[ -n "$name" ]] && names+=("$name")
  done < <(manifest_list "$MANIFEST" skills)

  echo "Platform: ${platforms[*]} (from manifest)"
  echo "---"
  uninstall_skills "$(IFS=,; echo "${names[*]+"${names[*]}"}")"
  echo "---"
  for name in "${names[@]+"${names[@]}"}"; do
    assert_identifier "$name" "skill"
    _skill_scalar "$name" exists '.skills[$s] | if . == null then empty else "yes" end'
    if [[ -z "$_SKILL_SCALAR" ]]; then
      echo "  $name: removed from the registry — uninstalled"
      continue
    fi
    for PLATFORM in "${platforms[@]}"; do install_single_skill "$name"; done
  done
}

echo "Target: $REPO_ROOT"

if [[ "$UPDATE_MODE" == "true" ]]; then
  run_update
  remove_legacy_lib
  migrate_legacy_docs
  if [[ "${#MANIFEST_SKILLS[@]}" -gt 0 ]]; then
    write_manifest
  fi
  echo "Done."
  exit 0
fi

echo "Platform: $PLATFORM"

case "$SKILL_MODE" in
  skills)
    echo "Skills: $SKILLS_LIST"
    echo "---"
    IFS=',' read -ra _skills_arr <<< "$SKILLS_LIST"
    _requested_skills=""
    for _s in "${_skills_arr[@]}"; do
      _s="${_s// /}"  # trim spaces
      [[ -n "$_s" ]] && _requested_skills+="$_s"$'\n'
    done
    prune_skills_not_in "$_requested_skills"
    while IFS= read -r _s; do
      [[ -n "$_s" ]] && install_single_skill "$_s"
    done <<< "$_requested_skills"
    unset _skills_arr _s _requested_skills
    ;;
  skill)
    echo "Skill: $SKILL_NAME"
    echo "---"
    install_single_skill "$SKILL_NAME"
    ;;
  all)
    echo "---"
    skill_names=()
    while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && skill_names+=("$_line"); done < <(jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json")
    for skill_name in "${skill_names[@]}"; do
      install_single_skill "$skill_name"
    done
    ;;
esac

remove_legacy_lib
migrate_legacy_docs
echo "---"
write_manifest

warn_shadowing_user_installs

echo "Done."
