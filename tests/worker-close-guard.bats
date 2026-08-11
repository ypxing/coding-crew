#!/usr/bin/env bats

# P4: the worker's close is mechanically impossible during a sprint.
#
# A worker that closes its own issue removes it from the ready-for-agent list, so a later
# orchestrator gate that demotes the result to `partial` has nothing left to re-dispatch
# and the unmerged branch is orphaned. Four prompts argued about this in prose while
# solve-issue step 7 told the worker to close anyway. The fact now lives on disk:
#
#   .scratch/<feature-slug>/.orchestrated   written by session-init.sh, removed by crew-summary.sh
#   mark-issue-done.sh                      refuses while it exists (exit 3)
#
# These assert the refusal, not the sentence. The prose tests below only require the
# documents to point at the mechanism instead of re-arguing it.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
MARK_DONE="$REPO_ROOT/scripts/tracker/mark-issue-done.sh"
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

# ─── the close itself ────────────────────────────────────────────────────────

@test "mark-issue-done closes an issue whose criteria are all checked" {
  issue=$(make_issue)
  run bash "$MARK_DONE" "$issue"
  [ "$status" -eq 0 ]
  [ ! -f "$issue" ]
  [ -f ".scratch/alpha/issues/done/01-first.md" ]
  grep -q '^Status: done' ".scratch/alpha/issues/done/01-first.md"
}

@test "mark-issue-done is idempotent when the issue is already in done/" {
  issue=$(make_issue)
  bash "$MARK_DONE" "$issue"
  run bash "$MARK_DONE" "$issue"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already closed"* ]]
}

@test "mark-issue-done fails when the issue does not exist at all" {
  run bash "$MARK_DONE" ".scratch/alpha/issues/open/99-nope.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "mark-issue-done reports usage when given no issue path" {
  run bash "$MARK_DONE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

# ─── guard 1: an orchestrator owns the close ─────────────────────────────────

@test "mark-issue-done refuses while the sprint marker exists" {
  issue=$(make_issue)
  touch ".scratch/alpha/.orchestrated"

  run bash "$MARK_DONE" "$issue"
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"orchestrator"* ]]
  # The work-loss failure this prevents: the issue must still be listed as open.
  [ -f "$issue" ]
  [ ! -f ".scratch/alpha/issues/done/01-first.md" ]
  grep -q '^Status: ready-for-agent' "$issue"
}

@test "mark-issue-done refuses when CREW_ORCHESTRATED is set, with no marker present" {
  issue=$(make_issue)
  run env CREW_ORCHESTRATED=1 bash "$MARK_DONE" "$issue"
  [ "$status" -eq 3 ]
  [ -f "$issue" ]
}

@test "mark-issue-done --force overrides the sprint marker" {
  issue=$(make_issue)
  touch ".scratch/alpha/.orchestrated"
  run bash "$MARK_DONE" "$issue" --force
  [ "$status" -eq 0 ]
  [ -f ".scratch/alpha/issues/done/01-first.md" ]
}

# ─── guard 2: unchecked criteria ─────────────────────────────────────────────

@test "mark-issue-done refuses an unchecked acceptance criterion" {
  issue=$(make_issue)
  printf -- '- [ ] three\n' >> "$issue"

  run bash "$MARK_DONE" "$issue"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unchecked criteria"* ]]
  [[ "$output" == *"three"* ]]
  [ -f "$issue" ]
}

@test "mark-issue-done refuses an unchecked cross-cutting requirement" {
  issue=$(make_issue)
  printf '\n## Cross-cutting Requirements\n\n- [ ] docs updated\n' >> "$issue"

  run bash "$MARK_DONE" "$issue"
  [ "$status" -eq 4 ]
  [[ "$output" == *"docs updated"* ]]
}

@test "mark-issue-done ignores unchecked boxes outside the criteria sections" {
  issue=$(make_issue)
  printf '\n## Notes\n\n- [ ] someone else s todo\n' >> "$issue"

  run bash "$MARK_DONE" "$issue"
  [ "$status" -eq 0 ]
}

@test "mark-issue-done --force closes despite an unchecked criterion" {
  issue=$(make_issue)
  printf -- '- [ ] descoped\n' >> "$issue"
  run bash "$MARK_DONE" "$issue" --force
  [ "$status" -eq 0 ]
}

# ─── sprint lifecycle ────────────────────────────────────────────────────────

@test "session-init writes the orchestration marker" {
  init_sprint alpha
  [ -f ".scratch/alpha/.orchestrated" ]
}

