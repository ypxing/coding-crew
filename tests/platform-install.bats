#!/usr/bin/env bats

# Every platform in platforms.json, installed the same way: which body it gets, what
# uninstall removes, and that the installer learns a platform from that
# file alone (a fifth entry in a copy of it installs with no installer edit).

load helpers/platforms
load helpers/shared-install

# A developer's own config-dir override must not move where a user-scope install lands.
_unset_config_dirs() {
  local p
  for p in "${PLATFORMS[@]}"; do unset "$(platform_field "$p" configDirEnv)"; done
}

# One solve-feature install per platform, read by the tests below.
setup_file() {
  _unset_config_dirs
  local p
  for p in "${PLATFORMS[@]}"; do shared_install "$p" "$p" --skill solve-feature; done
  bg_wait
}

setup() {
  export TEMP_DIR=$(mktemp -d)
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  _unset_config_dirs
}

teardown() {
  chmod -R u+w "$TEMP_DIR" 2>/dev/null || true
  rm -rf "$TEMP_DIR"
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

@test "no platform's solve-feature body names another platform's skills dir, CLI call or a bash dispatcher" {
  cd "$SCRIPT_DIR"
  local p q body
  for p in "${PLATFORMS[@]}"; do
    body="$(shared_installed "$p")/$(platform_field "$p" projectSkills)/solve-feature/SKILL.md"
    ! grep -n 'dispatch-agent\.sh\|dispatch-codex-agent\.sh' "$body" || return 1
    for q in "${PLATFORMS[@]}"; do
      [ "$q" != "$p" ] || continue
      ! grep -nF -e "$(platform_field "$q" projectSkills)/" -e "$q -p" "$body" || { echo "$p body names $q" >&2; return 1; }
    done
  done
}

@test "uninstall removes every platform's solve-feature and copilot's legacy .copilot/ copy" {
  cd "$SCRIPT_DIR"
  local p dir
  for p in "${PLATFORMS[@]}"; do
    cp -R "$(shared_installed "$p")" "$TEMP_DIR/$p"
    dir="$TEMP_DIR/$p/$(platform_field "$p" projectSkills)/solve-feature"
    [ -d "$dir" ]
    # Copilot project installs once landed in .copilot/, which Copilot never reads at project scope.
    if [ "$p" = copilot ]; then
      mkdir -p "$TEMP_DIR/$p/.copilot/skills/solve-feature"
      echo "stale body" > "$TEMP_DIR/$p/.copilot/skills/solve-feature/SKILL.md"
    fi
    TARGET_REPO="$TEMP_DIR/$p" ./uninstall.sh --skill solve-feature >/dev/null
    [ ! -d "$dir" ] || { echo "$p: $dir survived" >&2; return 1; }
    [ ! -d "$TEMP_DIR/$p/.copilot" ] || { echo "$p: .copilot/ survived" >&2; return 1; }
  done
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
  done < <(jq -r '.skills | keys[]' "$SCRIPT_DIR/registry.json")
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
  run env -u TARGET_REPO HOME="$TEMP_DIR/home" ./uninstall.sh --skill tdd
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
  run env -u TARGET_REPO HOME="$TEMP_DIR/home" ./uninstall.sh --skill tdd
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

@test "install.sh --help works without jq, saying where the platform list lives" {
  local bin="$TEMP_DIR/nojq" c
  mkdir -p "$bin"
  for c in bash dirname git env cat tr; do ln -s "$(command -v "$c")" "$bin/$c"; done
  run env PATH="$bin" "$SCRIPT_DIR/install.sh" --help
  [[ "$output" == *"platform:   all (default), a platform in platforms.json"* ]] || { echo "$output" >&2; return 1; }
  [[ "$output" != *"required command"* ]]
}
