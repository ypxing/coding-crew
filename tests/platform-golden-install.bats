#!/usr/bin/env bats
# platform-golden-install.bats — today's per-platform install tree, frozen.
#
# For each platform in orchestrator/platforms.json, a full `install.sh <platform>` at project
# scope, at user scope (TARGET_REPO=$HOME, a temp $HOME), and at user scope with the platform's
# configDirEnv pointing at a temp dir; then `uninstall.sh` in the same target. Each tree is
# recorded as one sorted line per entry — `<ROOT>/<relative path> <fact>` (`/` for a directory) —
# and compared against tests/fixtures/platform-golden/install/<platform>-<scope>.
# {install,uninstall}.txt. A refactor of install/uninstall must leave them unchanged; a deliberate
# change regenerates them with `UPDATE_GOLDEN=1 bats tests/platform-golden-install.bats`.
#
# A file's fact is not its content hash: that would rewrite every fixture on any edit to any shipped
# file. It is the executable bit, plus for a SKILL.md (the rendered file) the count of `{{` placeholders
# left in it, so a changed path, scope, executable bit or a broken render still fails; the manifest,
# which is structural, keeps its hash.
#
# Roots are written as REPO, HOME and CONFIG, and the manifest's per-run fields (installed_at,
# source, source_sha) are dropped before hashing, so a fixture holds no machine-specific value.
# Each manifest skill version is read as the one it had when the fixtures were recorded
# (manifest-versions.json): a version bump is registry data, not a change to what installs where,
# and must not churn every fixture.

load helpers/isolate-env

setup() {
  isolate_project_env
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GOLDEN="$REPO/tests/fixtures/platform-golden/install"
  WORK="$(cd "$(mktemp -d)" && pwd -P)"
  mkdir -p "$WORK/repo" "$WORK/home" "$WORK/config"
  # A developer's own config-dir override must not move what this records.
  local v
  while IFS= read -r v; do unset "$v"; done < <(jq -r '.[].configDirEnv' "$REPO/orchestrator/platforms.json")
}

teardown() {
  chmod -R u+w "$WORK" 2>/dev/null || true
  rm -rf "$WORK"
}

# _tree <label> <dir> — one line per entry under <dir>, sorted.
_tree() {
  local label="$1" dir="$2" rel path
  (
    cd "$dir" || exit 1
    find . -mindepth 1 -type d | LC_ALL=C sort | while IFS= read -r rel; do
      printf '%s/%s/ /\n' "$label" "${rel#./}"
    done
    find . -mindepth 1 \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r rel; do
      path="${rel#./}"
      if [[ "$(basename "$path")" == manifest.json ]]; then
        printf '%s/%s %s\n' "$label" "$path" \
          "$(jq -S --slurpfile v "$GOLDEN/manifest-versions.json" '
              del(.installed_at, .source, .source_sha)
              | .skills |= with_entries(.value.version = ($v[0][.key] // .value.version))' "$path" \
            | git hash-object --stdin)"
      else
        local fact="exec=$([[ -x "$path" ]] && echo 1 || echo 0)"
        [[ "$(basename "$path")" == SKILL.md ]] && fact+=" unrendered=$(LC_ALL=C grep -c '{{' "$path" || true)"
        printf '%s/%s %s\n' "$label" "$path" "$fact"
      fi
    done
  ) | LC_ALL=C sort
}

# _snapshot <scope> — the trees this scope can write to.
_snapshot() {
  case "$1" in
    project) _tree REPO "$WORK/repo"; _tree HOME "$WORK/home" ;;
    user) _tree HOME "$WORK/home" ;;
    user-config) _tree HOME "$WORK/home"; _tree CONFIG "$WORK/config" ;;
  esac
}

# _compare <platform> <scope> <phase> <actual-file>
_compare() {
  local platform="$1" scope="$2" phase="$3" actual="$4"
  local fixture="$GOLDEN/$platform-$scope.$phase.txt"
  if grep -q "$WORK" "$actual"; then
    echo "install golden: platform $platform, scope $scope ($phase) recorded a temp path" >&2
    return 1
  fi
  if [[ "${UPDATE_GOLDEN:-}" == 1 ]]; then
    mkdir -p "$GOLDEN"
    cp "$actual" "$fixture"
    return 0
  fi
  if [[ ! -f "$fixture" ]]; then
    echo "install golden missing for platform $platform, scope $scope ($phase): $fixture (run with UPDATE_GOLDEN=1)" >&2
    return 1
  fi
  if ! diff -u "$fixture" "$actual" >&2; then
    echo "install golden changed for platform $platform, scope $scope ($phase) (UPDATE_GOLDEN=1 to accept)" >&2
    return 1
  fi
}

# golden_install <platform> <scope> — install, snapshot, uninstall, snapshot.
golden_install() {
  local platform="$1" scope="$2" target env_name
  env_name=$(jq -r --arg p "$platform" '.[$p].configDirEnv' "$REPO/orchestrator/platforms.json")
  local -a env=(HOME="$WORK/home")
  case "$scope" in
    project) target="$WORK/repo" ;;
    user) target="$WORK/home" ;;
    user-config) target="$WORK/home"; env+=("$env_name=$WORK/config") ;;
  esac
  cd "$REPO"
  run env "${env[@]}" TARGET_REPO="$target" ./install.sh "$platform"
  [ "$status" -eq 0 ] || { echo "install.sh $platform ($scope) failed: $output" >&2; return 1; }
  _snapshot "$scope" > "$WORK/install.txt"
  _compare "$platform" "$scope" install "$WORK/install.txt"

  run env "${env[@]}" TARGET_REPO="$target" ./uninstall.sh
  [ "$status" -eq 0 ] || { echo "uninstall.sh after $platform ($scope) failed: $output" >&2; return 1; }
  _snapshot "$scope" > "$WORK/uninstall.txt"
  _compare "$platform" "$scope" uninstall "$WORK/uninstall.txt"
}

@test "install.sh's platforms are platforms.json's, and the cases below cover them all" {
  local want got
  want=$(SCRIPT_DIR="$REPO" REPO_ROOT="$WORK/repo" bash -c 'source "$SCRIPT_DIR/scripts/lib/platforms.sh"; printf "%s\n" "${PLATFORMS[@]}"' | LC_ALL=C sort)
  got=$(jq -r 'keys[]' "$REPO/orchestrator/platforms.json" | LC_ALL=C sort)
  [ "$want" = "$got" ]
  [ "$got" = "$(printf '%s\n' claude codex copilot pi)" ]
}

@test "install golden: claude, project" { golden_install claude project; }
@test "install golden: claude, user" { golden_install claude user; }
@test "install golden: claude, user + CLAUDE_CONFIG_DIR" { golden_install claude user-config; }
@test "install golden: copilot, project" { golden_install copilot project; }
@test "install golden: copilot, user" { golden_install copilot user; }
@test "install golden: copilot, user + COPILOT_HOME" { golden_install copilot user-config; }
@test "install golden: pi, project" { golden_install pi project; }
@test "install golden: pi, user" { golden_install pi user; }
@test "install golden: pi, user + PI_CODING_AGENT_DIR" { golden_install pi user-config; }
@test "install golden: codex, project" { golden_install codex project; }
@test "install golden: codex, user" { golden_install codex user; }
@test "install golden: codex, user + CODEX_HOME" { golden_install codex user-config; }
