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
  # The crew-afk scripts ask the tracker CLI which tracker this is: this repo's own copy.
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  unset CREW_INSTALL_DIR
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"
  git init -q -b main
  git config user.email "test@test.com"
  git config user.name "Test"
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m initial
  export MAIN_ROOT="$TEMP_DIR"
  # crew-summary.sh and promote-findings.sh read the aggregate review report through
  # review-rollup.mjs, not a hand-rolled awk — these fixtures copy the scripts alone
  # (see installed_scripts below), not a full install, so point it at the repo's own copy.
  export CREW_REVIEW_ROLLUP="$REPO_ROOT/orchestrator/review-rollup.mjs"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
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
  echo "Status: ready-for-agent" > ".scratch/$slug/issues/open/01-first.md"
  bash "$(installed_scripts)/session-init.sh" --feature-slug "$slug" >/dev/null
  # What the orchestrator exports to every child it runs: the scripts take their sprint from it.
  export FEATURE_SLUG="$slug"
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
  # The branch exists, but the main checkout was not switched to it.
  [ "$FEATURE_BRANCH" = "feature/calc" ]
  git rev-parse --verify -q refs/heads/feature/calc
  [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ]
}

@test "session-init writes no repo-wide .scratch/sprint.env pointer" {
  init_sprint calc

  [ ! -e .scratch/sprint.env ]
  run bash -c 'source "$TEMP_DIR/.scratch/calc/sprint.env" && echo "$FEATURE_SLUG"'
  [ "$status" -eq 0 ]
  [ "$output" = "calc" ]
}

@test "session-init --print-branch names the slug, branch and default branch and touches nothing" {
  mkdir -p .scratch/calc/issues/open
  echo "Status: ready-for-agent" > .scratch/calc/issues/open/01-first.md
  run bash "$(installed_scripts)/session-init.sh" --print-branch --feature-slug calc --jira PROJ-7
  [ "$status" -eq 0 ]
  [[ "$output" == *"FEATURE_SLUG=calc"* ]]
  [[ "$output" == *"FEATURE_BRANCH=feature/PROJ-7-calc"* ]]
  [[ "$output" == *"DEFAULT_BRANCH=main"* ]]
  ! git rev-parse --verify -q refs/heads/feature/PROJ-7-calc
  [ ! -e .scratch/calc/sprint.env ]
}

@test "sprint.env names the sprint the issues live in, not the alphabetically-first one" {
  # The bug this replaces: `jq .feature_slug "$(ls -1 .scratch/*/sprint-state.json | head -1)"`
  # picks whichever feature dir sorts first, silently pointing traces, resume state and the
  # PRD lookup at a directory with no issues in it.
  mkdir -p .scratch/aaa-old-sprint
  echo '{"feature_slug":"aaa-old-sprint"}' > .scratch/aaa-old-sprint/sprint-state.json
  init_sprint zzz-current

  run bash -c 'source "$TEMP_DIR/.scratch/zzz-current/sprint.env" && echo "$FEATURE_SLUG"'
  [ "$output" = "zzz-current" ]
}

@test "session-init accepts the retired --prd-audit and --coverage, with a notice, and records no PRD audit" {
  mkdir -p .scratch/calc/issues/open
  echo "Status: ready-for-agent" > .scratch/calc/issues/open/01-first.md
  run bash "$(installed_scripts)/session-init.sh" --feature-slug calc --prd-audit fix --coverage
  [ "$status" -eq 0 ]
  [[ "$output" == *'`--prd-audit` no longer does anything'* ]]
  [[ "$output" == *'`--coverage` no longer does anything'* ]]
  ! grep -q PRD_AUDIT .scratch/calc/sprint.env
}

@test "session-init traces the SESSION line" {
  init_sprint calc
  grep -q '\[SESSION\] feature=calc branch=' .scratch/calc/traces/orchestrator.log
}

# ─── trace.sh ────────────────────────────────────────────────────────────────

@test "trace.sh resolves the log from --feature-slug" {
  init_sprint calc
  unset FEATURE_SLUG
  run bash "$AFK_SCRIPTS/trace.sh" --feature-slug calc ROUND "round=2 issues=3"
  [ "$status" -eq 0 ]
  grep -q '\[ROUND\] round=2 issues=3' .scratch/calc/traces/orchestrator.log
}

