#!/usr/bin/env bats

# Every platform in orchestrator/platforms.json, installed the same way: where its skills land,
# which body it gets, what uninstall removes, and that the installer learns a platform from that
# file alone (a fifth entry in a copy of it installs with no installer edit).

load helpers/platforms

setup() {
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  # A developer's own config-dir override must not move where a user-scope install lands.
  local p
  for p in "${PLATFORMS[@]}"; do
    unset "$(platform_field "$p" configDirEnv)"
    mkdir -p "$TEMP_DIR/$p"
  done
}

teardown() {
  chmod -R u+w "$TEMP_DIR" 2>/dev/null || true
  rm -rf "$TEMP_DIR"
}

@test "every platform is accepted and its skills land in its projectSkills dir, nowhere else" {
  cd "$SCRIPT_DIR"
  local p dir config
  for p in "${PLATFORMS[@]}"; do
    dir=$(platform_field "$p" projectSkills); config=$(platform_field "$p" configDir)
    run env TARGET_REPO="$TEMP_DIR/$p" ./install.sh "$p" --skill tdd
    [ "$status" -eq 0 ] || { echo "$p: $output" >&2; return 1; }
    [ -f "$TEMP_DIR/$p/$dir/tdd/SKILL.md" ] || { echo "$p: no $dir/tdd/SKILL.md" >&2; return 1; }
    # e.g. codex scans .agents/skills, never .codex/skills
    if [ "$config/skills" != "$dir" ]; then
      [ ! -d "$TEMP_DIR/$p/$config/skills" ] || { echo "$p: wrote $config/skills" >&2; return 1; }
    fi
  done
}

@test "an unknown platform is rejected, listing the platforms platforms.json names" {
  cd "$SCRIPT_DIR"
  run env TARGET_REPO="$TEMP_DIR" ./install.sh nonsense --skill tdd
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid platform 'nonsense'"* ]]
  local p
  for p in "${PLATFORMS[@]}"; do [[ "$output" == *"$p"* ]] || { echo "missing $p" >&2; return 1; }; done

  jq '. + {zed: {projectSkills: ".zed/skills", userSkills: ".zed/skills", configDir: ".zed", configDirEnv: "ZED_HOME"}}' \
    "$PLATFORMS_JSON" > "$TEMP_DIR/platforms.json"
  run env CODING_CREW_PLATFORMS_JSON="$TEMP_DIR/platforms.json" TARGET_REPO="$TEMP_DIR" ./install.sh nonsense --skill tdd
  [ "$status" -ne 0 ]
  [[ "$output" == *"zed"* ]]
}

@test "every platform's crew-afk SKILL.md launches that platform, with no per-platform body beside it" {
  cd "$SCRIPT_DIR"
  local p q dir
  for p in "${PLATFORMS[@]}"; do
    dir="$TEMP_DIR/$p/$(platform_field "$p" projectSkills)/crew-afk"
    TARGET_REPO="$TEMP_DIR/$p" ./install.sh "$p" --skill crew-afk >/dev/null
    grep -q "run --platform $p " "$dir/SKILL.md" || { echo "$p: {{PLATFORM}} not rendered" >&2; return 1; }
    for q in "${PLATFORMS[@]}"; do
      [ ! -f "$dir/$q.SKILL.md" ] || { echo "$p: $q.SKILL.md installed" >&2; return 1; }
    done
  done
}

@test "no platform's crew-afk body names another platform's skills dir, CLI call or a bash dispatcher" {
  cd "$SCRIPT_DIR"
  local p q body
  for p in "${PLATFORMS[@]}"; do
    TARGET_REPO="$TEMP_DIR/$p" ./install.sh "$p" --skill crew-afk >/dev/null
    body="$TEMP_DIR/$p/$(platform_field "$p" projectSkills)/crew-afk/SKILL.md"
    ! grep -n 'dispatch-agent\.sh\|dispatch-codex-agent\.sh' "$body" || return 1
    for q in "${PLATFORMS[@]}"; do
      [ "$q" != "$p" ] || continue
      ! grep -nF -e "$(platform_field "$q" projectSkills)/" -e "$q -p" "$body" || { echo "$p body names $q" >&2; return 1; }
    done
  done
}

@test "uninstall removes every platform's crew-afk, its assets and every retired agent file" {
  cd "$SCRIPT_DIR"
  local p dir
  for p in "${PLATFORMS[@]}"; do
    dir="$TEMP_DIR/$p/$(platform_field "$p" projectSkills)/crew-afk"
    TARGET_REPO="$TEMP_DIR/$p" ./install.sh "$p" --skill crew-afk >/dev/null
    [ -d "$dir" ]
    TARGET_REPO="$TEMP_DIR/$p" ./uninstall.sh --skill crew-afk >/dev/null
    [ ! -d "$dir" ] || { echo "$p: $dir survived" >&2; return 1; }
    [ ! -d "$TEMP_DIR/$p/.coding-crew/crew-afk" ] || { echo "$p: assets survived" >&2; return 1; }
    [ -z "$(find "$TEMP_DIR/$p" -name 'crew-coder*')" ] || { echo "$p: a crew-coder agent file exists" >&2; return 1; }
  done
}

