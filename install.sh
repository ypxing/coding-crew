#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Pre-scan for --user flag (strip it; remaining args keep their positions)
INSTALL_LEVEL="project"
_filtered=()
for _arg in "$@"; do
  if [[ "$_arg" == "--user" ]]; then
    INSTALL_LEVEL="user"
  else
    _filtered+=("$_arg")
  fi
done
set -- "${_filtered[@]+"${_filtered[@]}"}"
unset _filtered _arg

if [[ "$INSTALL_LEVEL" == "user" ]]; then
  REPO_ROOT="$HOME"
else
  REPO_ROOT="${TARGET_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
fi

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
  LOCKFILE_PATH="${2:-}"
  if [[ -z "$LOCKFILE_PATH" ]]; then
    echo "Error: --from-lockfile requires a path to a lockfile" >&2
    exit 1
  fi
  if [[ ! -f "$LOCKFILE_PATH" ]]; then
    echo "Error: lockfile not found: $LOCKFILE_PATH" >&2
    exit 1
  fi
  PLATFORM="all"
  AGENT="all"
else
  PLATFORM="${1:-all}"    # all | claude | copilot
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
  echo "Usage: ./install.sh [--user] [platform] [agent]"
  echo "       ./install.sh [--user] [platform] --skill <skill-name>"
  echo "       ./install.sh [--user] [platform] --skills <a,b,c>"
  echo "       ./install.sh [--user] --update"
  echo "       ./install.sh [--user] --from-lockfile <path>"
  echo ""
  echo "  --user:          install to \$HOME (user-level); default installs into the current project repo"
  echo "  platform:        all (default), claude, copilot"
  echo "  agent:           all (default), crew-code-reviewer, crew-coder"
  echo "  --skill:         install a single skill (e.g. to-issues)"
  echo "  --skills:        install multiple skills (comma-separated, e.g. tdd,caveman,grill-me)"
  echo "  --update:        re-install only agents/skills whose version changed since last install"
  echo "  --from-lockfile: install from a lockfile (fetches pinned registry version and installs listed items)"
  echo ""
  echo "Examples:"
  echo "  ./install.sh                                      # install everything into project"
  echo "  ./install.sh --user                               # install everything into \$HOME"
  echo "  ./install.sh --user claude --skill tdd            # one skill into \$HOME/.claude/skills/"
  echo "  ./install.sh --user claude --skills tdd,caveman   # multiple skills at once"
  echo "  ./install.sh claude --skill crew-afk            # crew-afk + crew-coder + crew-code-reviewer"
  echo "  ./install.sh --update                             # update all installed agents/skills"
  echo "  ./install.sh --from-lockfile crew.lock            # install from lockfile"
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

  if [[ ! "$PLATFORM" =~ ^(all|claude|copilot)$ ]]; then
    echo "Error: invalid platform '$PLATFORM' — must be: all, claude, or copilot" >&2
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