@test "trace.sh writes an ISO date and a padded level ahead of the marker, info by default" {
  TRACE_LOG="$TEMP_DIR/t.log" run bash "$AFK_SCRIPTS/trace.sh" ROUND "round=1"
  [ "$status" -eq 0 ]
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z INFO  \[ROUND\] round=1$' "$TEMP_DIR/t.log"
}

@test "trace.sh --level names the level, alongside --log in either order" {
  bash "$AFK_SCRIPTS/trace.sh" --level error --log "$TEMP_DIR/t.log" MERGE "success=false"
  bash "$AFK_SCRIPTS/trace.sh" --log "$TEMP_DIR/t.log" --level debug STEP "x"
  grep -qE 'Z ERROR \[MERGE\] success=false$' "$TEMP_DIR/t.log"
  grep -qE 'Z DEBUG \[STEP\] x$' "$TEMP_DIR/t.log"
}

@test "trace.sh refuses an unknown level and writes nothing" {
  TRACE_LOG="$TEMP_DIR/t.log" run bash "$AFK_SCRIPTS/trace.sh" --level loud ROUND "x"
  [ "$status" -ne 0 ]
  [ ! -e "$TEMP_DIR/t.log" ]
}

@test "trace.sh inside a dispatched agent does not find the sprint on its own" {
  # A worker inherits MAIN_ROOT, so without this every trace.sh call its test suite makes
  # would land in the live sprint's orchestrator.log.
  init_sprint calc
  unset FEATURE_SLUG
  CREW_ORCHESTRATED=1 run bash "$AFK_SCRIPTS/trace.sh" ROUND "round=9 leaked"
  [ "$status" -eq 0 ]
  ! grep -q 'leaked' .scratch/calc/traces/orchestrator.log
}

@test "trace.sh inside a dispatched agent still honours an explicit log" {
  CREW_ORCHESTRATED=1 TRACE_LOG="$TEMP_DIR/own.log" run bash "$AFK_SCRIPTS/trace.sh" ROUND "round=1"
  [ "$status" -eq 0 ]
  grep -q '\[ROUND\] round=1' "$TEMP_DIR/own.log"
}

@test "trace.sh by hand with no sprint env and no --feature-slug exits 2 naming --feature-slug" {
  run bash "$AFK_SCRIPTS/trace.sh" ROUND "round=1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"--feature-slug"* ]]
}

