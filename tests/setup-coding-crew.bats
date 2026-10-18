#!/usr/bin/env bats

# The setup-coding-crew skill: what install.sh ships for it, and the pieces of its SKILL.md that are code rather
# than prose: Step 2's start of the dev commands file and Step 4's commit hint.

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
  [ -f "$skill/scripts/checks/run-checks.sh" ]
  [ -f "$target/.claude/skills/dep-install/SKILL.md" ]
  [ -f "$skill/scripts/tracker/cli.mjs" ]
  [ -f "$target/.claude/skills/configure-tracker/SKILL.md" ]
  [ "$(jq -c '.skills["setup-coding-crew"].deps' "$REPO_ROOT/registry.json")" = '["configure-tracker","dep-install"]' ]
}

# block <n> — the first bash block under SKILL.md's "## Step <n>" heading, <skill-dir> pointing at the source skill.
block() {
  awk -v h="^## Step $1" '$0 ~ h { s = 1; next } /^## / { s = 0 } s && /^```bash/ { c = 1; next } s && c && /^```/ { exit } c' \
    "$REPO_ROOT/skills/setup-coding-crew/SKILL.md" | sed "s#<skill-dir>#$REPO_ROOT/skills/setup-coding-crew#g"
}
# step4 — Step 4's block, START (the tree setup started in) the directory it runs in unless the test sets it.
step4() { block 4 | sed 's#^START="<[^>]*>"#START="${START:-$(git rev-parse --show-toplevel)}"#'; }

# repo_with_worktree — $REPO, a main checkout with one commit, and $WT, a linked worktree of it.
repo_with_worktree() {
  REPO="$TEMP_DIR/repo" WT="$TEMP_DIR/wt"
  git init -q -b main "$REPO"
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$REPO" worktree add -q --detach "$WT"
}

@test "Step 2 moves the clone's old .git/coding-crew/ file to the main checkout's file, from a linked worktree too" {
  repo_with_worktree
  block 2 > "$TEMP_DIR/step2.sh"
  grep -q 'commands-file.sh' "$TEMP_DIR/step2.sh"
  mkdir -p "$REPO/.git/coding-crew"
  echo '{"test": "make test", "install_mode": "host"}' > "$REPO/.git/coding-crew/dev-commands.json"
  (cd "$WT" && bash "$TEMP_DIR/step2.sh") >/dev/null
  [ ! -e "$REPO/.git/coding-crew/dev-commands.json" ]
  grep -q '"test": "make test"' "$REPO/.coding-crew/dev-commands.json"
  [ ! -e "$WT/.coding-crew" ]

  # An existing project file is kept; with no old file either, it starts empty.
  echo '{"test": "make check"}' > "$REPO/.coding-crew/dev-commands.json"
  echo '{"test": "old"}' > "$REPO/.git/coding-crew/dev-commands.json"
  (cd "$REPO" && bash "$TEMP_DIR/step2.sh") >/dev/null
  grep -q '"test": "make check"' "$REPO/.coding-crew/dev-commands.json"
  rm -rf "$REPO/.coding-crew" "$REPO/.git/coding-crew"
  (cd "$REPO" && bash "$TEMP_DIR/step2.sh") >/dev/null
  [ -f "$REPO/.coding-crew/dev-commands.json" ]
}

@test "setup verifies the commands: dep-install by name, then run-checks.sh, offering fix, keep or stop on a failure" {
  local skill="$REPO_ROOT/skills/setup-coding-crew/SKILL.md"
  grep -qF 'Use the dep-install skill' "$skill"
  grep -qF 'scripts/checks/run-checks.sh' "$skill"
  grep -qF 'CHECKS: fail' "$skill"
  grep -qF '**fix**' "$skill" && grep -qF '**keep**' "$skill" && grep -qF '**stop**' "$skill"
  ! grep -n 'dep-install/' "$skill" || false
  ! grep -nE 'Never run the commands|This step does not decide it|solve-feature needs these files committed|the tracked `.coding-crew' "$skill" || false
}

@test "the commit hint for a setup started in a linked worktree lists the main checkout's files, with a cd there" {
  repo_with_worktree
  step4 > "$TEMP_DIR/hint.sh"
  mkdir -p "$REPO/.coding-crew"
  echo '{"test": "make test"}' > "$REPO/.coding-crew/dev-commands.json"
  # Setup runs every command from the main checkout; only START remembers the worktree it was started in.
  run bash -c 'cd "$1" && START="$2" bash "$3"' _ "$REPO" "$WT" "$TEMP_DIR/hint.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd $REPO && git add .coding-crew/dev-commands.json && git commit"* ]] || { echo "$output"; return 1; }
}

@test "the commit hint labels each kept failing check unverified, above the commit line" {
  local repo="$TEMP_DIR/repo"
  step4 | sed 's/^UNVERIFIED=""/UNVERIFIED="lint test"/' > "$TEMP_DIR/hint.sh"
  grep -q '^UNVERIFIED="lint test"' "$TEMP_DIR/hint.sh"
  mkdir -p "$repo" && cd "$repo" && git init -q -b main
  mkdir -p .coding-crew && echo '{"test": "make test"}' > .coding-crew/dev-commands.json
  run bash "$TEMP_DIR/hint.sh"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "unverified: lint fails" ]
  [ "${lines[1]}" = "unverified: test fails" ]
  [[ "${lines[2]}" == "To finish, run: git add .coding-crew/dev-commands.json && git commit"* ]]
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
