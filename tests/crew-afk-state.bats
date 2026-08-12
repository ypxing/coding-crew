#!/usr/bin/env bats

# P3: sprint mechanism lives in scripts, not in prose.
#
# Four things used to be prompt text and are now executable:
#   sprint.env       — one file exporting the feature slug and every derived path, so the
#                      orchestrator never re-derives the slug from an alphabetical glob.
#   trace.sh         — each script traces its own step, so a step that ran is always in
#                      the trace and a step that was skipped can never appear as if it ran.
#   state.sh         — completions, retentions, blocks and coverage gaps, instead of lists
#                      carried in the model's context for the length of a sprint.
#   crew-summary.sh  — the rollup, the retained/promoted sections and the findings reminder,
#                      rendered from that state rather than from recollection.
#
# These assert behaviour. The prose assertions that used to stand in for them (a jq
# one-liner, a `git branch --list`, a print template) live in the other suites and now
# only require the body to call the script.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK_SCRIPTS="$REPO_ROOT/skills/crew-afk/scripts"

load helpers/render

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
  echo "Status: ready-for-agent" > ".scratch/$slug/issues/open/01-first.md"
  bash "$(installed_scripts)/session-init.sh" --feature-slug "$slug" >/dev/null
}

state() { bash "$(installed_scripts)/state.sh" "$@"; }

# ─── sprint.env ──────────────────────────────────────────────────────────────

@test "session-init writes sprint.env with the slug and every derived path" {
  init_sprint calc

  [ -f .scratch/calc/sprint.env ]
  # shellcheck disable=SC1091
  . "$TEMP_DIR/.scratch/calc/sprint.env"
  [ "$FEATURE_SLUG" = "calc" ]
  # Compare against git's own answer: on macOS mktemp hands back /var/... while
  # rev-parse resolves the /private/var symlink.
  [ "$MAIN_ROOT" = "$(git rev-parse --show-toplevel)" ]
  [ "$STATE_FILE" = "$MAIN_ROOT/.scratch/calc/sprint-state.json" ]
  [ "$TRACE_LOG" = "$MAIN_ROOT/.scratch/calc/traces/orchestrator.log" ]
  [ "$DISPATCH_DIR" = "$MAIN_ROOT/.scratch/calc/dispatch" ]
  [ "$REVIEW_DIR" = "$MAIN_ROOT/.scratch/calc/reviews" ]
  [ "$FEATURE_BRANCH" = "$(git rev-parse --abbrev-ref HEAD)" ]
}

@test "sourcing .scratch/sprint.env is enough — no slug lookup needed" {
  init_sprint calc

  run bash -c 'source "$TEMP_DIR/.scratch/sprint.env" && echo "$FEATURE_SLUG"'
  [ "$status" -eq 0 ]
  [ "$output" = "calc" ]
}

@test "sprint.env names the sprint the issues live in, not the alphabetically-first one" {
  # The bug this replaces: `jq .feature_slug "$(ls -1 .scratch/*/sprint-state.json | head -1)"`
  # picks whichever feature dir sorts first, silently pointing traces, resume state and the
  # PRD lookup at a directory with no issues in it.
  mkdir -p .scratch/aaa-old-sprint
  echo '{"feature_slug":"aaa-old-sprint"}' > .scratch/aaa-old-sprint/sprint-state.json
  init_sprint zzz-current

  run bash -c 'source "$TEMP_DIR/.scratch/sprint.env" && echo "$FEATURE_SLUG"'
  [ "$output" = "zzz-current" ]
}

@test "session-init traces the SESSION line" {
  init_sprint calc
  grep -q '\[SESSION\] feature=calc branch=' .scratch/calc/traces/orchestrator.log
}

# ─── trace.sh ────────────────────────────────────────────────────────────────

@test "trace.sh resolves the log through sprint.env with no arguments" {
  init_sprint calc
  run bash "$AFK_SCRIPTS/trace.sh" ROUND "round=2 issues=3"
  [ "$status" -eq 0 ]
  grep -q '\[ROUND\] round=2 issues=3' .scratch/calc/traces/orchestrator.log
}