@test "trace.sh inside a dispatched agent with no sprint to trace to stays a silent no-op" {
  CREW_ORCHESTRATED=1 run bash "$AFK_SCRIPTS/trace.sh" ROUND "round=1"
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

@test "state.sh retention reports the recorded reason, distinguishing a review-only retry from other retentions" {
  init_sprint calc
  state retain --slug first --branch crew/calc/first --reason review-not-run >/dev/null

  run state retention --slug first
  [ "$output" = "reason: review-not-run" ]

  state retain --slug second --branch crew/calc/second --reason verification-failed >/dev/null
  run state retention --slug second
  [ "$output" = "reason: verification-failed" ]
}

@test "state.sh retention says no retention record for a slug that was never retained" {
  init_sprint calc
  run state retention --slug never-ran
  [ "$output" = "no retention record" ]
}

@test "state.sh drop-retained removes a slug's retention and leaves the others, so it no longer counts as partial" {
  init_sprint calc
  state retain --slug first --branch crew/calc/first --reason verification-failed:fixable >/dev/null
  state retain --slug second --branch crew/calc/second --reason partial >/dev/null

  run state drop-retained --slug first --reason "issue closed"
  [ "$status" -eq 0 ]
  [ "$output" = "STATE: drop-retained slug=first branch=crew/calc/first — issue closed" ]
  [ "$(jq -r '.retained_branches.first // "gone"' .scratch/calc/sprint-state.json)" = "gone" ]
  [ "$(jq -r '.retention.first // "gone"' .scratch/calc/sprint-state.json)" = "gone" ]
  run state get partial
  [ "$output" = "second" ]
  run state get retained
  [ "$output" = "crew/calc/second" ]
  grep -q "drop-retained slug=first" .scratch/calc/traces/orchestrator.log
}

@test "state.sh drop-retained keeps a blocked slug unless --issue-gone says its issue left the tracker" {
  init_sprint calc
  state blocked --slug first --branch crew/calc/first --reason "tests red" --number 7 >/dev/null
  state drop-retained --slug first --reason "branch gone" >/dev/null
  [ "$(jq -r '.retention.first // "gone"' .scratch/calc/sprint-state.json)" = "gone" ]
  run state get blocked
  [ "$output" = "first" ]

  state drop-retained --slug first --reason "issue closed" --issue-gone >/dev/null
  run state get blocked
  [ "$output" = "" ]
  [ "$(jq -r '.blocked_labelled.first // "gone"' .scratch/calc/sprint-state.json)" = "gone" ]
  [ "$(jq -r '.blocked_reasons.first // "gone"' .scratch/calc/sprint-state.json)" = "gone" ]
}

@test "state.sh drop-retained on a slug with no record is a no-op, and requires --slug" {
  init_sprint calc
  run state drop-retained --slug never-ran
  [ "$status" -eq 0 ]
  [ "$output" = "STATE: drop-retained slug=never-ran — no record" ]
  run state drop-retained
  [ "$status" -ne 0 ]
  [[ "$output" == *"--slug"* ]]
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

@test "state.sh dispatch-cost files a tagged dispatch in this run's ledger; the totals span every run" {
  init_sprint calc
  state dispatch-cost --cost 1.5 --duration-ms 60000 --turns 10 >/dev/null   # an earlier run, untagged
  state run-start --id run-2 >/dev/null
  state dispatch-cost --cost 0.5 --duration-ms 1000 --turns 3 --slug a --role coder --attempt 1 \
    --session-id s1 --context-tokens 42000 --head abc123 >/dev/null
  f=.scratch/calc/sprint-state.json
  [ "$(jq -r '.total_cost_usd' "$f")" = "2" ]
  [ "$(jq -r '.dispatches | length' "$f")" = "1" ]
  [ "$(jq -c '.dispatches[0] | [.run, .slug, .role, .attempt, .session_id, .context_tokens, .head]' "$f")" = '["run-2","a","coder",1,"s1",42000,"abc123"]' ]
  grep -q 'dispatch-cost slug=a role=coder attempt=1 cost=0.5' .scratch/calc/traces/orchestrator.log
}

@test "state.sh run-end writes last_exit with this run's id, the reason, the code and an ISO time" {
  init_sprint calc
  state run-start --id run-1 >/dev/null
  run state run-end --reason "finished" --code 0
  [ "$status" -eq 0 ]
  f=.scratch/calc/sprint-state.json
  [ "$(jq -c '.last_exit | [.run, .reason, .code]' "$f")" = '["run-1","finished",0]' ]
  [[ "$(jq -r '.last_exit.at' "$f")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "state.sh run-end without --reason exits non-zero with a usage message and writes nothing" {
  init_sprint calc
  state run-start --id run-1 >/dev/null
  run state run-end --code 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage: state.sh run-end --reason <text> --code <n>"* ]]
  [ "$(jq -r '.last_exit // "none"' .scratch/calc/sprint-state.json)" = "none" ]
}

@test "state.sh run-start counts runs across invocations and keeps the previous run's exit" {
  init_sprint calc
  state run-start --id run-1 >/dev/null
  f=.scratch/calc/sprint-state.json
  [ "$(jq -r '.runs' "$f")" = "1" ]
  [ "$(jq -r '.previous_exit // "none"' "$f")" = "none" ]
  state run-end --reason "stalled" --code 2 >/dev/null
  run state run-start --id run-2
  [ "$status" -eq 0 ]
  [[ "$output" != *"without an exit"* ]]
  [ "$(jq -r '.runs' "$f")" = "2" ]
  [ "$(jq -r '.previous_exit.reason' "$f")" = "stalled" ]
}

@test "state.sh run-start after a run with no last_exit logs that it ended without an exit" {
  init_sprint calc
  state run-start --id run-1 >/dev/null
  run state run-start --id run-2
  [ "$status" -eq 0 ]
  [[ "$output" == *"previous run ended without an exit (killed or crashed)"* ]]
  grep -q 'WARN .*previous run ended without an exit (killed or crashed)' .scratch/calc/traces/orchestrator.log
  [ "$(jq -r '.previous_exit.reason' .scratch/calc/sprint-state.json)" = "ended without an exit (killed or crashed)" ]
}

@test "state.sh run-start on a pre-upgrade state (current_run set, no last_exit key) claims no crash" {
  init_sprint calc
  f=.scratch/calc/sprint-state.json
  jq '.current_run = "run-old" | del(.last_exit)' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  run state run-start --id run-new
  [ "$status" -eq 0 ]
  [[ "$output" != *"killed or crashed"* ]]
  ! grep -q 'killed or crashed' .scratch/calc/traces/orchestrator.log
  [ "$(jq -r '.previous_exit.reason' "$f")" = "unknown" ]
  [ "$(jq -r '.current_run' "$f")" = "run-new" ]
}

@test "state.sh run-start still reports a crash when last_exit names a different run" {
  init_sprint calc
  state run-start --id run-1 >/dev/null
  state run-end --reason "finished" --code 0 >/dev/null
  state run-start --id run-2 >/dev/null
  run state run-start --id run-3
  [ "$status" -eq 0 ]
  [[ "$output" == *"previous run ended without an exit (killed or crashed)"* ]]
  [ "$(jq -c '.previous_exit | [.run, .reason]' .scratch/calc/sprint-state.json)" = '["run-2","ended without an exit (killed or crashed)"]' ]
}

@test "crew-summary names the run count and why the previous run ended" {
  init_sprint calc
  state run-start --id run-1 >/dev/null
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc --no-reminder
  [[ "$output" == *"Run 1 for this feature; previous: none"* ]]
  state run-end --reason "wall-clock cap" --code 2 >/dev/null
  state run-start --id run-2 >/dev/null
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc --no-reminder
  [[ "$output" == *"Run 2 for this feature; previous: wall-clock cap"* ]]
}

@test "state.sh dispatch-cost --cost-unknown files the tokens and adds nothing to the cost total" {
  init_sprint calc
  state run-start --id r1 >/dev/null
  state dispatch-cost --cost 0.5 --duration-ms 1000 --turns 3 --slug a --role coder --attempt 1 >/dev/null
  state dispatch-cost --cost-unknown --tokens 48000 --turns 9 --slug b --role coder --attempt 1 >/dev/null
  f=.scratch/calc/sprint-state.json
  [ "$(jq -r '.total_cost_usd' "$f")" = "0.5" ]
  [ "$(jq -c '.dispatches[1] | [.slug, .cost_unknown, .tokens, .cost_usd, .turns]' "$f")" = '["b",true,48000,0,9]' ]
  [ "$(jq -c '.dispatches[0] | [.cost_unknown, .tokens]' "$f")" = '[false,null]' ]
}

@test "crew-summary appends the stopped dispatches to the Cost line, and only when there are some" {
  init_sprint calc
  state run-start --id now >/dev/null
  state dispatch-cost --cost 0.6 --duration-ms 60000 --turns 4 --slug a --role coder --attempt 1 >/dev/null
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *'feature total $0.60'* ]]
  [[ "$output" != *'cost unknown'* ]]

  state dispatch-cost --cost-unknown --tokens 900 --turns 2 --slug b --role coder --attempt 1 >/dev/null
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *'feature total $0.60 + 1 stopped dispatch, cost unknown'* ]]

  state dispatch-cost --cost-unknown --tokens 900 --slug c --role coder --attempt 1 >/dev/null
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *'feature total $0.60 + 2 stopped dispatches, cost unknown'* ]]
}

