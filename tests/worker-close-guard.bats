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
# These assert the refusal, not the sentence. The prose tests below only require the
# documents to point at the mechanism instead of re-arguing it.

load helpers/render

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

# mark_done <args> — the tracker CLI's mark-done, the one close behind both guards.
mark_done() { node "$REPO_ROOT/tracker/cli.mjs" mark-done "$@"; }

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

# ─── the close itself ────────────────────────────────────────────────────────

@test "mark-done closes an issue whose criteria are all checked" {
  issue=$(make_issue)
  run mark_done "$issue"
  [ "$status" -eq 0 ]
  [ ! -f "$issue" ]
  [ -f ".scratch/alpha/issues/done/01-first.md" ]
  grep -q '^Status: done' ".scratch/alpha/issues/done/01-first.md"
}

@test "mark-done is idempotent when the issue is already in done/" {
  issue=$(make_issue)
  mark_done "$issue"
  run mark_done "$issue"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already closed"* ]]
}

@test "mark-done fails when the issue does not exist at all" {
  run mark_done ".scratch/alpha/issues/open/99-nope.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not found"* ]]
}

@test "mark-done reports usage when given no issue path" {
  run mark_done
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

# ─── guard 1: an orchestrator owns the close ─────────────────────────────────

@test "mark-done refuses while the sprint marker exists" {
  issue=$(make_issue)
  touch ".scratch/alpha/.orchestrated"

  run mark_done "$issue"
  [ "$status" -eq 3 ]
  [[ "$output" == *"REFUSED"* ]]
  [[ "$output" == *"orchestrator"* ]]
  # The work-loss failure this prevents: the issue must still be listed as open.
  [ -f "$issue" ]
  [ ! -f ".scratch/alpha/issues/done/01-first.md" ]
  grep -q '^Status: ready-for-agent' "$issue"
}

@test "mark-done refuses when CREW_ORCHESTRATED is set, with no marker present" {
  issue=$(make_issue)
  CREW_ORCHESTRATED=1 run mark_done "$issue"
  [ "$status" -eq 3 ]
  [ -f "$issue" ]
}

@test "mark-done --force overrides the sprint marker" {
  issue=$(make_issue)
  touch ".scratch/alpha/.orchestrated"
  run mark_done "$issue" --force
  [ "$status" -eq 0 ]
  [ -f ".scratch/alpha/issues/done/01-first.md" ]
}

# ─── guard 2: unchecked criteria ─────────────────────────────────────────────

@test "mark-done refuses an unchecked acceptance criterion" {
  issue=$(make_issue)
  printf -- '- [ ] three\n' >> "$issue"

  run mark_done "$issue"
  [ "$status" -eq 4 ]
  [[ "$output" == *"unchecked criteria"* ]]
  [[ "$output" == *"three"* ]]
  [ -f "$issue" ]
}

@test "mark-done refuses an unchecked cross-cutting requirement" {
  issue=$(make_issue)
  printf '\n## Cross-cutting Requirements\n\n- [ ] docs updated\n' >> "$issue"

  run mark_done "$issue"
  [ "$status" -eq 4 ]
  [[ "$output" == *"docs updated"* ]]
}

@test "mark-done ignores unchecked boxes outside the criteria sections" {
  issue=$(make_issue)
  printf '\n## Notes\n\n- [ ] someone else s todo\n' >> "$issue"

  run mark_done "$issue"
  [ "$status" -eq 0 ]
}

@test "mark-done --force closes despite an unchecked criterion" {
  issue=$(make_issue)
  printf -- '- [ ] descoped\n' >> "$issue"
  run mark_done "$issue" --force
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

  run mark_done "$issue"
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

@test "tracker template delegates mark-done to the tracker CLI and hardcodes no mv" {
  local tpl="$REPO_ROOT/tracker/docs/local.md"
  section=$(awk '/^## Tracker CLI/{f=1;next} /^## /{f=0} f' "$tpl")
  echo "$section" | grep -q '^node "$TRACKER" mark-done <ref>'
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

# ─── one writer per issue file ───────────────────────────────────────
# The worker was told both to write to the issue file (§7 tick + mark-done, §8 unmet
# criteria) and never to touch it (crew-coder). Only the close was enforced. Both
# halves now branch on the same fact cli.mjs mark-done checks, so orchestrated runs
# have exactly one writer: the orchestrator.

solve_issue_section() {
  awk -v n="$1" 'index($0, "### " n ".")==1{f=1;next} /^### /{f=0} f' \
    "$REPO_ROOT/skills/solve-issue/SKILL.md"
}

@test "solve-issue section 7 branches on the same fact cli.mjs mark-done checks" {
  section=$(solve_issue_section 7)
  # The capability check, not the caller's name.
  echo "$section" | grep -q 'CREW_ORCHESTRATED'
  echo "$section" | grep -q '\.orchestrated'
}

@test "solve-issue section 7 forbids every issue-file write on an orchestrated run" {
  section=$(solve_issue_section 7)
  # An orchestrated branch that says what not to write: no tick, no mark-done.
  echo "$section" | grep -qiE 'write nothing to the issue file|no issue file writes'
  echo "$section" | grep -qi 'do not tick\|no tick'
}

@test "solve-issue section 7 keeps the direct-invocation close intact" {
  section=$(solve_issue_section 7)
  # Unorchestrated: still ticks its own boxes and still routes the close through the
  # tracker operation rather than a hand-rolled mv.
  echo "$section" | grep -q -- '- \[x\]'
  echo "$section" | grep -q 'Cross-cutting Requirements'
  echo "$section" | grep -qF 'node "$TRACKER" mark-done <issue-ref>'
  ! echo "$section" | grep -qE '^ *mv '
}

@test "solve-issue section 8 writes ## Unmet criteria only when nobody else owns the file" {
  section=$(awk '/^### 8\./{f=1;next} /^## /{if(f)exit} f' \
    "$REPO_ROOT/skills/solve-issue/SKILL.md")
  echo "$section" | grep -q '## Unmet criteria'
  # The write is conditional on the same check §7 uses.
  echo "$section" | grep -q 'CREW_ORCHESTRATED\|ORCHESTRATED'
  # ...and the orchestrated path reports instead of writing.
  echo "$section" | grep -qi 'report'
}

@test "a pre-ticked issue is still not closable by a worker under an orchestrator" {
  # The bypass this issue closes: mark-done's exit-4 criteria guard is
  # satisfied by a worker ticking its own boxes. Exit 3 must fire first and
  # unconditionally, so self-attestation buys nothing.
  issue=$(make_issue alpha 05-preticked)   # make_issue writes every box as [x]
  touch ".scratch/alpha/.orchestrated"

  run mark_done "$issue"
  [ "$status" -eq 3 ]
  [ -f "$issue" ]
  [ ! -f ".scratch/alpha/issues/done/05-preticked.md" ]
}

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

@test "every crew-coder variant points at the procedure instead of restating it" {
  for p in "${CODER_VARIANTS[@]}"; do
    local f
    f=$(coder_variant "$p")
    section=$(awk '/^## Issue Ownership/{f=1;next} /^## /{f=0} f' "$f")
    # The agent needs two facts: report `complete`, leave the file. The procedure and
    # its enforcement live in solve-issue §7 and cli.mjs mark-done respectively.
    echo "$section" | grep -q 'solve-issue' || {
      echo "$f: Issue Ownership does not point at solve-issue" >&2; return 1; }
    echo "$section" | grep -q 'complete'
    # Retired: three paragraphs of enforcement the gate already performs.
    ! echo "$section" | grep -q 'solve-issue step 7'
    ! echo "$section" | grep -q 'exit 3'
    # One line — a pointer, not a second copy of the rule.
    [ "$(echo "$section" | grep -c '[^[:space:]]')" -eq 1 ]
    [ "$(echo "$section" | wc -w)" -lt 60 ]
  done
}