@test "trace.sh is a silent no-op when there is no sprint to trace to" {
  # Tracing is observability: it must never fail the caller that is making progress.
  run bash "$AFK_SCRIPTS/trace.sh" ROUND "round=1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "merge-branches traces its own MERGE result" {
  init_sprint calc
  git checkout -q -b crew/calc/first
  echo change > file.txt && git add file.txt && git commit -q -m work
  git checkout -q "$(jq -r '.feature_slug' .scratch/calc/sprint-state.json | sed 's/^/feature\//')" 2>/dev/null \
    || git checkout -q feature/calc

  CREW_RECEIPTS=off run bash "$(installed_scripts)/merge-branches.sh" feature/calc crew/calc/first
  grep -q '\[MERGE\] branch=crew/calc/first success=true' .scratch/calc/traces/orchestrator.log
}

@test "close-issue traces its own CLOSE" {
  init_sprint calc
  run env CREW_RECEIPTS=off bash "$(installed_scripts)/close-issue.sh" .scratch/calc/issues/open/01-first.md
  [ "$status" -eq 0 ]
  grep -q '\[CLOSE\] issue=01-first.md' .scratch/calc/traces/orchestrator.log
}

# ─── state.sh ────────────────────────────────────────────────────────────────

@test "state.sh retain records the branch, the reason, and feeds cleanup --retain" {
  init_sprint calc

  run state retain --slug first --branch crew/calc/first --reason partial
  [ "$status" -eq 0 ]
  [ "$(jq -r '.retained_branches.first' .scratch/calc/sprint-state.json)" = "crew/calc/first" ]
  [ "$(jq -r '.retention.first.reason' .scratch/calc/sprint-state.json)" = "partial" ]

  run state get retained
  [ "$output" = "crew/calc/first" ]
}

@test "state.sh complete drops the retention so a stale branch is never resumed" {
  init_sprint calc
  state retain --slug first --branch crew/calc/first --reason partial >/dev/null

  run state complete --slug first --branch crew/calc/first
  [ "$status" -eq 0 ]
  [ "$(jq -r '.retained_branches.first // "gone"' .scratch/calc/sprint-state.json)" = "gone" ]

  run state get completed
  [ "$output" = "first" ]
  run state get merged
  [ "$output" = "crew/calc/first" ]
  run state get retained
  [ "$output" = "" ]
}

@test "state.sh complete and retain are both idempotent" {
  init_sprint calc
  state complete --slug first --branch crew/calc/first >/dev/null
  state complete --slug first --branch crew/calc/first >/dev/null
  run state get completed
  [ "$output" = "first" ]

  state retain --slug second --branch crew/calc/second --reason partial >/dev/null
  state retain --slug second --branch crew/calc/second --reason verification-failed >/dev/null
  [ "$(jq -r '.retention.second.reason' .scratch/calc/sprint-state.json)" = "verification-failed" ]
  run state get retained
  [ "$output" = "crew/calc/second" ]
}

@test "state.sh requires a reason for a retention" {
  init_sprint calc
  run state retain --slug first --branch crew/calc/first
  [ "$status" -ne 0 ]
  [[ "$output" == *"--reason"* ]]
}

@test "state.sh get merged and retained are disjoint" {
  init_sprint calc
  state complete --slug a --branch crew/calc/a >/dev/null
  state retain --slug b --branch crew/calc/b --reason criteria-unmet >/dev/null

  run state get merged
  [ "$output" = "crew/calc/a" ]
  run state get retained
  [ "$output" = "crew/calc/b" ]
}

@test "state.sh resume answers with the prior branch only when the ref still exists" {
  init_sprint calc
  state retain --slug first --branch crew/calc/first --reason partial >/dev/null

  run state resume --slug first
  [ "$output" = "no prior branch" ]

  git branch crew/calc/first
  run state resume --slug first
  [ "$output" = "resume: crew/calc/first" ]
}

@test "state.sh resume says no prior branch when nothing was retained" {
  init_sprint calc
  run state resume --slug never-ran
  [ "$output" = "no prior branch" ]
}