@test "state.sh baseline records one verdict per commit and rejects anything but pass or fail" {
  init_sprint calc
  state baseline --commit abc --verdict pass >/dev/null
  [ "$(jq -c '.baseline | [.commit, .verdict]' .scratch/calc/sprint-state.json)" = '["abc","pass"]' ]
  run state baseline --commit abc --verdict maybe
  [ "$status" -ne 0 ]
}

# ─── crew-summary.sh ─────────────────────────────────────────────────────────

@test "crew-summary prints this run's cost by role and retry, beside the feature total" {
  init_sprint calc
  state dispatch-cost --cost 10 --turns 100 >/dev/null   # earlier runs of the feature
  state run-start --id now >/dev/null
  state dispatch-cost --cost 0.6 --duration-ms 120000 --turns 40 --slug a --role coder --attempt 1 >/dev/null
  state dispatch-cost --cost 0.3 --duration-ms 60000 --turns 20 --slug a --role reviewer --attempt 1 >/dev/null
  state dispatch-cost --cost 0.1 --duration-ms 30000 --turns 5 --slug a --role triage --attempt 2 >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  [[ "$output" == *'Cost:   this run $1.00 · 3 dispatches · 3.5m agent time · 65 turns — feature total $11.00'* ]]
  [[ "$output" == *'by role: coder $0.60 · reviewer $0.30 · triage $0.10 · other $0.00 — first attempts $0.90 · retries $0.10'* ]]
}

