#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${TARGET_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

UPDATE_MODE=false
if [[ "${1:-}" == "--update" ]]; then
  UPDATE_MODE=true
  PLATFORM="all"
  AGENT="all"
else
  PLATFORM="${1:-all}"    # all | claude | copilot
  AGENT="${2:-all}"       # all | afk-sprint | coder | --skill <name>
fi

INSTALLED=""
MANIFEST_AGENT_ENTRIES=()  # each entry: "name version platform"
MANIFEST_SKILL_ENTRIES=()  # each entry: "name version"

usage() {
  echo "Usage: ./install.sh [platform] [agent]"
  echo "       ./install.sh [platform] --skill <skill-name>"
  echo "       ./install.sh [platform] --doc <doc-name>"
  echo "       ./install.sh --update"
  echo ""
  echo "  platform: all (default), claude, copilot"
  echo "  agent:    all (default), code-reviewer, coder"
  echo "  --skill:  install a standalone skill (e.g. to-issues, grill-me)"
  echo "  --doc:    install a standalone doc (e.g. issue-tracker.md)"
  echo "  --update: re-install only agents/skills whose version changed since last install"
  echo ""
  echo "Examples:"
  echo "  ./install.sh                        # install everything"
  echo "  ./install.sh claude --skill afk-sprint   # afk-sprint skill + coder + code-reviewer"
  echo "  ./install.sh copilot --skill afk-sprint  # afk-sprint (copilot variant) + agents"
  echo "  ./install.sh claude --skill to-issues  # install just the to-issues skill"
  echo "  ./install.sh claude --doc issue-tracker.md   # install just the issue-tracker doc"
  echo "  ./install.sh --update               # update all installed agents/skills"
  echo ""
  echo "Available skills:"
  echo "  $(jq -r '.skills | keys | join(", ")' "$SCRIPT_DIR/registry.json")"
  echo ""
  echo "Available docs:"
  echo "  $(jq -r '.docs | keys | join(", ")' "$SCRIPT_DIR/registry.json")"
  echo ""
  echo "Set TARGET_REPO to install into a different repo root."
  exit 1
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
fi

# ── Dependency checks ──────────────────────────────────────────────────────────
for cmd in jq git; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Error: required command '$cmd' not found" >&2; exit 1; }
done

# ── Input validation ───────────────────────────────────────────────────────────
if [[ "$UPDATE_MODE" == "false" ]]; then
  if [[ "${1:-}" == "--skill" || "${1:-}" == "--doc" ]]; then
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

install_docs() {
  local agent_name="$1"
  local docs
  docs=$(jq -r --arg name "$agent_name" '.agents[$name].docs // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)

  mkdir -p "$REPO_ROOT/docs/agents"
  local docs_arr=()
  while IFS= read -r _line; do [[ -n "$_line" ]] && docs_arr+=("$_line"); done <<< "$docs"
  for doc in "${docs_arr[@]+"${docs_arr[@]}"}"; do
    assert_identifier "$doc" "doc"
    [[ -f "$SCRIPT_DIR/docs/agents/$doc" ]] || { echo "Error: doc source not found: docs/agents/$doc" >&2; exit 1; }
    if [[ ! -f "$REPO_ROOT/docs/agents/$doc" ]]; then
      cp "$SCRIPT_DIR/docs/agents/$doc" "$REPO_ROOT/docs/agents/$doc"
      echo "  docs/agents/$doc"
    else
      echo "  docs/agents/$doc (skipped — already exists)"
    fi
  done
}

install_skills() {
  local agent_name="$1"
  local skills
  skills=$(jq -r --arg name "$agent_name" '.agents[$name].skills // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)

  local skills_arr=()
  while IFS= read -r _line; do [[ -n "$_line" ]] && skills_arr+=("$_line"); done <<< "$skills"
  for skill in "${skills_arr[@]+"${skills_arr[@]}"}"; do
    if [[ "$INSTALLED" == *"|skill:$skill|"* ]]; then
      continue
    fi
    INSTALLED="${INSTALLED}|skill:$skill|"

    assert_identifier "$skill" "skill"
    local skill_dest
    skill_dest=$(jq -r --arg s "$skill" '.skills[$s].install' "$SCRIPT_DIR/registry.json")
    assert_safe_path "$skill_dest" "skill install"
    [[ -d "$SCRIPT_DIR/skills/$skill" ]] || { echo "Error: skill source not found: skills/$skill" >&2; exit 1; }
    mkdir -p "$REPO_ROOT/$skill_dest"
    cp -r "$SCRIPT_DIR/skills/$skill/." "$REPO_ROOT/$skill_dest/"
    echo "  $skill_dest/"

    local skill_version
    skill_version=$(jq -r --arg s "$skill" '.skills[$s].version // "unknown"' "$SCRIPT_DIR/registry.json")
    MANIFEST_SKILL_ENTRIES+=("$skill $skill_version")
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
  install_docs "$agent_name"

  # Locate protocol source for {{PROTOCOL}} expansion (protocol.md tried first, then workflow.js)
  local protocol_file=""
  for candidate in "$SCRIPT_DIR/agents/$agent_name/protocol.md" "$SCRIPT_DIR/agents/$agent_name/workflow.js"; do
    if [[ -f "$candidate" ]]; then protocol_file="$candidate"; break; fi
  done

  expand_shim() {
    local src="$1" dest="$2"
    if grep -q '{{PROTOCOL}}' "$src" && [[ -z "$protocol_file" ]]; then
      echo "Error: $src contains {{PROTOCOL}} but no protocol.md or workflow.js found for $agent_name" >&2
      exit 1
    fi
    mkdir -p "$(dirname "$dest")"
    if grep -q '{{PROTOCOL}}' "$src"; then
      {
        while IFS= read -r line; do
          if [[ "$line" == *'{{PROTOCOL}}'* ]]; then
            cat "$protocol_file"
          else
            printf '%s\n' "$line"
          fi
        done < "$src"
      } > "$dest" || { rm -f "$dest"; exit 1; }
    else
      cp "$src" "$dest" || { rm -f "$dest"; exit 1; }
    fi
  }

  if [[ "$platform" == "claude" || "$platform" == "all" ]]; then
    local claude_dest claude_src
    claude_dest=$(jq -r --arg name "$agent_name" '.agents[$name].install.shims.claude // empty' "$SCRIPT_DIR/registry.json")
    local claude_count
    claude_count=$(find "$SCRIPT_DIR/agents/$agent_name" -maxdepth 1 -name "claude.*" | wc -l)
    if [[ "$claude_count" -gt 1 ]]; then
      echo "Error: multiple claude.* files in $SCRIPT_DIR/agents/$agent_name — cannot determine which to install" >&2
      exit 1
    fi
    claude_src=$(find "$SCRIPT_DIR/agents/$agent_name" -maxdepth 1 -name "claude.*" | head -1)
    if [[ -n "$claude_src" && -n "$claude_dest" ]]; then
      assert_safe_path "$claude_dest" "claude install"
      expand_shim "$claude_src" "$REPO_ROOT/$claude_dest"
      echo "  $claude_dest"
    fi
  fi

  if [[ "$platform" == "copilot" || "$platform" == "all" ]]; then
    local copilot_dest copilot_src
    copilot_dest=$(jq -r --arg name "$agent_name" '.agents[$name].install.shims.copilot // empty' "$SCRIPT_DIR/registry.json")
    local copilot_count
    copilot_count=$(find "$SCRIPT_DIR/agents/$agent_name" -maxdepth 1 -name "copilot.*" | wc -l)
    if [[ "$copilot_count" -gt 1 ]]; then
      echo "Error: multiple copilot.* files in $SCRIPT_DIR/agents/$agent_name — cannot determine which to install" >&2
      exit 1
    fi
    copilot_src=$(find "$SCRIPT_DIR/agents/$agent_name" -maxdepth 1 -name "copilot.*" | head -1)
    if [[ -n "$copilot_src" && -n "$copilot_dest" ]]; then
      assert_safe_path "$copilot_dest" "copilot install"
      expand_shim "$copilot_src" "$REPO_ROOT/$copilot_dest"
      echo "  $copilot_dest"
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
  while IFS= read -r _line; do [[ -n "$_line" ]] && deps_arr+=("$_line"); done <<< "$deps"
  for dep in "${deps_arr[@]+"${deps_arr[@]}"}"; do
    install_agent "$dep" "$platform"
  done
}

install_single_skill() {
  local skill_name="$1"
  assert_identifier "$skill_name" "skill"

  # Dedup — skip if already installed in this session
  if [[ "$INSTALLED" == *"|skill:$skill_name|"* ]]; then
    return
  fi
  INSTALLED="${INSTALLED}|skill:$skill_name|"

  local skill_dest skill_src_primary skill_src_remove
  if [[ "$PLATFORM" == "copilot" ]]; then
    skill_dest=$(jq -r --arg s "$skill_name" '.skills[$s]["install-copilot"] // .skills[$s].install // empty' "$SCRIPT_DIR/registry.json")
    skill_src_primary="copilot.SKILL.md"
    skill_src_remove="SKILL.md"
  else
    skill_dest=$(jq -r --arg s "$skill_name" '.skills[$s].install // empty' "$SCRIPT_DIR/registry.json")
    skill_src_primary="SKILL.md"
    skill_src_remove="copilot.SKILL.md"
  fi
  if [[ -z "$skill_dest" ]]; then
    echo "Error: skill '$skill_name' not found in registry.json"
    echo "Available skills: $(jq -r '.skills | keys | join(", ")' "$SCRIPT_DIR/registry.json")"
    exit 1
  fi
  assert_safe_path "$skill_dest" "skill install"
  [[ -d "$SCRIPT_DIR/skills/$skill_name" ]] || { echo "Error: skill source not found: skills/$skill_name" >&2; exit 1; }
  mkdir -p "$REPO_ROOT/$skill_dest"
  cp -r "$SCRIPT_DIR/skills/$skill_name/." "$REPO_ROOT/$skill_dest/"
  # Remove the other platform's primary file; rename the active one to SKILL.md
  rm -f "$REPO_ROOT/$skill_dest/$skill_src_remove"
  if [[ "$skill_src_primary" != "SKILL.md" && -f "$REPO_ROOT/$skill_dest/$skill_src_primary" ]]; then
    mv "$REPO_ROOT/$skill_dest/$skill_src_primary" "$REPO_ROOT/$skill_dest/SKILL.md"
  fi
  echo "  $skill_dest/"

  local skill_version
  skill_version=$(jq -r --arg s "$skill_name" '.skills[$s].version // "unknown"' "$SCRIPT_DIR/registry.json")
  MANIFEST_SKILL_ENTRIES+=("$skill_name $skill_version")

  # Resolve skill-level deps declared in registry.json
  local deps
  deps=$(jq -r --arg s "$skill_name" '.skills[$s].deps // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  local deps_arr=()
  while IFS= read -r _line; do [[ -n "$_line" ]] && deps_arr+=("$_line"); done <<< "$deps"
  for dep in "${deps_arr[@]+"${deps_arr[@]}"}"; do
    install_single_skill "$dep"
  done

  # Resolve agent-deps — agents this skill requires at runtime
  local agent_deps
  agent_deps=$(jq -r --arg s "$skill_name" '.skills[$s]["agent-deps"] // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  local agent_deps_arr=()
  while IFS= read -r _line; do [[ -n "$_line" ]] && agent_deps_arr+=("$_line"); done <<< "$agent_deps"
  for dep in "${agent_deps_arr[@]+"${agent_deps_arr[@]}"}"; do
    install_agent "$dep" "$PLATFORM"
  done

  # Install docs declared on the skill
  local skill_docs
  skill_docs=$(jq -r --arg s "$skill_name" '.skills[$s].docs // [] | .[]' "$SCRIPT_DIR/registry.json" 2>/dev/null || true)
  local skill_docs_arr=()
  while IFS= read -r _line; do [[ -n "$_line" ]] && skill_docs_arr+=("$_line"); done <<< "$skill_docs"
  if [[ "${#skill_docs_arr[@]}" -gt 0 ]]; then
    mkdir -p "$REPO_ROOT/docs/agents"
    for doc in "${skill_docs_arr[@]}"; do
      assert_identifier "$doc" "doc"
      [[ -f "$SCRIPT_DIR/docs/agents/$doc" ]] || { echo "Error: doc source not found: docs/agents/$doc" >&2; exit 1; }
      if [[ ! -f "$REPO_ROOT/docs/agents/$doc" ]]; then
        cp "$SCRIPT_DIR/docs/agents/$doc" "$REPO_ROOT/docs/agents/$doc"
        echo "  docs/agents/$doc"
      else
        echo "  docs/agents/$doc (skipped — already exists)"
      fi
    done
  fi
}

install_single_doc() {
  local doc_name="$1"
  assert_identifier "$doc_name" "doc"
  local doc_dest
  doc_dest=$(jq -r --arg d "$doc_name" '.docs[$d].install // empty' "$SCRIPT_DIR/registry.json")
  if [[ -z "$doc_dest" ]]; then
    echo "Error: doc '$doc_name' not found in registry.json"
    echo "Available docs: $(jq -r '.docs | keys | join(", ")' "$SCRIPT_DIR/registry.json")"
    exit 1
  fi
  assert_safe_path "$doc_dest" "doc install"
  [[ -f "$SCRIPT_DIR/docs/agents/$doc_name" ]] || { echo "Error: doc source not found: docs/agents/$doc_name" >&2; exit 1; }
  mkdir -p "$(dirname "$REPO_ROOT/$doc_dest")"
  cp "$SCRIPT_DIR/docs/agents/$doc_name" "$REPO_ROOT/$doc_dest"
  echo "  $doc_dest"
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

run_update() {
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

echo "Target: $REPO_ROOT"

if [[ "$UPDATE_MODE" == "true" ]]; then
  run_update
  if [[ "${#MANIFEST_AGENT_ENTRIES[@]}" -gt 0 || "${#MANIFEST_SKILL_ENTRIES[@]}" -gt 0 ]]; then
    write_manifest
  fi
  echo "Done."
  exit 0
fi

echo "Platform: $PLATFORM"

if [[ "$AGENT" == "--skill" ]]; then
  SKILL_NAME="${3:-}"
  if [[ -z "$SKILL_NAME" ]]; then
    echo "Error: --skill requires a skill name"
    usage
  fi
  echo "Skill: $SKILL_NAME"
  echo "---"
  install_single_skill "$SKILL_NAME"
elif [[ "$AGENT" == "--doc" ]]; then
  DOC_NAME="${3:-}"
  if [[ -z "$DOC_NAME" ]]; then
    echo "Error: --doc requires a doc name"
    usage
  fi
  echo "Doc: $DOC_NAME"
  echo "---"
  install_single_doc "$DOC_NAME"
  echo "---"
  echo "Done."
  exit 0
elif [[ "$AGENT" == "all" ]]; then
  echo "Agent: $AGENT"
  echo "---"
  agent_names=()
  while IFS= read -r _line; do [[ -n "$_line" ]] && agent_names+=("$_line"); done < <(jq -r '.agents | keys[]' "$SCRIPT_DIR/registry.json")
  for agent_name in "${agent_names[@]}"; do
    install_agent "$agent_name" "$PLATFORM"
  done
  # Install all standalone skills — not just those wired to agents as deps
  skill_names=()
  while IFS= read -r _line; do [[ -n "$_line" ]] && skill_names+=("$_line"); done < <(jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json")
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