@test "state.sh refuses to guess which sprint it is bookkeeping for" {
  mkdir -p .scratch/aaa/issues/open .scratch/zzz/issues/open
  echo '{"feature_slug":"aaa"}' > .scratch/aaa/sprint-state.json
  run bash "$AFK_SCRIPTS/state.sh" get feature-slug --feature-slug zzz
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "state.sh records the resolved model and a coverage gap" {
  init_sprint calc
  state model opus >/dev/null
  state coverage-gap --slug first --categories "lint,typecheck" >/dev/null

  run state get model
  [ "$output" = "opus" ]
  [ "$(jq -r '.coverage_gaps.first' .scratch/calc/sprint-state.json)" = "lint,typecheck" ]
  grep -q '\[MODEL\] resolved=opus' .scratch/calc/traces/orchestrator.log
}

# ─── crew-summary.sh ─────────────────────────────────────────────────────────

@test "crew-summary renders the rollup from state, not from a print template" {
  init_sprint calc
  state model sonnet >/dev/null
  state round 2 --issues 3 >/dev/null
  state complete --slug a --branch crew/calc/a >/dev/null
  state retain --slug b --branch crew/calc/b --reason "verification-failed — tests did not pass" >/dev/null
  state blocked --slug c --branch crew/calc/c --reason "spec is ambiguous" >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  [[ "$output" == *"Rounds: 2"* ]]
  [[ "$output" == *"Model:  sonnet"* ]]
  [[ "$output" == *"Merged  (1): a"* ]]
  [[ "$output" == *"Partial (1): b"* ]]
  [[ "$output" == *"Blocked (1): c"* ]]
  [[ "$output" == *"## Verification Failures"* ]]
  [[ "$output" == *"## Retained Branches"* ]]
  [[ "$output" == *"crew/calc/b: retained (verification-failed — tests did not pass)"* ]]
}

@test "crew-summary omits empty sections and reports a clean sprint as clean" {
  init_sprint calc
  state complete --slug a --branch crew/calc/a >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  [[ "$output" == *"Partial (0): none"* ]]
  [[ "$output" != *"## Retained Branches"* ]]
  [[ "$output" != *"## Verification Failures"* ]]
  [[ "$output" == *"No open review findings."* ]]
}

@test "crew-summary surfaces a coverage gap instead of reading as a clean pass" {
  init_sprint calc
  state complete --slug a --branch crew/calc/a >/dev/null
  state coverage-gap --slug a --categories "lint,typecheck" >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"## Coverage Gaps"* ]]
  [[ "$output" == *"a: not_run lint,typecheck"* ]]
}

@test "crew-summary reports open findings with a real count" {
  init_sprint calc
  mkdir -p .scratch/calc/reviews
  cat > .scratch/calc/reviews/sprint-review-1.md <<'EOF'
## Branch: crew/calc/a (a)
- [MEDIUM] something worth a look
- [LOW] a nit
EOF

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"## Next Step"* ]]
  [[ "$output" == *"2 review finding(s) still need triage (MEDIUM=1, LOW=1)."* ]]
  [[ "$output" == *"Run: /crew-address-findings"* ]]
  [[ "$output" != *"## Unreviewed Branches"* ]]
}

@test "crew-summary never lets a clean findings count hide an unreviewed branch" {
  init_sprint calc
  mkdir -p .scratch/calc/reviews
  bash "$(installed_scripts)/promote-findings.sh" mark-not-run --feature-slug calc \
    --branch crew/calc/a --slug a --report .scratch/calc/reviews/sprint-review-1.md \
    --reason "reviewer dispatch timed out" >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"## Unreviewed Branches"* ]]
  [[ "$output" == *"crew/calc/a — reviewer dispatch timed out"* ]]
  [[ "$output" != *"No open review findings."* ]]
}

@test "crew-summary lists promoted findings with their fix issue and state" {
  init_sprint calc
  mkdir -p .scratch/calc/reviews
  cat > .scratch/calc/reviews/sprint-review-1.md <<'EOF'
## Branch: crew/calc/a (a)
- [CRITICAL] unchecked input at src/x.ts:12
EOF
  printf -- '- [ ] validate input at src/x.ts:12\n' > .scratch/calc/reviews/a.criteria.md
  bash "$(installed_scripts)/promote-findings.sh" defer --feature-slug calc \
    --branch crew/calc/a --slug a --title "Fix review findings: a" \
    --report .scratch/calc/reviews/sprint-review-1.md \
    --criteria-file .scratch/calc/reviews/a.criteria.md >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"## Promoted Findings"* ]]
  [[ "$output" == *"crew/calc/a: 1 finding(s) → 02-fix-findings-a (deferred-findings)"* ]]
  # The promoted finding is not also counted as needing human triage.
  [[ "$output" == *"No open review findings."* ]]
}

@test "crew-summary --stalled says so, and --no-reminder stops before the reminder" {
  init_sprint calc

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc --stalled
  [[ "$output" == *"STALLED: resolve blockers and re-run (/crew-afk)"* ]]

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc --no-reminder
  [[ "$output" != *"No open review findings."* ]]
  [[ "$output" != *"## Next Step"* ]]
}

