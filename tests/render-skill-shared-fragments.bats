#!/usr/bin/env bats

# scripts/render-skill.sh's shared fragments: a whole-line {{FRAGMENT:<key>}} expands to
# skills/_shared/fragments/<key>.md, so a fragment used by several skills (e.g. the "Tracker
# Configuration" preamble to-issues/to-prd/upgrade-deps/crew-address-findings all used to
# copy-paste independently) has exactly one source instead of one per skill.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
RENDER="$REPO_ROOT/scripts/render-skill.sh"
load helpers/platforms

# The probe skill lives in a per-test copy of the render tree (render-skill.sh resolves
# registry.json and skills/ from its own location), never under the real skills/: bats -j
# runs tests concurrently, and a shared fixture path there let one test's teardown delete
# another's fixture, and put a stray skill in front of every other test file rendering skills/.
# A skill absent from registry.json falls back to its own directory name as source-dir.
FIXTURE_NAME="__render_skill_fragment_probe__"

setup() {
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/scripts" "$TREE/skills/$FIXTURE_NAME"
  cp "$RENDER" "$TREE/scripts/render-skill.sh"
  cp "$REPO_ROOT/registry.json" "$TREE/registry.json"
  PROBE_RENDER="$TREE/scripts/render-skill.sh"
  FIXTURE_SKILL_DIR="$TREE/skills/$FIXTURE_NAME"
  SHARED_DIR="$TREE/skills/_shared/fragments"
  {
    echo "# Probe"
    echo ""
    echo "{{FRAGMENT:shared-only}}"
    echo ""
    echo "## Process"
  } > "$FIXTURE_SKILL_DIR/SKILL.md"
}

@test "a fragment under skills/_shared/fragments renders on every platform" {
  mkdir -p "$SHARED_DIR"
  echo "Shared content." > "$SHARED_DIR/shared-only.md"

  for p in "${PLATFORMS[@]}"; do
    run bash "$PROBE_RENDER" "$FIXTURE_NAME" "$p"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Shared content."* ]]
    [[ "$output" != *"{{FRAGMENT"* ]]
  done
}

@test "a missing fragment is a hard error" {
  run bash "$PROBE_RENDER" "$FIXTURE_NAME" claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"fragment"* ]]
}

# ─── the real shared fragments ───────────────────────────────────────────────────

@test "skills/_shared/fragments holds one file per fragment and no subdirectories" {
  [ -f "$REPO_ROOT/skills/_shared/fragments/tracker-configuration.md" ]
  run find "$REPO_ROOT/skills/_shared/fragments" -mindepth 1 -type d
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every tracker-touching skill's Tracker Configuration prose is byte-identical to the shared fragment" {
  # The skills reach the tracker only through the tracker CLI, and the fragment is the one
  # place that says how; a skill whose rendered section differed would be saying it twice.
  local expected
  expected=$(cat "$REPO_ROOT/skills/_shared/fragments/tracker-configuration.md")
  for skill in to-issues to-prd crew-address-findings upgrade-deps solve-issue; do
    run bash "$RENDER" "$skill" claude
    [ "$status" -eq 0 ]
    local actual
    # The fragment opens the section; a skill may add its own lines after it.
    actual=$(printf '%s\n' "$output" | awk '/^## Tracker Configuration$/{f=1} f' | head -n "$(wc -l < "$REPO_ROOT/skills/_shared/fragments/tracker-configuration.md")")
    [ "$actual" = "$expected" ] || {
      echo "$skill's rendered Tracker Configuration section changed:" >&2
      diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2
      return 1
    }
  done
}

@test "to-issues, to-prd, upgrade-deps and crew-address-findings all render the shared tracker-configuration fragment, for every platform" {
  for skill in to-issues to-prd upgrade-deps crew-address-findings; do
    for p in "${PLATFORMS[@]}"; do
      run bash "$RENDER" "$skill" "$p"
      [ "$status" -eq 0 ] || { echo "$skill/$p failed to render: $output" >&2; return 1; }
      [[ "$output" == *"## Tracker Configuration"* ]] || {
        echo "$skill/$p is missing the Tracker Configuration section" >&2; return 1; }
      [[ "$output" == *"issue-tracker.md"* ]] || {
        echo "$skill/$p is missing the issue-tracker.md reference" >&2; return 1; }
      [[ "$output" != *"{{FRAGMENT"* ]] || {
        echo "$skill/$p left an unexpanded fragment placeholder" >&2; return 1; }
    done
  done
}