@test "no platform's install ships a bash dispatcher, and a reinstall prunes one an older install left" {
  cd "$SCRIPT_DIR"
  local p scripts
  for p in "${PLATFORMS[@]}"; do
    scripts="$TEMP_DIR/$p/$(platform_field "$p" projectSkills)/crew-afk/scripts"
    TARGET_REPO="$TEMP_DIR/$p" ./install.sh "$p" --skill crew-afk >/dev/null
    [ ! -f "$scripts/dispatch-agent.sh" ] && [ ! -f "$scripts/dispatch-codex-agent.sh" ]
    touch "$scripts/dispatch-agent.sh" "$scripts/dispatch-codex-agent.sh"
    TARGET_REPO="$TEMP_DIR/$p" ./install.sh "$p" --skill crew-afk >/dev/null
    [ ! -f "$scripts/dispatch-agent.sh" ] && [ ! -f "$scripts/dispatch-codex-agent.sh" ] \
      || { echo "$p: stale dispatcher kept" >&2; return 1; }
  done
}

@test "every platform's adapter has its own co-author trailer, and codex's credits Codex" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  # squash-commits.sh writes whatever --co-author it is given (tests/squash-commits.bats);
  # the trailer itself is the adapter's.
  local p trailers=""
  cd "$SCRIPT_DIR"
  for p in "${PLATFORMS[@]}"; do
    trailers+="$(node -e 'import("./orchestrator/lib/adapters/index.mjs").then(({ ADAPTERS }) => console.log(ADAPTERS[process.argv[1]].coAuthor))' "$p")"$'\n'
  done
  [ "$(printf '%s' "$trailers" | grep -c '^Co-authored-by: ')" -eq "${#PLATFORMS[@]}" ]
  [ "$(printf '%s' "$trailers" | sort -u | grep -c .)" -eq "${#PLATFORMS[@]}" ]
  printf '%s' "$trailers" | grep -qx 'Co-authored-by: Codex <noreply@openai.com>'
}

# --- the installer learns a platform from platforms.json alone ---

_fifth_platform() {
  jq '. + {newp: {projectSkills: ".newp/skills", userSkills: ".newp/home/skills", configDir: ".newp/home", configDirEnv: "NEWP_HOME"}}' \
    "$PLATFORMS_JSON" > "$TEMP_DIR/platforms.json"
}

_assert_every_skill_in() {
  local dir="$1" skill
  while IFS= read -r skill; do
    [ -f "$dir/$skill/SKILL.md" ] || { echo "missing $dir/$skill/SKILL.md" >&2; return 1; }
  done < <(jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json" | tr -d '\r')
}

@test "a fifth platforms.json entry installs every skill to its projectSkills dir, and uninstall removes them" {
  _fifth_platform
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/repo"
  run env CODING_CREW_PLATFORMS_JSON="$TEMP_DIR/platforms.json" TARGET_REPO="$TEMP_DIR/repo" ./install.sh newp
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  _assert_every_skill_in "$TEMP_DIR/repo/.newp/skills"
  [ ! -d "$TEMP_DIR/repo/.newp/home" ]
  local p
  for p in "${PLATFORMS[@]}"; do [ ! -d "$TEMP_DIR/repo/$(platform_field "$p" projectSkills)" ]; done

  run env CODING_CREW_PLATFORMS_JSON="$TEMP_DIR/platforms.json" TARGET_REPO="$TEMP_DIR/repo" ./uninstall.sh
  [ "$status" -eq 0 ]
  [ ! -d "$TEMP_DIR/repo/.newp" ]
}

@test "a fifth platforms.json entry installs every skill to its userSkills dir, relocated by its configDirEnv" {
  _fifth_platform
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/home" "$TEMP_DIR/cfg"
  run env CODING_CREW_PLATFORMS_JSON="$TEMP_DIR/platforms.json" HOME="$TEMP_DIR/home" TARGET_REPO="$TEMP_DIR/home" ./install.sh newp
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  _assert_every_skill_in "$TEMP_DIR/home/.newp/home/skills"

  run env CODING_CREW_PLATFORMS_JSON="$TEMP_DIR/platforms.json" HOME="$TEMP_DIR/home" NEWP_HOME="$TEMP_DIR/cfg" \
    TARGET_REPO="$TEMP_DIR/home" ./install.sh newp
  [ "$status" -eq 0 ]
  _assert_every_skill_in "$TEMP_DIR/cfg/skills"
}

# --- uninstall sweeps only the legacy paths an earlier install wrote ---
# Earlier installs wrote <platform>'s resources under .<platform>/ at both scopes: Copilot's
# .copilot/ at project scope and pi's .pi/ at user scope are the only such dead copies. The
# other scope's dir is otherwise a live install of its own, which a scoped uninstall leaves be.

@test "a user uninstall leaves the project-scope .github/skills under \$HOME alone" {
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/home/.github/skills/tdd"
  echo "a repo's own skill" > "$TEMP_DIR/home/.github/skills/tdd/SKILL.md"
  run env HOME="$TEMP_DIR/home" TARGET_REPO="$TEMP_DIR/home" ./uninstall.sh --user --skill tdd
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -f "$TEMP_DIR/home/.github/skills/tdd/SKILL.md" ]
}