@test "crew-summary counts a conflict-only dispatch's cost under coder, so the roles add up to the run total" {
  init_sprint calc
  state run-start --id now >/dev/null
  state dispatch-cost --cost 0.6 --turns 40 --slug a --role coder --attempt 1 >/dev/null
  state dispatch-cost --cost 0.2 --turns 10 --slug a --role conflict --attempt 2 >/dev/null
  state dispatch-cost --cost 0.3 --turns 20 --slug a --role reviewer --attempt 1 >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  [[ "$output" == *'Cost:   this run $1.10 · 3 dispatches'* ]]
  [[ "$output" == *'by role: coder $0.80 · reviewer $0.30 · triage $0.00'* ]]
}

@test "crew-summary puts command discovery and the PR writer under other, so the roles sum to the run total" {
  init_sprint calc
  state run-start --id now >/dev/null
  state dispatch-cost --cost 0.6 --turns 40 --slug a --role coder --attempt 1 >/dev/null
  state dispatch-cost --cost 0.05 --turns 2 --slug commands --role commandFinder --attempt 1 >/dev/null
  state dispatch-cost --cost 0.15 --turns 6 --slug pr-body --role prWriter --attempt 1 >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  [[ "$output" == *'Cost:   this run $0.80 · 3 dispatches'* ]]
  [[ "$output" == *'by role: coder $0.60 · reviewer $0.00 · triage $0.00 · other $0.20'* ]]
}

@test "crew-summary falls back to the feature total when this run has no ledger" {
  init_sprint calc
  state dispatch-cost --cost 2.5 --duration-ms 60000 --turns 7 >/dev/null
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *'Cost:   $2.50 · agent time: 1.0m across 7 turns (every run of this feature)'* ]]
}

@test "crew-summary --capped names the wall-clock cap, not blockers, as what left work undone" {
  init_sprint calc
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc --stalled --capped
  [[ "$output" == *"CAPPED: the wall-clock cap stopped new claims"* ]]
  [[ "$output" != *"STALLED:"* ]]
}

@test "state blocked records the reason for every blocked issue, branch or not" {
  init_sprint calc
  state blocked --slug r --reason "requires failed: docker not running" >/dev/null
  state blocked --slug c --branch crew/calc/c --reason "spec is ambiguous" >/dev/null
  run jq -r '.blocked_reasons.r, .blocked_reasons.c' .scratch/calc/sprint-state.json
  [ "${lines[0]}" = "requires failed: docker not running" ]
  [ "${lines[1]}" = "spec is ambiguous" ]
}

@test "crew-summary names a main-tree-dirty block as a human's job, with the files" {
  init_sprint calc
  state blocked --slug b --branch crew/calc/b --reason "main-tree-dirty — uncommitted changes in /r would be overwritten: a.ts — commit or stash them in the main checkout, then re-run" >/dev/null
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"## Feature Worktree Not Clean (need a human)"* ]]
  [[ "$output" == *"- crew/calc/b: uncommitted changes in /r would be overwritten: a.ts"* ]]
}

