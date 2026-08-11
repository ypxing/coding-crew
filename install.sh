#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

REPO_ROOT="${TARGET_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Pull --version/--registry out of the args wherever they appear, before positional
# parsing below assigns platform/agent from $1/$2/$3. Passing --version pins the
# install to that tag AND writes crew.lock recording it — see write_lockfile().
# --version latest resolves to the newest published release tag before pinning, so
# crew.lock always records a concrete version, never the moving "latest" alias.
PIN_VERSION=""
PIN_REGISTRY=""
_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version=*) PIN_VERSION="${1#--version=}"; shift ;;
    --version) PIN_VERSION="${2:-}"; shift 2 ;;
    --registry=*) PIN_REGISTRY="${1#--registry=}"; shift ;;
    --registry) PIN_REGISTRY="${2:-}"; shift 2 ;;
    *) _ARGS+=("$1"); shift ;;
  esac
done
set -- "${_ARGS[@]+"${_ARGS[@]}"}"

UPDATE_MODE=false
LOCKFILE_MODE=false
LOCKFILE_PATH=""
SKILLS_LIST=""  # comma-separated list from --skills a,b,c
if [[ "${1:-}" == "--update" ]]; then
  UPDATE_MODE=true
  PLATFORM="all"
  AGENT="all"
elif [[ "${1:-}" == "--from-lockfile" ]]; then
  LOCKFILE_MODE=true
  LOCKFILE_PATH="${2:-$REPO_ROOT/crew.lock}"
  if [[ ! -f "$LOCKFILE_PATH" ]]; then
    echo "Error: lockfile not found: $LOCKFILE_PATH" >&2
    exit 1
  fi
  PLATFORM="all"
  AGENT="all"
else
  PLATFORM="${1:-all}"    # all | claude | copilot | pi | codex
  AGENT="${2:-all}"       # all | crew-coder | crew-code-reviewer | --skill <name> | --skills a,b
fi

# --skills a,b,c  (multi-skill shorthand, replaces --skill for multiple names)
if [[ "$AGENT" == "--skills" ]]; then
  SKILLS_LIST="${3:-}"
  if [[ -z "$SKILLS_LIST" ]]; then
    echo "Error: --skills requires a comma-separated list (e.g. --skills tdd,caveman)" >&2
    usage
  fi
  AGENT="--skill"  # normalise so later dispatch hits the skill path
fi

INSTALLED=""
MANIFEST_AGENT_ENTRIES=()  # each entry: "name version platform"
MANIFEST_SKILL_ENTRIES=()  # each entry: "name version"

usage() {
  echo "Usage: ./install.sh [platform] [agent]"
  echo "       ./install.sh [platform] --skill <skill-name>"
  echo "       ./install.sh [platform] --skills <a,b,c>"
  echo "       ./install.sh --update"
  echo "       ./install.sh --from-lockfile [path]"
  echo ""
  echo "  platform:        all (default), claude, copilot, pi, codex"
  echo "  agent:           all (default), crew-code-reviewer, crew-coder"
  echo "  --skill:         install a single skill (e.g. to-issues)"
  echo "  --skills:        install multiple skills (comma-separated, e.g. tdd,caveman,to-issues)"
  echo "  --update:        re-install only agents/skills whose version changed since last install"
  echo "  --version:       pin to a release tag (e.g. v1.2.0) or 'latest' to resolve the newest release"
  echo "  --from-lockfile: install from a lockfile (defaults to ./crew.lock; fetches pinned registry version and installs listed items)"
  echo ""
  echo "Examples:"
  echo "  ./install.sh                                      # install everything into project"
  echo "  ./install.sh claude --skill tdd                   # one skill into project"
  echo "  ./install.sh claude --skills tdd,caveman          # multiple skills at once"
  echo "  ./install.sh claude --skill crew-afk              # crew-afk + crew-coder + crew-code-reviewer"
  echo "  ./install.sh --update                             # update all installed agents/skills"
  echo "  ./install.sh --from-lockfile                      # install from ./crew.lock"
  echo "  ./install.sh --from-lockfile path/to/crew.lock    # install from a specific lockfile"
  echo "  ./install.sh --version latest                     # pin to the newest published release"
  echo ""
  echo "Available skills:"
  echo "  $(jq -r '.skills | keys | join(", ")' "$SCRIPT_DIR/registry.json")"
  echo ""
  echo "Set TARGET_REPO to install into a different repo root."
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

# ── Dependency checks ──────────────────────────────────────────────────────────
_required_cmds=("jq" "git")
for cmd in "${_required_cmds[@]}"; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: required command '$cmd' not found" >&2; exit 1; }
done

# ── Input validation ───────────────────────────────────────────────────────────
if [[ "$UPDATE_MODE" == "false" ]]; then
  if [[ "${1:-}" == "--skill" ]]; then
    echo "Error: platform argument required before flag (e.g. ./install.sh claude --skill to-issues)" >&2
    usage
  fi

  if [[ ! "$PLATFORM" =~ ^(all|claude|copilot|pi|codex)$ ]]; then
    echo "Error: invalid platform '$PLATFORM' — must be: all, claude, copilot, pi, or codex" >&2
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

# Every platform install.sh knows about. Order matters only for output readability.
PLATFORMS=(claude copilot pi codex)

# Registry skill paths are written Claude-style (.claude/skills/<name>). When a skill
# declares no install-<platform> override, swap the leading directory for the one that
# platform actually scans. Codex is the odd one out: it reads skills from .agents/skills
# (repo scope) and $HOME/.agents/skills (user scope), not .codex/skills.
default_skill_dest() {
  local platform="$1" claude_dest="$2"
  case "$platform" in
    codex) printf '%s' "${claude_dest/.claude\//.agents/}" ;;
    *) printf '%s' "${claude_dest/.claude\//.$platform/}" ;;
  esac
}

