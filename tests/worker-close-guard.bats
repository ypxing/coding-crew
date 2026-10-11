#!/usr/bin/env bats

# P4: the worker's close is mechanically impossible during a sprint.
#
# A worker that closes its own issue removes it from the ready-for-agent list, so a later
# orchestrator gate that demotes the result to `partial` has nothing left to re-dispatch
# and the unmerged branch is orphaned. Four prompts argued about this in prose while
# solve-issue step 7 told the worker to close anyway. The fact now lives on disk:
#
#   .scratch/<feature-slug>/.orchestrated   written by session-init.sh, removed by crew-summary.sh
#   cli.mjs mark-done                       refuses while it exists (exit 3)
#
# mark-done's refusal itself is tested once, at the CLI, in tests/orchestrator/tracker-cli-write.test.mjs;
# these cover the marker's lifecycle and the orchestrator's own close.

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
  # The crew-afk scripts ask this repo's own tracker CLI, not a full install.
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  unset CREW_ORCHESTRATED CREW_INSTALL_DIR
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# An issue with every criterion checked off — the only shape that should ever close.
make_issue() {
  local slug="${1:-alpha}" file="${2:-01-first}"
  mkdir -p ".scratch/$slug/issues/open"
  cat > ".scratch/$slug/issues/open/$file.md" <<'EOF'
# First

Status: ready-for-agent

## Acceptance criteria

- [x] one
- [x] two
EOF
  echo ".scratch/$slug/issues/open/$file.md"
}

# session-init.sh calls trace.sh as a sibling; that colocation
# only exists after install.sh copies them into the skill's scripts/ dir. Reproduce it.
installed_scripts() {
  local dir="$TEMP_DIR/installed-scripts"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir"
    cp "$AFK_SCRIPTS"/*.sh "$dir/"
  fi
  echo "$dir"
}

init_sprint() {
  local slug="${1:-alpha}"
  mkdir -p ".scratch/$slug/issues/open"
  [ -f ".scratch/$slug/issues/open/01-first.md" ] || echo "Status: ready-for-agent" > ".scratch/$slug/issues/open/01-first.md"
  bash "$(installed_scripts)/session-init.sh" --feature-slug "$slug" >/dev/null
}

# ─── sprint lifecycle ────────────────────────────────────────────────────────

@test "session-init writes the orchestration marker" {
  init_sprint alpha
  [ -f ".scratch/alpha/.orchestrated" ]
}

@test "crew-summary removes the marker on the final summary" {
  init_sprint alpha
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug alpha
  [ "$status" -eq 0 ]
  [ ! -f ".scratch/alpha/.orchestrated" ]
}

@test "crew-summary --no-reminder keeps the marker: the sprint is still running" {
  init_sprint alpha
  bash "$(installed_scripts)/crew-summary.sh" --feature-slug alpha --no-reminder
  [ -f ".scratch/alpha/.orchestrated" ]
}

@test "the orchestrator's own close-issue.sh is not blocked by the marker" {
  init_sprint alpha
  issue=$(make_issue alpha 02-second)

  run env CREW_RECEIPTS=off bash "$(installed_scripts)/close-issue.sh" "$issue"
  [ "$status" -eq 0 ]
  [ -f ".scratch/alpha/issues/done/02-second.md" ]
}

# ─── one writer per issue file ───────────────────────────────────────
# On an orchestrated run the orchestrator is the issue file's one writer.

@test "the orchestrator's close is the writer that ticks the boxes" {
  init_sprint alpha
  mkdir -p ".scratch/alpha/issues/open"
  cat > ".scratch/alpha/issues/open/06-unticked.md" <<'EOF'
# Sixth

Status: ready-for-agent

## Acceptance criteria

- [ ] a criterion the worker must not tick itself
EOF

  run env CREW_RECEIPTS=off bash "$(installed_scripts)/close-issue.sh" \
    ".scratch/alpha/issues/open/06-unticked.md"
  [ "$status" -eq 0 ]
  grep -q -- '- \[x\] a criterion the worker must not tick itself' \
    ".scratch/alpha/issues/done/06-unticked.md"
}