@test "crew-summary renders the rollup from state, not from a print template" {
  init_sprint calc
  state model sonnet >/dev/null
  state attempt --slug b --n 1 >/dev/null
  state attempt --slug b --n 2 >/dev/null
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

@test "crew-summary tells a human how to resolve a merge-failed retention by hand" {
  init_sprint calc
  state retain --slug b --branch crew/calc/b --reason "merge-failed" >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Merge Conflicts (need a human)"* ]]
  [[ "$output" == *"git worktree add /tmp/crew-resolve feature/calc && cd /tmp/crew-resolve && git merge --no-ff <branch>"* ]]
  [[ "$output" == *"- crew/calc/b"* ]]
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

@test "crew-summary names a coder that ran the full suite under Deviations" {
  init_sprint calc
  state complete --slug a --branch crew/calc/a >/dev/null
  state deviation --slug a --reason "coder ran the full test suite 2x" >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"## Deviations"* ]]
  [[ "$output" == *"a: coder ran the full test suite 2x"* ]]
}

@test "crew-summary does not count a triage-dismissed finding as needing triage" {
  init_sprint calc
  mkdir -p .scratch/calc/reviews
  write_verdict_report() {
    jq -n --argjson f "$1" '{branch: "crew/calc/a", slug: "a", verdict: "all-met", findings: $f}' > v.json
    { printf '## Branch: crew/calc/a (a)\n\n```json\n'; cat v.json; printf '\n```\n'; } > .scratch/calc/reviews/sprint-review-1.md
  }
  write_verdict_report '[{"severity":"HIGH","location":"a.py:1","criterion":"x","verdict":"dismiss","rationale":"guarded"}]'
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" != *"still need triage"* ]]
  [[ "$output" == *"1 finding(s) dismissed by triage"*"sprint-review-1.md"* ]]

  write_verdict_report '[{"severity":"HIGH","location":"a.py:1","criterion":"x","verdict":"dismiss","rationale":"guarded"},{"severity":"MEDIUM","location":"a.py:2","criterion":"y","verdict":"debatable","rationale":"api"}]'
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"1 review finding(s) still need triage (MEDIUM=1)."* ]]
  [[ "$output" == *"1 finding(s) dismissed by triage"* ]]
}