@test "crew-summary traces EXIT with the counts it printed" {
  init_sprint calc
  state complete --slug a --branch crew/calc/a >/dev/null
  state retain --slug b --branch crew/calc/b --reason partial >/dev/null

  bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc >/dev/null
  grep -q '\[EXIT\] merged=1 partial=1 blocked=0' .scratch/calc/traces/orchestrator.log
}

# ─── the bodies delegate ─────────────────────────────────────────────────────

@test "no crew-afk body re-derives the feature slug from a sprint-state glob" {
  # This is the line the sprint.env indirection exists to delete. It sat directly
  # beneath a comment that said "Never re-derive it".
  for f in "$REPO_ROOT/skills/crew-afk/SKILL.md" "$REPO_ROOT/skills/crew-afk/dispatch.SKILL.md"; do
    ! grep -q 'ls -1 .*sprint-state.json' "$f"
  done
}

@test "every crew-afk body sources sprint.env instead of deriving paths" {
  for f in "$REPO_ROOT/skills/crew-afk/SKILL.md" "$REPO_ROOT/skills/crew-afk/dispatch.SKILL.md"; do
    grep -q 'source "$(git rev-parse --show-toplevel)/.scratch/sprint.env"' "$f"
  done
}

@test "no crew-afk body hand-rolls a trace line for a step a script performs" {
  # Each of these markers is emitted by the script that does the work. A prose echo
  # for the same marker is a second, unreliable source of the same fact — and for
  # DISPATCH it was a literal duplicate of what dispatch-agent.sh already logs.
  for f in "$REPO_ROOT/skills/crew-afk/SKILL.md" "$REPO_ROOT/skills/crew-afk/dispatch.SKILL.md" \
           "$REPO_ROOT"/skills/crew-afk/fragments/*/*.md; do
    for marker in DISPATCH VERIFY MERGE CLOSE PROMOTE FLUSH CLEANUP SQUASH EXIT SESSION; do
      if grep -q "echo \"\[\$(date[^\"]*\[$marker\]" "$f"; then
        echo "$f hand-rolls the [$marker] trace line" >&2
        return 1
      fi
    done
  done
}

@test "every crew-afk body derives cleanup's branch lists from state.sh" {
  for f in "$REPO_ROOT/skills/crew-afk/SKILL.md" "$REPO_ROOT/skills/crew-afk/dispatch.SKILL.md"; do
    grep -q 'state.sh" get merged' "$f"
    grep -q 'state.sh" get retained' "$f"
  done
}

@test "the sprint reports once, from disk — not per round" {
  # Three copies of the same content used to reach the context: the per-round rollup, the
  # verbatim echo of every worker report, and the final summary's per-issue detail. All of it
  # is on disk in sprint-state.json and the review reports, so the summary renders it once.
  for variant in claude pi codex copilot; do
    f=$(afk_variant "$variant")
    if grep -q 'crew-summary.sh" --no-reminder' "$f"; then
      echo "$variant still prints a per-round rollup" >&2; return 1
    fi
    if grep -qi "print each worker's report verbatim" "$f"; then
      echo "$variant still echoes every worker report" >&2; return 1
    fi
    if grep -q '^### Per-issue' "$f"; then
      echo "$variant still re-prints per-issue detail in the summary" >&2; return 1
    fi
  done
}

@test "P3: the orchestrator bodies are within their word budget" {
  # The audit measured 4,358–5,051 words per variant, of which ~9% was novel judgement.
  # A budget is the only thing that stops mechanism creeping back in as prose.
  #
  # Stage B (AC folded into the review) is a structural saving, not a prose one: it removes
  # an agent spawn and a full-diff read per branch while the words move rather than vanish.
  # The ratchet still tightens, so nothing reclaims the space that was freed.
  # Stage C (coverage opt-in, CRITICAL-only promotion, one summary instead of three) moves the
  # coverage prompt into the script and deletes the per-round reporting, so the ratchet tightens
  # again. It stops here: the prose that remains is either an instruction with no script behind
  # it or scar tissue from an observed failure, and cutting that buys tokens with correctness.
  for f in "$REPO_ROOT/skills/crew-afk/SKILL.md" "$REPO_ROOT/skills/crew-afk/dispatch.SKILL.md"; do
    words=$(wc -w < "$f")
    [ "$words" -lt 2750 ] || { echo "$f is $words words (budget 2750)" >&2; return 1; }
  done
}
