#!/usr/bin/env bats

# scripts/render-skill.sh's shared-fragments fallback: skills/_shared/fragments/<platform>/
# <key>.md is checked when a skill-local fragment of the same key is absent, so a fragment
# used by several skills (e.g. the "Tracker Configuration" preamble to-issues/to-prd/
# upgrade-deps/crew-address-findings all used to copy-paste independently) has exactly one
# source instead of one per skill. See .scratch/github-issue-tracker/issues/open/
# 08-skill-prose-github-support.md.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
RENDER="$REPO_ROOT/scripts/render-skill.sh"
PLATFORMS=(claude copilot pi codex)

# A skill absent from registry.json falls back to its own directory name as source-dir
# (`.skills[$s]["source-dir"] // $s`), so a throwaway fixture needs no registry.json edit —
# just a real (temporary) directory under the real skills/ tree, cleaned up per test.
FIXTURE_NAME="__render_skill_fragment_probe__"
FIXTURE_SKILL_DIR="$REPO_ROOT/skills/$FIXTURE_NAME"

setup() {
  mkdir -p "$FIXTURE_SKILL_DIR"
  {
    echo "# Probe"
    echo ""
    echo "{{FRAGMENT:shared-only}}"
    echo ""
    echo "## Process"
  } > "$FIXTURE_SKILL_DIR/SKILL.md"
}

teardown() {
  rm -rf "$FIXTURE_SKILL_DIR"
  rm -f "$REPO_ROOT/skills/_shared/fragments/claude/shared-only.md"
}

@test "a fragment absent locally but present under skills/_shared/fragments/<platform> renders" {
  mkdir -p "$REPO_ROOT/skills/_shared/fragments/claude"
  echo "Shared fallback content." > "$REPO_ROOT/skills/_shared/fragments/claude/shared-only.md"

  run bash "$RENDER" "$FIXTURE_NAME" claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"Shared fallback content."* ]]
  [[ "$output" != *"{{FRAGMENT"* ]]
}

@test "a skill-local fragment of the same key wins over the shared fallback" {
  mkdir -p "$FIXTURE_SKILL_DIR/fragments/claude"
  echo "Skill-local content." > "$FIXTURE_SKILL_DIR/fragments/claude/shared-only.md"
  mkdir -p "$REPO_ROOT/skills/_shared/fragments/claude"
  echo "Shared fallback content." > "$REPO_ROOT/skills/_shared/fragments/claude/shared-only.md"

  run bash "$RENDER" "$FIXTURE_NAME" claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skill-local content."* ]]
  [[ "$output" != *"Shared fallback content."* ]]
}

@test "missing from both skill-local and shared fallback is still a hard error" {
  run bash "$RENDER" "$FIXTURE_NAME" claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"fragment"* ]]
}

# ─── the real shared fragment this issue adds ──────────────────────────────────

@test "skills/_shared/fragments/<platform>/tracker-configuration.md exists for every platform" {
  for p in "${PLATFORMS[@]}"; do
    [ -f "$REPO_ROOT/skills/_shared/fragments/$p/tracker-configuration.md" ] || {
      echo "missing skills/_shared/fragments/$p/tracker-configuration.md" >&2; return 1; }
  done
}

@test "to-issues, to-prd and crew-address-findings's Tracker Configuration prose is byte-identical to before the fragment consolidation" {
  # These three skills copy-pasted the exact same preamble (unlike upgrade-deps, whose
  # wording drifted — see .scratch/github-issue-tracker/issues/open/
  # 08-skill-prose-github-support.md), so switching them to {{FRAGMENT:tracker-configuration}}
  # must not change one byte of what a consuming repo receives.
  local expected
  expected=$(cat <<'EOF'
## Tracker Configuration

Before any tracker operation, locate `issue-tracker.md` using this lookup chain:

1. `$(git rev-parse --show-toplevel)/.coding-crew/docs/issue-tracker.md` (project-level)

If it does not exist, invoke the `configure-tracker` skill now to set it up, then continue.

All tracker operations in this skill use the operation definitions in that file.
EOF
)
  for skill in to-issues to-prd crew-address-findings; do
    run bash "$RENDER" "$skill" claude
    [ "$status" -eq 0 ]
    local actual
    actual=$(printf '%s\n' "$output" | awk '/^## Tracker Configuration$/{f=1} f{print} /^All tracker operations in this skill use the operation definitions in that file\.$/{if(f)exit}')
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