@test "crew-summary reports open findings with a real count" {
  init_sprint calc
  mkdir -p .scratch/calc/reviews
  json=$(jq -n '{
    branch: "crew/calc/a", slug: "a", verdict: "all-met",
    findings: [
      {severity: "MEDIUM", location: "a.py:1", criterion: "something worth a look"},
      {severity: "LOW", location: "a.py:2", criterion: "a nit"}
    ]
  }')
  cat > .scratch/calc/reviews/sprint-review-1.md <<EOF
## Branch: crew/calc/a (a)

\`\`\`json
$json
\`\`\`
EOF

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"## Next Step"* ]]
  [[ "$output" == *"2 review finding(s) still need triage (MEDIUM=1, LOW=1)."* ]]
  [[ "$output" == *"Run: /crew-address-findings"* ]]
  [[ "$output" != *"## Unreviewed Branches"* ]]
}

@test "crew-summary's Next Step names /address-pr-comments with the PR when the findings were posted to it" {
  init_sprint calc
  mkdir -p .scratch/calc/reviews
  json=$(jq -n '{branch: "crew/calc/a", slug: "a", verdict: "all-met",
    findings: [{severity: "MEDIUM", location: "a.py:1", criterion: "something worth a look"}]}')
  cat > .scratch/calc/reviews/sprint-review-1.md <<EOF
## Branch: crew/calc/a (a)

\`\`\`json
$json
\`\`\`
EOF

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc --posted-to https://github.com/o/r/pull/7
  [[ "$output" == *"Run: /address-pr-comments https://github.com/o/r/pull/7"* ]]
  [[ "$output" != *"Run: /crew-address-findings"* ]]
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

@test "crew-summary drops a stale not_run gap for a branch that actually merged" {
  # Merging requires an all-met review (see runHousekeeping in orchestrator/lib/pipeline.mjs)
  # — a gap left over from an earlier failed attempt on the same branch (this run's own
  # retry, or a stale report from a resumed sprint's dead prior process) must not survive
  # into the summary and contradict the Merged line by claiming the branch was "retained
  # rather than merged".
  init_sprint calc
  state complete --slug a --branch crew/calc/a >/dev/null
  mkdir -p .scratch/calc/reviews
  bash "$(installed_scripts)/promote-findings.sh" mark-not-run --feature-slug calc \
    --branch crew/calc/a --slug a --report .scratch/calc/reviews/sprint-review-1.md \
    --reason "reviewer dispatch timed out" >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"Merged  (1): a"* ]]
  [[ "$output" != *"## Unreviewed Branches"* ]]
  [[ "$output" != *"retained rather than merged"* ]]
}

@test "crew-summary's code review rollup picks up a later indented json verdict over a stale not_run stub" {
  # A captured reviewer transcript sometimes lands indented, fence lines included (e.g.
  # two extra leading spaces on every line, "  \`\`\`json" and "  \`\`\`"). JSON treats
  # whitespace between tokens as insignificant, so the rollup still folds to this later,
  # real verdict rather than reporting the earlier not_run stub.
  init_sprint calc
  mkdir -p .scratch/calc/reviews
  bash "$(installed_scripts)/promote-findings.sh" mark-not-run --feature-slug calc \
    --branch crew/calc/a --slug a --report .scratch/calc/reviews/sprint-review-1.md \
    --reason "reviewer dispatch timed out" >/dev/null
  json=$(jq -cn '{
    branch: "crew/calc/a", slug: "a", verdict: "all-met",
    findings: [{severity: "HIGH", location: "a.py:1", criterion: "something worth a look"}]
  }')
  cat >> .scratch/calc/reviews/sprint-review-1.md <<EOF

  Branch: crew/calc/a (a)
  \`\`\`json
  $json
  \`\`\`
EOF

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"Branches reviewed: 1 (all-met: 1, unmet: 0, not-reviewed: 0)"* ]]
  [[ "$output" == *"Findings: 1 total (CRITICAL: 0, HIGH: 1, MEDIUM: 0, LOW: 0)"* ]]
}

@test "crew-summary lists promoted findings with their fix issue and state" {
  init_sprint calc
  mkdir -p .scratch/calc/reviews
  cat > .scratch/calc/reviews/sprint-review-1.md <<'EOF'
## Branch: crew/calc/a (a)
- [CRITICAL] unchecked input at src/x.ts:12
EOF
  printf -- '- [ ] validate input at src/x.ts:12\n' > .scratch/calc/reviews/a.criteria.md
  bash "$(installed_scripts)/promote-findings.sh" defer --severities "actionable" --feature-slug calc \
    --branch crew/calc/a --slug a --title "Fix review findings: a" \
    --report .scratch/calc/reviews/sprint-review-1.md \
    --criteria-file .scratch/calc/reviews/a.criteria.md >/dev/null

  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"## Promoted Findings"* ]]
  [[ "$output" == *"crew/calc/a: 1 finding(s) → 02-fix-findings-a (deferred-findings)"* ]]
  # The promoted finding is not also counted as needing human triage.
  [[ "$output" == *"No open review findings."* ]]
}

@test "crew-summary renders a github fix issue as #<n> with the marker's count, offline" {
  init_sprint calc
  mkdir -p .scratch/calc/reviews
  cat > .scratch/calc/reviews/sprint-review-1.md <<'EOF'
## Branch: crew/calc/a (a)

## Promoted Findings

- crew/calc/a: actionable → https://github.com/acme/widgets/issues/42 (3 finding(s))
EOF
  # No network: a gh on PATH that fails the test if called.
  mkdir -p nogh && printf '#!/bin/sh\necho called >> "%s/gh-called"\nexit 1\n' "$PWD" > nogh/gh && chmod +x nogh/gh

  PATH="$PWD/nogh:$PATH" run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"- crew/calc/a: 3 finding(s) → #42"* ]]
  [[ "$output" != *"missing"* ]]
  [ ! -e gh-called ]
}

@test "crew-summary renders an old count-less github marker without a count, never as 0 / missing" {
  init_sprint calc
  mkdir -p .scratch/calc/reviews
  cat > .scratch/calc/reviews/sprint-review-1.md <<'EOF'
## Promoted Findings

- crew/calc/a: CRITICAL, HIGH → https://github.com/acme/widgets/issues/42
EOF
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"- crew/calc/a: findings → #42"* ]]
  [[ "$output" != *"0 finding(s)"* ]]
  [[ "$output" != *"missing"* ]]
}

@test "crew-summary still counts an old count-less local marker from the issue file" {
  init_sprint calc
  mkdir -p .scratch/calc/reviews .scratch/calc/issues/open
  printf '# Fix\n\nStatus: deferred-findings\n\n## Acceptance criteria\n\n- [ ] one\n- [ ] two\n' \
    > .scratch/calc/issues/open/05-fix-findings-a.md
  cat > .scratch/calc/reviews/sprint-review-1.md <<EOF
## Promoted Findings

- crew/calc/a: CRITICAL → $PWD/.scratch/calc/issues/open/05-fix-findings-a.md
EOF
  run bash "$(installed_scripts)/crew-summary.sh" --feature-slug calc
  [[ "$output" == *"- crew/calc/a: 2 finding(s) → 05-fix-findings-a (deferred-findings)"* ]]
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
#
# There is no prose body left to assert on. Five tests lived here — no sprint-state glob,
# `source sprint.env`, no hand-rolled trace line, cleanup's branch lists from `state.sh get`,
# and the 2,750-word budget — and each was a promise a body made about the pipeline. The
# pipeline is `orchestrator/` now, so those promises are asserted where they are kept:
#
#   - the slug is derived once by session-init.sh and read back through sprint.env by
#     orchestrator/lib/sprint.mjs, never re-globbed  → tests/orchestrator/sprint-gates-config.test.mjs
#   - every trace marker is written by the script that performs the step               → ditto
#   - cleanup's `--merged` / `--retain` lists come from `state.sh get` in
#     orchestrator/lib/loop.mjs                                                        → ditto
#   - the sprint reports once, from disk, at the end                                   → ditto
#   - the word budget is AFK_LAUNCHER_WORD_BUDGET per launcher → tests/crew-afk-launcher.bats

@test "state.sh feature-reviewed records feature_review.reviewed_tip and requires --tip" {
  init_sprint calc
  run state feature-reviewed
  [ "$status" -ne 0 ]
  state feature-reviewed --tip abc123 >/dev/null
  [ "$(jq -r .feature_review.reviewed_tip .scratch/calc/sprint-state.json)" = "abc123" ]
}

@test "state.sh feature-review-promoted counts per feature: 0 when unrecorded, kept across feature-reviewed" {
  init_sprint calc
  [ "$(state get feature-review-promotions)" = "0" ]
  state feature-reviewed --tip abc123 >/dev/null
  [ "$(state get feature-review-promotions)" = "0" ]
  run state feature-review-promoted
  [ "$status" -eq 0 ]
  [[ "$output" == *"promotions=1"* ]]
  state feature-reviewed --tip def456 >/dev/null
  state feature-review-promoted >/dev/null
  [ "$(state get feature-review-promotions)" = "2" ]
  [ "$(jq -r .feature_review.reviewed_tip .scratch/calc/sprint-state.json)" = "def456" ]
}

@test "state.sh retain --fingerprint is stored and printed by retention; absent without it" {
  init_sprint calc
  run state retain --slug first --branch crew/calc/first --reason criteria-unmet --fingerprint abc123
  [ "$status" -eq 0 ]
  run state retention --slug first
  [[ "$output" == *"reason: criteria-unmet"* ]]
  [[ "$output" == *"fingerprint: abc123"* ]]
  run state retain --slug second --branch crew/calc/second --reason criteria-unmet
  run state retention --slug second
  [[ "$output" != *fingerprint* ]]
}

@test "state.sh blocked --branch keeps --fingerprint in the retention record" {
  init_sprint calc
  state blocked --slug first --branch crew/calc/first --reason "retry limit reached" --fingerprint abc123 >/dev/null
  run state retention --slug first
  [[ "$output" == *"reason: blocked — retry limit reached"* ]]
  [[ "$output" == *"fingerprint: abc123"* ]]
}

@test "trace.sh --feature-slug from a linked worktree writes to the main checkout's log" {
  local main="$TEMP_DIR/trace-main" linked="$TEMP_DIR/trace-linked"
  git init -q -b main "$main"
  git -C "$main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$main" worktree add -q -b side "$linked"
  (cd "$linked" && env -u MAIN_ROOT -u TRACE_LOG -u CREW_ORCHESTRATED bash "$AFK_SCRIPTS/trace.sh" --feature-slug x MARK hello)
  grep -q 'MARK' "$main/.scratch/x/traces/orchestrator.log"
  [ ! -e "$linked/.scratch/x/traces/orchestrator.log" ]
}