@test "a project uninstall leaves a repo's .pi/agent/skills alone" {
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/repo/.pi/agent/skills/tdd"
  echo "a repo's own skill" > "$TEMP_DIR/repo/.pi/agent/skills/tdd/SKILL.md"
  run env TARGET_REPO="$TEMP_DIR/repo" ./uninstall.sh --skill tdd
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ -f "$TEMP_DIR/repo/.pi/agent/skills/tdd/SKILL.md" ]
}

@test "a user uninstall still removes pi's legacy ~/.pi/skills copy" {
  cd "$SCRIPT_DIR"
  mkdir -p "$TEMP_DIR/home/.pi/skills/tdd" "$TEMP_DIR/home/.pi/agent/skills/tdd"
  echo stale > "$TEMP_DIR/home/.pi/skills/tdd/SKILL.md"
  echo current > "$TEMP_DIR/home/.pi/agent/skills/tdd/SKILL.md"
  run env HOME="$TEMP_DIR/home" TARGET_REPO="$TEMP_DIR/home" ./uninstall.sh --user --skill tdd
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  [ ! -d "$TEMP_DIR/home/.pi/skills/tdd" ]
  [ ! -d "$TEMP_DIR/home/.pi/agent/skills/tdd" ]
}

# --- bootstrap.sh leaves platform validation to install.sh ---

@test "bootstrap.sh hands any platform word to install.sh, which validates it" {
  local stub="$TEMP_DIR/stub" pkg="$TEMP_DIR/pkg/coding-crew-main"
  mkdir -p "$stub" "$pkg"
  printf '#!/bin/bash\necho "install.sh $*"\n' > "$pkg/install.sh"
  tar czf "$TEMP_DIR/main.tar.gz" -C "$TEMP_DIR/pkg" coding-crew-main
  printf '#!/bin/bash\ncat "%s"\n' "$TEMP_DIR/main.tar.gz" > "$stub/curl"
  chmod +x "$stub/curl"

  run env PATH="$stub:$PATH" HOME="$TEMP_DIR" bash "$SCRIPT_DIR/bootstrap.sh" nosuch
  [ "$status" -eq 0 ]
  [[ "$output" == *"install.sh nosuch"* ]]

  run env PATH="$stub:$PATH" HOME="$TEMP_DIR" bash "$SCRIPT_DIR/bootstrap.sh" --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown argument: --bogus"* ]]
}

# --- nothing per-platform is left outside platforms.json ---

@test "no registry.json skill entry has an install or install-<platform> key, and the installer reads none" {
  run jq -r '.skills | to_entries[] | .key as $k | .value | keys[] | select(test("^install(-.+)?$")) | "\($k).\(.)"' \
    "$SCRIPT_DIR/registry.json"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run grep -nE '\.install\b|"install-|install-\$|\]\.install' "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh" \
    "$SCRIPT_DIR/scripts/render-skill.sh" "$SCRIPT_DIR/scripts/lib/platforms.sh"
  [ "$status" -ne 0 ]
}

@test "install.sh and render-skill.sh read no per-platform body or platform-files" {
  run grep -nE '\.body\b|body\[|platform-files|PLATFORM\.SKILL\.md|platform\.SKILL\.md' \
    "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/scripts/render-skill.sh"
  [ "$status" -ne 0 ]
}

@test "install.sh and uninstall.sh name no platform outside their migrations" {
  local f names
  names=$(IFS='|'; echo "${PLATFORMS[*]}")
  for f in install.sh uninstall.sh; do
    # Migrations keep their platform: the legacy Copilot path and retired-agents removal.
    # Comments and echoed help text are prose, not decisions.
    run bash -c "awk '/^(prune_legacy_copilot_path|prune_retired_agents|remove_retired_agents)\\(\\)/{skip=1} skip&&/^}/{skip=0;next} !skip' '$SCRIPT_DIR/$f' \
      | grep -vE '^[[:space:]]*(#|echo )' \
      | grep -nE '(^|[^A-Za-z0-9_.-])($names)([^A-Za-z0-9_.-]|\$)'"
    [ "$status" -ne 0 ] || { echo "$f: $output" >&2; return 1; }
  done
}

@test "skill destinations resolve in one helper both installers source" {
  grep -q 'source "$SCRIPT_DIR/scripts/lib/platforms.sh"' "$SCRIPT_DIR/install.sh"
  grep -q 'source "$SCRIPT_DIR/scripts/lib/platforms.sh"' "$SCRIPT_DIR/uninstall.sh"
  run grep -nE '^(resolve_dest|resolve_skill_dest|platform_skills_dir|default_skill_dest|adjust_platform_path)\(\)' \
    "$SCRIPT_DIR/install.sh" "$SCRIPT_DIR/uninstall.sh"
  [ "$status" -ne 0 ]
}
