#!/usr/bin/env bats

# crew-summary.sh's dev-commands.json reminder — .coding-crew/dev-commands.json is committed
# but nothing auto-commits it (see PRD: no auto-commit to any branch, ever), so the end-of-
# sprint summary reminds a human to review and commit it when it's dirty at MAIN_ROOT, and
# says nothing when it's clean or was never created. --no-reminder suppresses this section
# the same way it already suppresses the findings reminder.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_SCRIPTS="$REPO_ROOT/skills/crew-afk/scripts"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  git init -q -b main
  git config user.email "test@test.com"
  git config user.name "Test"
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m initial
  export MAIN_ROOT="$TEMP_DIR"
  unset CREW_ORCHESTRATED
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# session-init.sh calls feature-branch-setup.sh and trace.sh as siblings; that colocation
# only exists after install.sh copies them into the skill's scripts/ dir. Reproduce it.
installed_scripts() {
  local dir="$TEMP_DIR/installed-scripts"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    cp "$AFK_SCRIPTS"/*.sh "$dir/"
    cp "$REPO_ROOT/scripts/skill-utils/git-workflow/feature-branch-setup.sh" "$dir/"
  fi
  echo "$dir"
}

init_sprint() {
  local slug="${1:-alpha}"
  mkdir -p ".scratch/$slug/issues/open"
  [ -f ".scratch/$slug/issues/open/01-first.md" ] || echo "Status: ready-for-agent" > ".scratch/$slug/issues/open/01-first.md"
  bash "$(installed_scripts)/session-init.sh" --feature-slug "$slug" >/dev/null
}

@test "crew-summary reminds when dev-commands.json has uncommitted changes at MAIN_ROOT" {
  init_sprint alpha
  mkdir -p .coding-crew
  printf '{"test": "npm test", "lint": null, "typecheck": null, "install": null, "env": null}' > .coding-crew/dev-commands.json

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Dev Commands Cache"* ]]
  [[ "$output" == *".coding-crew/dev-commands.json has uncommitted changes"* ]]
}

@test "crew-summary omits the dev-commands section when the cache is committed and clean" {
  init_sprint alpha
  mkdir -p .coding-crew
  printf '{"test": "npm test", "lint": null, "typecheck": null, "install": null, "env": null}' > .coding-crew/dev-commands.json
  git add .coding-crew/dev-commands.json
  git commit -q -m "commit dev-commands cache"

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug alpha
  [ "$status" -eq 0 ]
  [[ "$output" != *"## Dev Commands Cache"* ]]
}

@test "crew-summary omits the dev-commands section when the cache file was never created" {
  init_sprint alpha

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug alpha
  [ "$status" -eq 0 ]
  [[ "$output" != *"## Dev Commands Cache"* ]]
}

@test "crew-summary --no-reminder suppresses the dev-commands reminder too" {
  init_sprint alpha
  mkdir -p .coding-crew
  printf '{"test": "npm test", "lint": null, "typecheck": null, "install": null, "env": null}' > .coding-crew/dev-commands.json

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug alpha --no-reminder
  [ "$status" -eq 0 ]
  [[ "$output" != *"## Dev Commands Cache"* ]]
}