# pi keeps user-level resources under ~/.pi/agent/ but project-level ones under .pi/.
# Registry paths are written project-style; rewrite them when targeting $HOME.
# Codex needs no adjustment: .agents/skills and .codex/agents are the same relative
# paths at both project and user level.
adjust_platform_path() {
  local platform="$1" path="$2"
  if [[ "$platform" == "pi" && "$path" == .pi/* && "$REPO_ROOT" == "$HOME" ]]; then
    printf '.pi/agent/%s' "${path#.pi/}"
  else
    printf '%s' "$path"
  fi
}

assert_identifier() {
  local val="$1" label="$2"
  if [[ ! "$val" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "Error: invalid $label name '$val' — must match [a-zA-Z0-9_.-]+" >&2
    exit 1
  fi
}

# Helper: report whether an incoming file is new, identical, or changed
# Args: $1=incoming_content_file $2=dest_path
# Returns: 0=new, 1=identical, 2=changed
# Side effect: prints a one-line notice for changed files
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

install_skills() {
  local agent_name="$1"
  local skills
  skills=$(jq -r --arg name "$agent_name" '.agents[$name].skills // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  local skills_arr=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && skills_arr+=("$_line"); done <<< "$skills"
  for skill in "${skills_arr[@]+"${skills_arr[@]}"}"; do
    install_single_skill "$skill"
  done
}

install_agent() {
  local agent_name="$1"
  local platform="$2"

  assert_identifier "$agent_name" "agent"

  # Dedup per platform — `install_single_skill` fans platform=all out one platform at
  # a time, so keying on name alone would install an agent for the first platform only.
  if [[ "$INSTALLED" == *"|agent:$agent_name:$platform|"* ]]; then
    return
  fi

  if [[ "$platform" != "all" ]]; then
    local platforms
    platforms=$(jq -r --arg name "$agent_name" '.agents[$name].platforms // empty' "$SCRIPT_DIR/registry.json")
    if [[ -n "$platforms" ]] && ! echo "$platforms" | jq -e --arg p "$platform" 'index($p)' >/dev/null 2>&1; then
      echo "Skipping $agent_name (not available for $platform)"
      return
    fi
  fi

  INSTALLED="${INSTALLED}|agent:$agent_name:$platform|"

  echo "Installing $agent_name ($platform)..."

  install_skills "$agent_name"

  # Resolve agent source directory: use source-dir field if present, otherwise use agent name
  local agent_source_dir
  agent_source_dir=$(jq -r --arg name "$agent_name" '.agents[$name]["source-dir"] // $name' "$SCRIPT_DIR/registry.json")

  # Locate protocol source for {{PROTOCOL}} expansion (protocol.md tried first, then workflow.js)
  local protocol_file=""
  for candidate in "$SCRIPT_DIR/agents/$agent_source_dir/protocol.md" "$SCRIPT_DIR/agents/$agent_source_dir/workflow.js"; do
    if [[ -f "$candidate" ]]; then protocol_file="$candidate"; break; fi
  done

  expand_shim() {
    local src="$1" dest="$2"
    if grep -q '{{PROTOCOL}}' "$src" && [[ -z "$protocol_file" ]]; then
      echo "Error: $src contains {{PROTOCOL}} but no protocol.md or workflow.js found for $agent_name" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    
    # Generate content to temp file for diffing
    local tmpfile
    tmpfile=$(mktemp)
    trap "rm -f '$tmpfile'" RETURN
    
    if grep -q '{{PROTOCOL}}' "$src"; then
      {
        while IFS= read -r line; do
          if [[ "$line" == *'{{PROTOCOL}}'* ]]; then
            cat "$protocol_file"
          else
            printf '%s\n' "$line"
          fi
        done < "$src"
      } > "$tmpfile" || { rm -f "$tmpfile"; exit 1; }
    else
      cp "$src" "$tmpfile" || { rm -f "$tmpfile"; exit 1; }
    fi
    
    # Check and diff, then write
    local status=0
    check_dest_status "$tmpfile" "$dest" || status=$?
    chmod 0644 "$tmpfile"
    mv "$tmpfile" "$dest" || { rm -f "$tmpfile"; exit 1; }
    trap - RETURN

    # Print path only for new files (status=0)
    if [[ $status -eq 0 ]]; then
      local rel_dest="${dest#$REPO_ROOT/}"
      echo "  $rel_dest"
    fi
  }

  local target_platform
  for target_platform in "${PLATFORMS[@]}"; do
    [[ "$platform" == "$target_platform" || "$platform" == "all" ]] || continue

    local shim_dest shim_src shim_count
    shim_dest=$(jq -r --arg name "$agent_name" --arg p "$target_platform" '.agents[$name].install.shims[$p] // empty' "$SCRIPT_DIR/registry.json")
    shim_count=$(find "$SCRIPT_DIR/agents/$agent_source_dir" -maxdepth 1 -name "$target_platform.*" | wc -l)
    if [[ "$shim_count" -gt 1 ]]; then
      echo "Error: multiple $target_platform.* files in $SCRIPT_DIR/agents/$agent_source_dir — cannot determine which to install" >&2
      exit 1
    fi
    shim_src=$(find "$SCRIPT_DIR/agents/$agent_source_dir" -maxdepth 1 -name "$target_platform.*" | head -1)
    if [[ -n "$shim_src" && -n "$shim_dest" ]]; then
      assert_safe_path "$shim_dest" "$target_platform install"
      shim_dest=$(adjust_platform_path "$target_platform" "$shim_dest")
      expand_shim "$shim_src" "$REPO_ROOT/$shim_dest"
    fi
  done

  local agent_version
  agent_version=$(jq -r --arg n "$agent_name" '.agents[$n].version // "unknown"' "$SCRIPT_DIR/registry.json")
  MANIFEST_AGENT_ENTRIES+=("$agent_name $agent_version $platform")

  # Install deps recursively (platform-specific deps take priority)
  local deps_key="deps"
  if [[ "$platform" != "all" ]]; then
    local has_platform_deps
    has_platform_deps=$(jq -r --arg name "$agent_name" --arg p "$platform" '.agents[$name] | has("deps-" + $p)' "$SCRIPT_DIR/registry.json")
    if [[ "$has_platform_deps" == "true" ]]; then
      deps_key="deps-$platform"
    fi
  fi
  local deps
  deps=$(jq -r --arg name "$agent_name" --arg key "$deps_key" '.agents[$name][$key] // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  local deps_arr=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && deps_arr+=("$_line"); done <<< "$deps"
  for dep in "${deps_arr[@]+"${deps_arr[@]}"}"; do
    install_agent "$dep" "$platform"
  done
}

install_single_skill() {
  local skill_name="$1"
  assert_identifier "$skill_name" "skill"

  # For platform=all, fan out to every platform independently
  if [[ "$PLATFORM" == "all" ]]; then
    local saved_platform="$PLATFORM"
    local fan_platform
    for fan_platform in "${PLATFORMS[@]}"; do
      PLATFORM="$fan_platform"; install_single_skill "$skill_name"
    done
    PLATFORM="$saved_platform"
    return
  fi

  # Dedup per platform
  if [[ "$INSTALLED" == *"|skill:$skill_name:$PLATFORM|"* ]]; then
    return
  fi
  INSTALLED="${INSTALLED}|skill:$skill_name:$PLATFORM|"

  local skill_dest
  if [[ "$PLATFORM" != "claude" ]]; then
    # Non-Claude platforms may declare install-<platform>; otherwise the Claude path
    # is reused with .claude/ swapped for .<platform>/.
    skill_dest=$(jq -r --arg s "$skill_name" --arg p "install-$PLATFORM" '.skills[$s][$p] // empty' "$SCRIPT_DIR/registry.json")
    if [[ -z "$skill_dest" ]]; then
      local claude_dest
      claude_dest=$(jq -r --arg s "$skill_name" '.skills[$s].install // empty' "$SCRIPT_DIR/registry.json")
      [[ -n "$claude_dest" ]] && skill_dest=$(default_skill_dest "$PLATFORM" "$claude_dest")
    fi
  else
    skill_dest=$(jq -r --arg s "$skill_name" '.skills[$s].install // empty' "$SCRIPT_DIR/registry.json")
  fi
  if [[ -z "$skill_dest" ]]; then
    echo "Error: skill '$skill_name' not found in registry.json"
    echo "Available skills: $(jq -r '.skills | keys | join(", ")' "$SCRIPT_DIR/registry.json")"
    exit 1
  fi
  assert_safe_path "$skill_dest" "skill install"
  skill_dest=$(adjust_platform_path "$PLATFORM" "$skill_dest")
  
  # Resolve source directory: use source-dir field if present, otherwise use skill name
  local source_dir
  source_dir=$(jq -r --arg s "$skill_name" '.skills[$s]["source-dir"] // $s' "$SCRIPT_DIR/registry.json")
  
  [[ -d "$SCRIPT_DIR/skills/$source_dir" ]] || { echo "Error: skill source not found: skills/$source_dir" >&2; exit 1; }
  # Remove a stale symlink before mkdir -p; mkdir would succeed but cp into it would fail
  [[ -L "$REPO_ROOT/$skill_dest" ]] && rm -f "$REPO_ROOT/$skill_dest"
  mkdir -p "$REPO_ROOT/$skill_dest"
  
  # Resolve which SKILL.md this platform gets BEFORE copying. The installed file is
  # always named SKILL.md, so diffing the shared fallback against a previously
  # installed platform variant reports the entire file as changed on every
  # re-install. Pick the source now and copy it straight to SKILL.md.
  #
  # A `body` map in registry.json points several platforms at one shared body
  # (e.g. pi/codex/copilot → dispatch.SKILL.md), whose per-platform differences live
  # in fragments/<platform>/<key>.md and are inlined at install time by
  # scripts/render-skill.sh. Without a map entry the old convention still holds:
  # <platform>.SKILL.md, else the shared SKILL.md.
  local skill_md_source
  skill_md_source=$(jq -r --arg s "$skill_name" --arg p "$PLATFORM" '.skills[$s].body[$p] // empty' "$SCRIPT_DIR/registry.json")
  if [[ -z "$skill_md_source" ]]; then
    skill_md_source="SKILL.md"
    [[ -f "$SCRIPT_DIR/skills/$source_dir/$PLATFORM.SKILL.md" ]] && skill_md_source="$PLATFORM.SKILL.md"
  fi
  [[ -f "$SCRIPT_DIR/skills/$source_dir/$skill_md_source" ]] || {
    echo "Error: skill body not found: skills/$source_dir/$skill_md_source ($PLATFORM)" >&2; exit 1; }

  # platform-files gates individual source files to a single platform, so e.g. pi's
  # dispatch-agent.sh never lands in a codex install. Build two lists: paths gated to
  # some other platform (skipped, and pruned if an older install left them behind) and
  # paths gated to this one (copied normally).
  local -a foreign_files=()
  local foreign_index="|"
  local gate_platform gate_path
  for gate_platform in "${PLATFORMS[@]}"; do
    [[ "$gate_platform" == "$PLATFORM" ]] && continue
    while IFS= read -r gate_path; do
      gate_path="${gate_path%$'\r'}"
      [[ -n "$gate_path" ]] || continue
      foreign_files+=("$gate_path")
      foreign_index="${foreign_index}${gate_path}|"
    done < <(jq -r --arg s "$skill_name" --arg p "$gate_platform" '.skills[$s]["platform-files"][$p] // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  done

  # Copy files with diff output for changed files
  while IFS= read -r -d '' src_file; do
    local rel_path="${src_file#$SCRIPT_DIR/skills/$source_dir/}"
    # Fragments are build inputs, not runtime files — they are inlined into the
    # rendered SKILL.md and must never ship on their own.
    [[ "$rel_path" == fragments/* ]] && continue
    # Every *.SKILL.md competes for one destination: SKILL.md. Copy only the variant
    # this platform resolved to and skip the rest.
    if [[ "$rel_path" == "SKILL.md" || "$rel_path" == *".SKILL.md" ]]; then
      [[ "$rel_path" == "$skill_md_source" ]] || continue
      rel_path="SKILL.md"
    fi
    # Skip files another platform owns
    if [[ "$foreign_index" == *"|$rel_path|"* ]]; then
      continue
    fi
    local dest_file="$REPO_ROOT/$skill_dest/$rel_path"
    local rel_dest="${dest_file#$REPO_ROOT/}"
    mkdir -p "$(dirname "$dest_file")"

    # The body is rendered (placeholders expanded); every other file copies verbatim.
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
    [[ -n "$render_tmp" ]] && rm -f "$render_tmp"

    # Print path for new files (status=0)
    if [[ $status -eq 0 ]]; then
      echo "  $rel_dest"
    fi
  done < <(find "$SCRIPT_DIR/skills/$source_dir" -type f -not -name "test-*.sh" -print0)
  # Drop platform variants and shared bodies left behind by older installs, which
  # copied every variant and selected one afterwards. Also drop a fragments/ tree from
  # an install that predates rendering.
  local stale_body
  while IFS= read -r stale_body; do
    [[ -n "$stale_body" ]] && rm -f "$stale_body"
  done < <(find "$REPO_ROOT/$skill_dest" -maxdepth 1 -name "*.SKILL.md" 2>/dev/null || true)
  rm -rf "$REPO_ROOT/$skill_dest/fragments"
  # Drop other platforms' gated files left behind by older installs, which copied
  # every file regardless of platform.
  local foreign_file
  for foreign_file in "${foreign_files[@]+"${foreign_files[@]}"}"; do
    rm -f "$REPO_ROOT/$skill_dest/$foreign_file"
  done

  # Copy scripts from scripts/skill-utils/git-workflow/ if this skill declares any
  local scripts
  scripts=$(jq -r --arg s "$skill_name" '.skills[$s].scripts // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  local scripts_arr=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && scripts_arr+=("$_line"); done <<< "$scripts"
  if [[ "${#scripts_arr[@]}" -gt 0 ]]; then
    mkdir -p "$REPO_ROOT/$skill_dest/scripts"
    for script in "${scripts_arr[@]}"; do
      local script_src="$SCRIPT_DIR/scripts/skill-utils/git-workflow/$script"
      if [[ ! -f "$script_src" ]]; then
        echo "Error: script source not found: scripts/skill-utils/git-workflow/$script" >&2
        exit 1
      fi
      cp "$script_src" "$REPO_ROOT/$skill_dest/scripts/$script"
      chmod +x "$REPO_ROOT/$skill_dest/scripts/$script"
    done
    echo "  $skill_dest/scripts/ (${#scripts_arr[@]} scripts from skill-utils/git-workflow)"
  fi

  local skill_version
  skill_version=$(jq -r --arg s "$skill_name" '.skills[$s].version // "unknown"' "$SCRIPT_DIR/registry.json")
  MANIFEST_SKILL_ENTRIES+=("$skill_name $skill_version")

  # Resolve skill-level deps declared in registry.json
  local deps
  deps=$(jq -r --arg s "$skill_name" '.skills[$s].deps // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  local deps_arr=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && deps_arr+=("$_line"); done <<< "$deps"
  for dep in "${deps_arr[@]+"${deps_arr[@]}"}"; do
    install_single_skill "$dep"
  done

  # Resolve agent-deps — agents this skill requires at runtime
  local agent_deps
  agent_deps=$(jq -r --arg s "$skill_name" '.skills[$s]["agent-deps"] // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  local agent_deps_arr=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && agent_deps_arr+=("$_line"); done <<< "$agent_deps"
  for dep in "${agent_deps_arr[@]+"${agent_deps_arr[@]}"}"; do
    install_agent "$dep" "$PLATFORM"
  done
}

install_docs() {
  # Copy doc templates to the target repo, skipping any that already exist.
  # Source definitions come from registry.json .docs.templates.
  local templates
  templates=$(jq -r '.docs.templates // {} | keys[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  local templates_arr=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && templates_arr+=("$_line"); done <<< "$templates"

  local docs_header_printed=0
  for tpl in "${templates_arr[@]+"${templates_arr[@]}"}"; do
    local src_rel dest_rel
    src_rel=$(jq -r --arg t "$tpl" '.docs.templates[$t].source // empty' "$SCRIPT_DIR/registry.json")
    dest_rel=$(jq -r --arg t "$tpl" '.docs.templates[$t].dest // empty' "$SCRIPT_DIR/registry.json")

    [[ -z "$src_rel" || -z "$dest_rel" ]] && continue

    local src="$SCRIPT_DIR/$src_rel"
    local dest="$REPO_ROOT/$dest_rel"

    [[ -f "$src" ]] || { echo "Warning: doc template source not found: $src_rel" >&2; continue; }

    if [[ -f "$dest" ]]; then
      # Already exists — skip (never overwrite user-customised docs)
      continue
    fi

    [[ "$docs_header_printed" -eq 0 ]] && { echo "Docs:"; docs_header_printed=1; }
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    local rel_dest="${dest#$REPO_ROOT/}"
    echo "  $rel_dest"
  done

  # Copy tracker template files so configure-tracker can present them as options.
  local trackers_src="$SCRIPT_DIR/docs/templates/trackers"
  local trackers_dest="$REPO_ROOT/.coding-crew/docs/templates/trackers"
  if [[ -d "$trackers_src" ]]; then
    mkdir -p "$trackers_dest"
    while IFS= read -r -d '' tpl_file; do
      local tpl_dest="$trackers_dest/$(basename "$tpl_file")"
      if [[ ! -f "$tpl_dest" ]]; then
        [[ "$docs_header_printed" -eq 0 ]] && { echo "Docs:"; docs_header_printed=1; }
        cp "$tpl_file" "$tpl_dest"
        echo "  .coding-crew/docs/templates/trackers/$(basename "$tpl_file")"
      fi
    done < <(find "$trackers_src" -maxdepth 1 -name "*.md" -print0)
  fi
}

# A user-level install of the same skill or agent can take precedence over the copy we
# just wrote into the project, so a project install silently has no effect and the
# consumer debugs against a stale definition. We cannot change the host agent's
# resolution order, so say so plainly instead.
warn_shadowing_user_installs() {
  [[ "$REPO_ROOT" == "$HOME" ]] && return 0

  local found=()
  local d
  for d in "$HOME/.pi/agent/skills" "$HOME/.pi/agent/agents" \
           "$HOME/.claude/skills" "$HOME/.claude/agents" \
           "$HOME/.copilot/skills" "$HOME/.copilot/agents" \
           "$HOME/.agents/skills" "$HOME/.codex/agents"; do
    [[ -d "$d" ]] || continue
    local name
    for name in crew-afk crew-coder crew-code-reviewer solve-issue; do
      if [[ -e "$d/$name" || -e "$d/$name.md" || -e "$d/$name.toml" || -e "$d/$name.agent.md" ]]; then
        found+=("$d/$name")
      fi
    done
  done

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

  # Build agents JSON from collected entries
  local agents_json="{}"
  for entry in "${MANIFEST_AGENT_ENTRIES[@]+"${MANIFEST_AGENT_ENTRIES[@]}"}"; do
    local name version platform_val
    read -r name version platform_val <<< "$entry"
    agents_json=$(jq -n --argjson base "$agents_json" --arg n "$name" --arg v "$version" --arg p "$platform_val" \
      '$base | .[$n] = {version: $v, platform: $p}')
  done

  # Build skills JSON from collected entries
  local skills_json="{}"
  for entry in "${MANIFEST_SKILL_ENTRIES[@]+"${MANIFEST_SKILL_ENTRIES[@]}"}"; do
    local name version
    read -r name version <<< "$entry"
    skills_json=$(jq -n --argjson base "$skills_json" --arg n "$name" --arg v "$version" \
      '$base | .[$n] = {version: $v}')
  done

  # Merge with existing manifest so entries from prior installs are preserved
  local existing_agents="{}" existing_skills="{}"
  if [[ -f "$manifest" ]]; then
    existing_agents=$(jq '.agents // {}' "$manifest")
    existing_skills=$(jq '.skills // {}' "$manifest")
  fi

  jq -n \
    --arg sha "$source_sha" \
    --arg remote "$source_remote" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --arg platform "$PLATFORM" \
    --argjson existing_agents "$existing_agents" \
    --argjson new_agents "$agents_json" \
    --argjson existing_skills "$existing_skills" \
    --argjson new_skills "$skills_json" \
    '{
      source: $remote,
      source_sha: $sha,
      installed_at: $ts,
      platform: $platform,
      agents: ($existing_agents * $new_agents),
      skills: ($existing_skills * $new_skills)
    }' > "$manifest"

  echo "  .coding-crew/manifest.json"
}

# git remotes are often SSH (git@github.com:owner/repo.git); the release/tarball
# endpoints need an https URL, so normalise before using or recording one.
normalize_registry_url() {
  local url="${1%.git}"
  case "$url" in
    git@*:*)
      url="${url#git@}"          # github.com:owner/repo
      url="https://${url/://}"   # https://github.com/owner/repo
      ;;
    ssh://git@*) url="https://${url#ssh://git@}" ;;
  esac
  printf '%s' "$url"
}

# crew.lock records the release as "v<semver>", but tarball URLs and version
# comparisons need the bare semver. Normalise on read rather than changing the
# recorded format, so lockfiles written by older versions keep working.
lock_bare_version() { printf '%s' "${1#v}"; }

# Reads one item's version out of a lockfile. write_lockfile records objects
# ({"version": "1.2.3"}); older lockfiles recorded a bare string, so accept both
# — reading the object as if it were a string is what made every comparison
# downstream see a mismatch and reinstall unconditionally.
lock_item_version() {
  local lockfile="$1" section="$2" name="$3"
  jq -r --arg s "$section" --arg n "$name" \
    'getpath([$s, $n]) as $e
     | if ($e | type) == "object" then ($e.version // empty)
       elif ($e | type) == "string" then $e
       else empty end' "$lockfile"
}

# Writes crew.lock recording the pinned version/registry, the platform installed
# for, plus the agents/skills just installed. Only called when --version was
# passed — see PIN_VERSION above.
write_lockfile() {
  local registry="$PIN_REGISTRY"
  if [[ -z "$registry" ]]; then
    registry=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "")
  fi
  if [[ -z "$registry" ]]; then
    echo "Warning: could not determine registry URL (no git remote and no --registry given) — skipping crew.lock" >&2
    return
  fi
  registry=$(normalize_registry_url "$registry")

  local agents_json="{}"
  for entry in "${MANIFEST_AGENT_ENTRIES[@]+"${MANIFEST_AGENT_ENTRIES[@]}"}"; do
    local name version platform_val
    read -r name version platform_val <<< "$entry"
    agents_json=$(jq -n --argjson base "$agents_json" --arg n "$name" --arg v "$version" \
      '$base | .[$n] = {version: $v}')
  done

  local skills_json="{}"
  for entry in "${MANIFEST_SKILL_ENTRIES[@]+"${MANIFEST_SKILL_ENTRIES[@]}"}"; do
    local name version
    read -r name version <<< "$entry"
    skills_json=$(jq -n --argjson base "$skills_json" --arg n "$name" --arg v "$version" \
      '$base | .[$n] = {version: $v}')
  done

  # Record the platform too: without it, --update from a lockfile fell back to
  # "all" and reinstalled every platform over a single-platform install.
  jq -n \
    --arg registry "$registry" \
    --arg version "v$(lock_bare_version "$PIN_VERSION")" \
    --arg platform "$PLATFORM" \
    --argjson agents "$agents_json" \
    --argjson skills "$skills_json" \
    '{
      registry: $registry,
      version: $version,
      platform: $platform,
      agents: $agents,
      skills: $skills
    }' > "$REPO_ROOT/crew.lock"

  echo "  crew.lock (pinned to $PIN_VERSION)"
}

fetch_latest_release_version() {
  local registry_url
  registry_url=$(normalize_registry_url "$1")
  local url="${registry_url}/releases/latest"
  
  # Follow redirect and get final URL
  local final_url
  if ! final_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$url" 2>&1); then
    echo "Error: failed to fetch latest release from $url" >&2
    echo "Network error or no releases available" >&2
    return 1
  fi
  
  # Extract tag from URL like https://github.com/owner/repo/releases/tag/v1.2.3
  local tag
  tag=$(echo "$final_url" | sed -E 's|.*/releases/tag/([^/]+)$|\1|')
  local version="${tag#v}"  # Strip leading 'v' if present
  
  if [[ -z "$version" ]]; then
    echo "Error: failed to extract version from $final_url" >&2
    return 1
  fi
  
  echo "$version"
}

# Turns --version latest into the concrete newest release tag; any other value is
# left untouched. Called just before write_lockfile so the recorded version is
# always reproducible.
resolve_pin_version() {
  [[ "$PIN_VERSION" == "latest" ]] || return 0

  local registry="$PIN_REGISTRY"
  if [[ -z "$registry" ]]; then
    registry=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || echo "")
  fi
  if [[ -z "$registry" ]]; then
    echo "Error: --version latest needs a registry URL (no git remote and no --registry given)" >&2
    exit 1
  fi
  registry=$(normalize_registry_url "$registry")

  local resolved
  if ! resolved=$(fetch_latest_release_version "$registry"); then
    exit 1
  fi
  PIN_VERSION="v${resolved#v}"
  echo "Resolved --version latest to $PIN_VERSION"
}

run_update_from_lockfile() {
  local lockfile="$REPO_ROOT/crew.lock"
  
  if [[ ! -f "$lockfile" ]]; then
    echo "Error: crew.lock not found at $lockfile" >&2
    return 1
  fi
  
  # Read lockfile
  local current_version registry lock_platform
  current_version=$(jq -r '.version // empty' "$lockfile")
  registry=$(jq -r '.registry // empty' "$lockfile")
  lock_platform=$(jq -r '.platform // empty' "$lockfile")
  
  if [[ -z "$current_version" || -z "$registry" ]]; then
    echo "Error: crew.lock missing required fields (version, registry)" >&2
    exit 1
  fi

  # Lockfiles written before platform was recorded fall back to the manifest,
  # then to "all" — never silently widen a single-platform install.
  if [[ -z "$lock_platform" ]]; then
    local prior_manifest="$REPO_ROOT/.coding-crew/manifest.json"
    if [[ -f "$prior_manifest" ]]; then
      lock_platform=$(jq -r '.platform // empty' "$prior_manifest")
    fi
  fi
  PLATFORM="${lock_platform:-all}"

  current_version=$(lock_bare_version "$current_version")
  
  echo "Current version: v${current_version} (from crew.lock)"
  echo "Platform: $PLATFORM (from crew.lock)"
  echo "Checking for updates from $registry..."
  
  # Fetch latest release version
  local latest_version
  if ! latest_version=$(fetch_latest_release_version "$registry"); then
    exit 1
  fi
  latest_version=$(lock_bare_version "$latest_version")
  
  echo "Latest version: v${latest_version}"
  echo "---"
  
  # Compare versions
  if [[ "$current_version" == "$latest_version" ]]; then
    echo "Already at v${current_version} — nothing to update"
    exit 0
  fi
  
  echo "Update available: v${current_version} → v${latest_version}"
  echo "Fetching registry tarball..."
  
  # Create temp directory for tarball extraction
  local temp_dir
  temp_dir=$(mktemp -d)
  trap "rm -rf '$temp_dir'" EXIT
  
  # Fetch and extract tarball
  local tarball_url="${registry}/archive/refs/tags/v${latest_version}.tar.gz"
  if ! curl -fsSL "$tarball_url" | tar -xz -C "$temp_dir"; then
    echo "Error: failed to fetch or extract tarball from $tarball_url" >&2
    exit 1
  fi
  
  # Find extracted directory
  local extracted_dir
  extracted_dir=$(find "$temp_dir" -maxdepth 1 -type d | grep -v "^$temp_dir$" | head -1)
  if [[ -z "$extracted_dir" || ! -d "$extracted_dir" ]]; then
    echo "Error: failed to locate extracted registry directory in $temp_dir" >&2
    exit 1
  fi
  
  # Override SCRIPT_DIR to point to the extracted registry
  SCRIPT_DIR="$extracted_dir"
  
  echo "---"
  echo "Updating agents and skills..."
  
  local updated=0
  local changelog=()
  
  # Update agents from lockfile
  while IFS= read -r agent_name; do
    local old_version new_version
    old_version=$(lock_item_version "$lockfile" agents "$agent_name")
    old_version="${old_version:-unknown}"
    new_version=$(jq -r --arg n "$agent_name" '.agents[$n].version // empty' "$SCRIPT_DIR/registry.json")
    
    if [[ -z "$new_version" ]]; then
      echo "  $agent_name: removed from registry — skipping"
      continue
    fi
    
    if [[ "$old_version" != "$new_version" ]]; then
      changelog+=("  $agent_name: $old_version → $new_version")
      install_agent "$agent_name" "$PLATFORM"
      updated=$((updated + 1))
    fi
  done < <(jq -r '.agents | keys[]' "$lockfile")
  
  # Update skills from lockfile
  while IFS= read -r skill_name; do
    local old_version new_version
    old_version=$(lock_item_version "$lockfile" skills "$skill_name")
    old_version="${old_version:-unknown}"
    new_version=$(jq -r --arg n "$skill_name" '.skills[$n].version // empty' "$SCRIPT_DIR/registry.json")
    
    if [[ -z "$new_version" ]]; then
      echo "  $skill_name: removed from registry — skipping"
      continue
    fi
    
    if [[ "$old_version" != "$new_version" ]]; then
      changelog+=("  $skill_name: $old_version → $new_version")
      install_single_skill "$skill_name"
      updated=$((updated + 1))
    fi
  done < <(jq -r '.skills | keys[]' "$lockfile")
  
  # Rewrite lockfile with new version and updated item versions. Item entries stay
  # in write_lockfile's object form so the next --update can read them back.
  local new_agents_json="{}"
  while IFS= read -r agent_name; do
    local version
    version=$(jq -r --arg n "$agent_name" '.agents[$n].version // empty' "$SCRIPT_DIR/registry.json")
    if [[ -n "$version" ]]; then
      new_agents_json=$(jq -n --argjson base "$new_agents_json" --arg n "$agent_name" --arg v "$version" \
        '$base | .[$n] = {version: $v}')
    fi
  done < <(jq -r '.agents | keys[]' "$lockfile")
  
  local new_skills_json="{}"
  while IFS= read -r skill_name; do
    local version
    version=$(jq -r --arg n "$skill_name" '.skills[$n].version // empty' "$SCRIPT_DIR/registry.json")
    if [[ -n "$version" ]]; then
      new_skills_json=$(jq -n --argjson base "$new_skills_json" --arg n "$skill_name" --arg v "$version" \
        '$base | .[$n] = {version: $v}')
    fi
  done < <(jq -r '.skills | keys[]' "$lockfile")
  
  jq -n \
    --arg registry "$registry" \
    --arg version "v${latest_version}" \
    --arg platform "$PLATFORM" \
    --argjson agents "$new_agents_json" \
    --argjson skills "$new_skills_json" \
    '{
      registry: $registry,
      version: $version,
      platform: $platform,
      agents: $agents,
      skills: $skills
    }' > "$lockfile"
  
  echo "---"
  if [[ "$updated" -gt 0 ]]; then
    echo "Changes:"
    for line in "${changelog[@]}"; do
      echo "$line"
    done
    echo "---"
  fi
  echo "$updated item(s) updated"
  echo "crew.lock updated to v${latest_version}"
}