@test "a worker cannot close its issue during a live sprint" {
  init_sprint alpha
  issue=$(make_issue alpha 02-second)

  run bash "$MARK_DONE" "$issue"
  [ "$status" -eq 3 ]
  [ -f "$issue" ]
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

# ─── the documents point at the mechanism instead of re-arguing it ───────────

@test "tracker template delegates mark-done to the script and hardcodes no mv" {
  local tpl="$REPO_ROOT/docs/templates/trackers/local.md"
  section=$(awk '/^## Operation: mark-done/{f=1;next} /^## /{f=0} f' "$tpl")
  echo "$section" | grep -q 'mark-issue-done.sh'
  # Exit codes are the contract, so the caller can tell a refusal from a failure.
  echo "$section" | grep -q '3'
  echo "$section" | grep -q '4'
  # No hand-rolled close left to bypass the guards.
  ! echo "$section" | grep -q 'mkdir -p .*done'
  ! echo "$section" | grep -qE '^ *mv "<issue-path>"'
}

@test "solve-issue delegates the close and no longer argues about orchestrated runs" {
  local f="$REPO_ROOT/skills/solve-issue/SKILL.md"
  grep -q 'mark-done' "$f"
  ! grep -q 'Skip this step entirely' "$f"
  ! grep -q 'orphaning the unmerged branch' "$f"
}

@test "solve-issue has a non-interactive branch instead of asking a question nobody reads" {
  local f="$REPO_ROOT/skills/solve-issue/SKILL.md"
  section=$(awk '/^### 8\./{f=1} /^## /{if(f)exit} f' "$f")
  echo "$section" | grep -qi 'non-interactive'
  echo "$section" | grep -q 'CREW_ORCHESTRATED'
  echo "$section" | grep -qi 'partial'
}

@test "tdd planning has a non-interactive branch for its approval gates" {
  local f="$REPO_ROOT/skills/tdd/SKILL.md"
  section=$(awk '/^### 1\. Planning/{f=1;next} /^### /{f=0} f' "$f")
  # The approval gates still exist for interactive use...
  echo "$section" | grep -qi 'confirm with user'
  # ...and a headless worker is told what to do instead of waiting on them.
  echo "$section" | grep -qi 'non-interactive'
  echo "$section" | grep -q 'CREW_ORCHESTRATED'
  echo "$section" | grep -qi 'acceptance criteria'
}

@test "every crew-coder variant cites the mechanical refusal, not three paragraphs" {
  for f in "$REPO_ROOT"/agents/crew-coder/claude.agent.md \
           "$REPO_ROOT"/agents/crew-coder/copilot.agent.md \
           "$REPO_ROOT"/agents/crew-coder/pi.agent.md \
           "$REPO_ROOT"/agents/crew-coder/codex.agent.toml; do
    section=$(awk '/^## Issue Ownership/{f=1;next} /^## /{f=0} f' "$f")
    echo "$section" | grep -q '.orchestrated'
    echo "$section" | grep -q 'mark-issue-done.sh'
    # The prose that solve-issue no longer contains must not linger here either.
    ! echo "$section" | grep -q 'solve-issue step 7'
    # Budget: a gate that fails closed does not need re-arguing.
    [ "$(echo "$section" | wc -w)" -lt 120 ]
  done
}

# ─── install / uninstall ─────────────────────────────────────────────────────

@test "install ships the tracker close script, executable" {
  cd "$REPO_ROOT"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  [ -f "$TEMP_DIR/.coding-crew/scripts/mark-issue-done.sh" ]
  [ -x "$TEMP_DIR/.coding-crew/scripts/mark-issue-done.sh" ]
}

@test "install overwrites a stale close script: it is mechanism, not user text" {
  cd "$REPO_ROOT"
  mkdir -p "$TEMP_DIR/.coding-crew/scripts"
  echo "stale" > "$TEMP_DIR/.coding-crew/scripts/mark-issue-done.sh"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  ! grep -q '^stale$' "$TEMP_DIR/.coding-crew/scripts/mark-issue-done.sh"
  grep -q 'REFUSED' "$TEMP_DIR/.coding-crew/scripts/mark-issue-done.sh"
}

@test "uninstall removes the close script but keeps the tracker doc" {
  cd "$REPO_ROOT"
  TARGET_REPO="$TEMP_DIR" ./install.sh claude --skill solve-issue >/dev/null
  TARGET_REPO="$TEMP_DIR" ./uninstall.sh >/dev/null
  [ ! -f "$TEMP_DIR/.coding-crew/scripts/mark-issue-done.sh" ]
  [ -f "$TEMP_DIR/.coding-crew/docs/issue-tracker.md" ]
}