assert_identifier() {
  local val="$1" label="$2"
  if [[ ! "$val" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo "Error: invalid $label name '$val' — must match [a-zA-Z0-9_.-]+" >&2
    exit 1
  fi
}

# Helper: print diff if destination exists and differs from incoming content
# Args: $1=incoming_content_file $2=dest_path
# Returns: 0=new, 1=identical, 2=changed
# Side effect: prints labeled diff for changed files
check_and_diff() {
  local incoming="$1" dest="$2"
  if [[ ! -f "$dest" ]]; then
    return 0  # new file
  fi
  if cmp -s "$incoming" "$dest"; then
    return 1  # identical
  fi
  # Files differ — print labeled diff
  local rel_dest="${dest#$REPO_ROOT/}"
  echo "  $rel_dest (updated)"
  diff -u "$dest" "$incoming" | sed "1s|^--- .*|--- $rel_dest|; 2s|^+++ .*|+++ incoming|" || true
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

  if [[ "$INSTALLED" == *"|$agent_name|"* ]]; then
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

  INSTALLED="${INSTALLED}|$agent_name|"

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
    check_and_diff "$tmpfile" "$dest" || status=$?
    chmod 0644 "$tmpfile"
    mv "$tmpfile" "$dest" || { rm -f "$tmpfile"; exit 1; }
    trap - RETURN

    # Print path only for new files (status=0)
    if [[ $status -eq 0 ]]; then
      local rel_dest="${dest#$REPO_ROOT/}"
      echo "  $rel_dest"
    fi
  }

  if [[ "$platform" == "claude" || "$platform" == "all" ]]; then
    local claude_dest claude_src
    claude_dest=$(jq -r --arg name "$agent_name" '.agents[$name].install.shims.claude // empty' "$SCRIPT_DIR/registry.json")
    local claude_count
    claude_count=$(find "$SCRIPT_DIR/agents/$agent_source_dir" -maxdepth 1 -name "claude.*" | wc -l)
    if [[ "$claude_count" -gt 1 ]]; then
      echo "Error: multiple claude.* files in $SCRIPT_DIR/agents/$agent_source_dir — cannot determine which to install" >&2
      exit 1
    fi
    claude_src=$(find "$SCRIPT_DIR/agents/$agent_source_dir" -maxdepth 1 -name "claude.*" | head -1)
    if [[ -n "$claude_src" && -n "$claude_dest" ]]; then
      assert_safe_path "$claude_dest" "claude install"
      expand_shim "$claude_src" "$REPO_ROOT/$claude_dest"
    fi
  fi

  if [[ "$platform" == "copilot" || "$platform" == "all" ]]; then
    local copilot_dest copilot_src
    copilot_dest=$(jq -r --arg name "$agent_name" '.agents[$name].install.shims.copilot // empty' "$SCRIPT_DIR/registry.json")
    local copilot_count
    copilot_count=$(find "$SCRIPT_DIR/agents/$agent_source_dir" -maxdepth 1 -name "copilot.*" | wc -l)
    if [[ "$copilot_count" -gt 1 ]]; then
      echo "Error: multiple copilot.* files in $SCRIPT_DIR/agents/$agent_source_dir — cannot determine which to install" >&2
      exit 1
    fi
    copilot_src=$(find "$SCRIPT_DIR/agents/$agent_source_dir" -maxdepth 1 -name "copilot.*" | head -1)
    if [[ -n "$copilot_src" && -n "$copilot_dest" ]]; then
      assert_safe_path "$copilot_dest" "copilot install"
      expand_shim "$copilot_src" "$REPO_ROOT/$copilot_dest"
    fi
  fi

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

  # For platform=all, fan out to both platforms independently
  if [[ "$PLATFORM" == "all" ]]; then
    local saved_platform="$PLATFORM"
    PLATFORM="claude";  install_single_skill "$skill_name"
    PLATFORM="copilot"; install_single_skill "$skill_name"
    PLATFORM="$saved_platform"
    return
  fi

  # Dedup per platform
  if [[ "$INSTALLED" == *"|skill:$skill_name:$PLATFORM|"* ]]; then
    return
  fi
  INSTALLED="${INSTALLED}|skill:$skill_name:$PLATFORM|"

  local skill_dest
  if [[ "$PLATFORM" == "copilot" ]]; then
    skill_dest=$(jq -r --arg s "$skill_name" '.skills[$s]["install-copilot"] // empty' "$SCRIPT_DIR/registry.json")
    if [[ -z "$skill_dest" ]]; then
      local claude_dest
      claude_dest=$(jq -r --arg s "$skill_name" '.skills[$s].install // empty' "$SCRIPT_DIR/registry.json")
      skill_dest="${claude_dest/.claude\//.copilot/}"
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
  
  # Resolve source directory: use source-dir field if present, otherwise use skill name
  local source_dir
  source_dir=$(jq -r --arg s "$skill_name" '.skills[$s]["source-dir"] // $s' "$SCRIPT_DIR/registry.json")
  
  [[ -d "$SCRIPT_DIR/skills/$source_dir" ]] || { echo "Error: skill source not found: skills/$source_dir" >&2; exit 1; }
  # Remove a stale symlink before mkdir -p; mkdir would succeed but cp into it would fail
  [[ -L "$REPO_ROOT/$skill_dest" ]] && rm -f "$REPO_ROOT/$skill_dest"
  mkdir -p "$REPO_ROOT/$skill_dest"
  
  # Copy files with diff output for changed files
  while IFS= read -r -d '' src_file; do
    local rel_path="${src_file#$SCRIPT_DIR/skills/$source_dir/}"
    local dest_file="$REPO_ROOT/$skill_dest/$rel_path"
    local rel_dest="${dest_file#$REPO_ROOT/}"
    mkdir -p "$(dirname "$dest_file")"
    
    local status=0
    check_and_diff "$src_file" "$dest_file" || status=$?
    cp "$src_file" "$dest_file"
    
    # Print path for new files (status=0)
    if [[ $status -eq 0 ]]; then
      echo "  $rel_dest"
    fi
  done < <(find "$SCRIPT_DIR/skills/$source_dir" -type f -not -name "test-*.sh" -print0)
  # Select the right SKILL.md:
  #   claude.SKILL.md / copilot.SKILL.md  — platform-specific variant wins when present
  #   SKILL.md                             — shared fallback used by both platforms
  if [[ "$PLATFORM" == "copilot" && -f "$REPO_ROOT/$skill_dest/copilot.SKILL.md" ]]; then
    rm -f "$REPO_ROOT/$skill_dest/SKILL.md"
    mv "$REPO_ROOT/$skill_dest/copilot.SKILL.md" "$REPO_ROOT/$skill_dest/SKILL.md"
  elif [[ "$PLATFORM" == "claude" && -f "$REPO_ROOT/$skill_dest/claude.SKILL.md" ]]; then
    rm -f "$REPO_ROOT/$skill_dest/SKILL.md"
    mv "$REPO_ROOT/$skill_dest/claude.SKILL.md" "$REPO_ROOT/$skill_dest/SKILL.md"
  fi
  # Drop whichever platform variants weren't selected
  rm -f "$REPO_ROOT/$skill_dest/copilot.SKILL.md" "$REPO_ROOT/$skill_dest/claude.SKILL.md"

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

write_manifest() {
  local manifest="$REPO_ROOT/.coding-crew.manifest.json"

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

  echo "  .coding-crew.manifest.json"
}

fetch_latest_release_version() {
  local registry_url="$1"
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

run_update_from_lockfile() {
  local lockfile="$REPO_ROOT/crew.lock"
  
  if [[ ! -f "$lockfile" ]]; then
    echo "Error: crew.lock not found at $lockfile" >&2
    return 1
  fi
  
  # Read lockfile
  local current_version registry
  current_version=$(jq -r '.version // empty' "$lockfile")
  registry=$(jq -r '.registry // empty' "$lockfile")
  
  if [[ -z "$current_version" || -z "$registry" ]]; then
    echo "Error: crew.lock missing required fields (version, registry)" >&2
    exit 1
  fi
  
  echo "Current version: $current_version (from crew.lock)"
  echo "Checking for updates from $registry..."
  
  # Fetch latest release version
  local latest_version
  if ! latest_version=$(fetch_latest_release_version "$registry"); then
    exit 1
  fi
  
  echo "Latest version: $latest_version"
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
    old_version=$(jq -r --arg n "$agent_name" '.agents[$n] // "unknown"' "$lockfile")
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
    old_version=$(jq -r --arg n "$skill_name" '.skills[$n] // "unknown"' "$lockfile")
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
  
  # Rewrite lockfile with new version and updated item versions
  local new_agents_json="{}"
  while IFS= read -r agent_name; do
    local version
    version=$(jq -r --arg n "$agent_name" '.agents[$n].version // empty' "$SCRIPT_DIR/registry.json")
    if [[ -n "$version" ]]; then
      new_agents_json=$(jq -n --argjson base "$new_agents_json" --arg n "$agent_name" --arg v "$version" \
        '$base | .[$n] = $v')
    fi
  done < <(jq -r '.agents | keys[]' "$lockfile")
  
  local new_skills_json="{}"
  while IFS= read -r skill_name; do
    local version
    version=$(jq -r --arg n "$skill_name" '.skills[$n].version // empty' "$SCRIPT_DIR/registry.json")
    if [[ -n "$version" ]]; then
      new_skills_json=$(jq -n --argjson base "$new_skills_json" --arg n "$skill_name" --arg v "$version" \
        '$base | .[$n] = $v')
    fi
  done < <(jq -r '.skills | keys[]' "$lockfile")
  
  jq -n \
    --arg registry "$registry" \
    --arg version "$latest_version" \
    --argjson agents "$new_agents_json" \
    --argjson skills "$new_skills_json" \
    '{
      registry: $registry,
      version: $version,
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
  local manifest="$REPO_ROOT/.coding-crew.manifest.json"
  if [[ ! -f "$manifest" ]]; then
    echo "Error: no manifest found at $manifest — run ./install.sh first" >&2
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
  
  local registry version
  registry=$(jq -r '.registry // empty' "$lockfile")
  version=$(jq -r '.version // empty' "$lockfile")
  
  if [[ -z "$registry" || -z "$version" ]]; then
    echo "Error: lockfile must contain 'registry' and 'version' fields" >&2
    exit 1
  fi
  
  echo "Lockfile: $lockfile"
  echo "Registry: $registry"
  echo "Version: $version"
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
      lockfile_version=$(jq -r --arg n "$agent_name" '.agents[$n] // empty' "$lockfile")
      registry_version=$(jq -r --arg n "$agent_name" '.agents[$n].version // empty' "$SCRIPT_DIR/registry.json")
      
      if [[ -z "$registry_version" ]]; then
        echo "Warning: agent '$agent_name' not found in registry $version — skipping"
        continue
      fi
      
      if [[ "$lockfile_version" != "$registry_version" ]]; then
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
      lockfile_version=$(jq -r --arg n "$skill_name" '.skills[$n] // empty' "$lockfile")
      registry_version=$(jq -r --arg n "$skill_name" '.skills[$n].version // empty' "$SCRIPT_DIR/registry.json")
      
      if [[ -z "$registry_version" ]]; then
        echo "Warning: skill '$skill_name' not found in registry $version — skipping"
        continue
      fi
      
      if [[ "$lockfile_version" != "$registry_version" ]]; then
        echo "Warning: skill '$skill_name' version mismatch (lockfile: $lockfile_version, registry: $registry_version) — using registry version"
      fi
      
      install_single_skill "$skill_name"
    done < <(jq -r '.skills | keys[]' "$lockfile")
  fi
}

echo "Target: $REPO_ROOT ($INSTALL_LEVEL-level)"

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

echo "---"
write_manifest

echo "Done."