run_update() {
  # Check for crew.lock first
  if [[ -f "$REPO_ROOT/crew.lock" ]]; then
    run_update_from_lockfile
    if [[ "${#MANIFEST_AGENT_ENTRIES[@]}" -gt 0 || "${#MANIFEST_SKILL_ENTRIES[@]}" -gt 0 ]]; then
      write_manifest
    fi
    return
  fi
  
  # Fall back to manifest-based update (legacy mode)
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

  # Check agents
  while IFS= read -r name; do
    local installed_version current_version
    installed_version=$(jq -r --arg n "$name" '.agents[$n].version // "unknown"' "$manifest")
    current_version=$(jq -r --arg n "$name" '.agents[$n].version // empty' "$SCRIPT_DIR/registry.json")
    if [[ -z "$current_version" ]]; then
      echo "  $name: removed from registry — skipping"
      continue
    fi
    if [[ "$installed_version" != "$current_version" ]]; then
      echo "  Updating $name: $installed_version → $current_version"
      install_agent "$name" "$saved_platform"
      updated=$((updated + 1))
    else
      echo "  $name $installed_version: up to date"
    fi
  done < <(jq -r '.agents | keys[]' "$manifest")

  # Check skills
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

run_from_lockfile() {
  local lockfile="$1"
  
  # Validate lockfile format
  if ! jq empty "$lockfile" 2>/dev/null; then
    echo "Error: invalid JSON in lockfile: $lockfile" >&2
    exit 1
  fi
  
  local registry version lock_platform
  registry=$(jq -r '.registry // empty' "$lockfile")
  version=$(jq -r '.version // empty' "$lockfile")
  lock_platform=$(jq -r '.platform // empty' "$lockfile")
  
  if [[ -z "$registry" || -z "$version" ]]; then
    echo "Error: lockfile must contain 'registry' and 'version' fields" >&2
    exit 1
  fi

  # The lockfile records "v<semver>"; tags/URLs are built from the bare semver.
  version=$(lock_bare_version "$version")
  # Reproduce the platform the lockfile was written for, not "all".
  PLATFORM="${lock_platform:-all}"
  
  echo "Lockfile: $lockfile"
  echo "Registry: $registry"
  echo "Version: v${version}"
  echo "Platform: $PLATFORM"
  echo "---"

  # file:// registries point directly to a local directory — no tarball fetch needed
  if [[ "$registry" == file://* ]]; then
    local local_path="${registry#file://}"
    if [[ ! -d "$local_path" ]]; then
      echo "Error: local registry path does not exist: $local_path" >&2
      exit 1
    fi
    SCRIPT_DIR="$local_path"
  else
    # Construct tarball URL
    local tarball_url="${registry}/archive/refs/tags/v${version}.tar.gz"
    echo "Fetching registry tarball from: $tarball_url"

    # Create temp directory with cleanup trap
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf '$temp_dir'" EXIT

    # Fetch and extract tarball
    if ! curl -fsSL "$tarball_url" | tar -xz -C "$temp_dir"; then
      echo "Error: failed to fetch or extract tarball from $tarball_url" >&2
      exit 1
    fi

    # Find the extracted directory (GitHub tarballs extract to owner-repo-sha/)
    local extracted_dir
    extracted_dir=$(find "$temp_dir" -maxdepth 1 -type d | grep -v "^$temp_dir$" | head -1)
    if [[ -z "$extracted_dir" || ! -d "$extracted_dir" ]]; then
      echo "Error: failed to locate extracted registry directory in $temp_dir" >&2
      exit 1
    fi

    echo "Extracted to: $extracted_dir"
    SCRIPT_DIR="$extracted_dir"
  fi
  
  # Install agents from lockfile
  local agents_json
  agents_json=$(jq -r '.agents // {}' "$lockfile")
  if [[ "$agents_json" != "{}" ]]; then
    echo "---"
    echo "Installing agents from lockfile..."
    while IFS= read -r agent_name; do
      local lockfile_version registry_version
      lockfile_version=$(lock_item_version "$lockfile" agents "$agent_name")
      registry_version=$(jq -r --arg n "$agent_name" '.agents[$n].version // empty' "$SCRIPT_DIR/registry.json")
      
      if [[ -z "$registry_version" ]]; then
        echo "Warning: agent '$agent_name' not found in registry v${version} — skipping"
        continue
      fi
      
      if [[ -n "$lockfile_version" && "$lockfile_version" != "$registry_version" ]]; then
        echo "Warning: agent '$agent_name' version mismatch (lockfile: $lockfile_version, registry: $registry_version) — using registry version"
      fi
      
      install_agent "$agent_name" "$PLATFORM"
    done < <(jq -r '.agents | keys[]' "$lockfile")
  fi
  
  # Install skills from lockfile
  local skills_json
  skills_json=$(jq -r '.skills // {}' "$lockfile")
  if [[ "$skills_json" != "{}" ]]; then
    echo "---"
    echo "Installing skills from lockfile..."
    while IFS= read -r skill_name; do
      local lockfile_version registry_version
      lockfile_version=$(lock_item_version "$lockfile" skills "$skill_name")
      registry_version=$(jq -r --arg n "$skill_name" '.skills[$n].version // empty' "$SCRIPT_DIR/registry.json")
      
      if [[ -z "$registry_version" ]]; then
        echo "Warning: skill '$skill_name' not found in registry v${version} — skipping"
        continue
      fi
      
      if [[ -n "$lockfile_version" && "$lockfile_version" != "$registry_version" ]]; then
        echo "Warning: skill '$skill_name' version mismatch (lockfile: $lockfile_version, registry: $registry_version) — using registry version"
      fi
      
      install_single_skill "$skill_name"
    done < <(jq -r '.skills | keys[]' "$lockfile")
  fi
}

echo "Target: $REPO_ROOT"

if [[ "$UPDATE_MODE" == "true" ]]; then
  run_update
  if [[ "${#MANIFEST_AGENT_ENTRIES[@]}" -gt 0 || "${#MANIFEST_SKILL_ENTRIES[@]}" -gt 0 ]]; then
    write_manifest
  fi
  echo "Done."
  exit 0
fi

if [[ "$LOCKFILE_MODE" == "true" ]]; then
  run_from_lockfile "$LOCKFILE_PATH"
  echo "---"
  write_manifest
  echo "Done."
  exit 0
fi

echo "Platform: $PLATFORM"

if [[ "$AGENT" == "--skill" ]]; then
  if [[ -n "$SKILLS_LIST" ]]; then
    # --skills a,b,c  path
    echo "Skills: $SKILLS_LIST"
    echo "---"
    IFS=',' read -ra _skills_arr <<< "$SKILLS_LIST"
    for _s in "${_skills_arr[@]}"; do
      _s="${_s// /}"  # trim spaces
      [[ -n "$_s" ]] && install_single_skill "$_s"
    done
    unset _skills_arr _s
  else
    # --skill <name>  path
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
  echo "Agent: $AGENT"
  echo "---"
  agent_names=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && agent_names+=("$_line"); done < <(jq -r '.agents | keys[]' "$SCRIPT_DIR/registry.json")
  for agent_name in "${agent_names[@]}"; do
    install_agent "$agent_name" "$PLATFORM"
  done
  # Install all standalone skills — not just those wired to agents as deps
  skill_names=()
  while IFS= read -r _line; do _line="${_line%$'\r'}"; [[ -n "$_line" ]] && skill_names+=("$_line"); done < <(jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json")
  for skill_name in "${skill_names[@]}"; do
    install_single_skill "$skill_name"
  done
else
  echo "Agent: $AGENT"
  echo "---"
  install_agent "$AGENT" "$PLATFORM"
fi

install_docs
echo "---"
write_manifest
if [[ -n "$PIN_VERSION" ]]; then
  resolve_pin_version
  write_lockfile
fi

warn_shadowing_user_installs

echo "Done."
