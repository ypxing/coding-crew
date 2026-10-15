#!/usr/bin/env bats

# The setup-coding-crew skill: what install.sh ships for it, and the one piece of its SKILL.md that is
# code rather than prose, the commit hint.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  TEMP_DIR="$(mktemp -d)"
}
teardown() { rm -rf "$TEMP_DIR"; }

@test "install.sh claude --skill setup-coding-crew ships SKILL.md, the Actions template, both discovery scripts and configure-tracker" {
  local target="$TEMP_DIR/target" skill
  mkdir -p "$target" && git -C "$target" init -q -b main
  run env TARGET_REPO="$target" bash "$REPO_ROOT/install.sh" claude --skill setup-coding-crew
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  skill="$target/.claude/skills/setup-coding-crew"
  [ -f "$skill/SKILL.md" ]
  [ -f "$skill/hosts/github-actions.yml" ]
  [ -f "$skill/scripts/checks/discover-commands.sh" ]
  [ -f "$skill/scripts/checks/write-commands-cache.sh" ]
  [ -f "$skill/scripts/tracker/cli.mjs" ]
  [ -f "$target/.claude/skills/configure-tracker/SKILL.md" ]
  [ "$(jq -c '.skills["setup-coding-crew"].deps' "$REPO_ROOT/registry.json")" = '["configure-tracker"]' ]
}

# step4 — the bash block under SKILL.md's "## Step 4" heading, the commit hint the skill prints.
step4() {
  awk '/^## Step 4/ { s = 1; next } /^## / { s = 0 } s && /^```bash/ { c = 1; next } s && c && /^```/ { exit } c' \
    "$REPO_ROOT/skills/setup-coding-crew/SKILL.md"
}

@test "the commit hint lists each setup file git shows as changed or untracked, and says when all are committed" {
  local repo="$TEMP_DIR/repo"
  step4 > "$TEMP_DIR/hint.sh"
  [ -s "$TEMP_DIR/hint.sh" ]
  mkdir -p "$repo" && cd "$repo" && git init -q -b main
  git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  mkdir -p .coding-crew .github/workflows
  echo '{"tracker": {"kind": "github"}}' > .coding-crew/config.json
  echo '{"test": "make test"}' > .coding-crew/dev-commands.json
  echo 'name: other' > .github/workflows/other.yml
  git add .coding-crew/dev-commands.json && git -c user.name=t -c user.email=t@t commit -q -m cmds
  echo '{"test": "make check"}' > .coding-crew/dev-commands.json

  run bash "$TEMP_DIR/hint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'git add .coding-crew/config.json .coding-crew/dev-commands.json && git commit -m "Set up coding-crew"'* ]]
  [[ "$output" != *other.yml* ]]

  git add .coding-crew && git -c user.name=t -c user.email=t@t commit -q -m setup
  run bash "$TEMP_DIR/hint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"git add"* ]]
  [[ "$output" == *"committed"* ]]
}

@test "the skill runs no git commit or git push itself, says so, and reaches configure-tracker only by name" {
  local skill="$REPO_ROOT/skills/setup-coding-crew/SKILL.md"
  # A command block may print a git commit line, never run one.
  ! awk '/^ *```bash/ { c = 1; next } /^ *```/ { c = 0 } c' "$skill" | grep -E 'git (commit|push)' | grep -v 'echo ' || false
  grep -qF 'does not commit or push' "$skill"
  grep -qF 'Use the configure-tracker skill' "$skill"
  ! grep -n 'configure-tracker/' "$skill" || false
}
