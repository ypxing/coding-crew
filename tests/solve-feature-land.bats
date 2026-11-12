#!/usr/bin/env bats

# solve-feature.sh land: its guards, the push and the draft PR. Setup and the stubs: helpers/solve-feature.bash.

load helpers/solve-feature

bats_require_minimum_version 1.5.0

# --- land: guards ----------------------------------------------------------------------

# stops_at <step> <reason> — land just exited 1: nothing pushed, the stop in .coding-crew/solve-feature/outcome.
stops_at() {
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: 2 $1 failed: $2"* ]] || { echo "$output"; return 1; }
  [ "$(git ls-remote origin feature/feat | cut -f1)" != "$(git rev-parse HEAD)" ] || { echo pushed; return 1; }
  [ ! -f "$STATE/pr-created" ]
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: 2 $1 failed: $2"* ]]
}

@test "land on a branch other than start's, or on a dirty tree, exits 1 with a solve stop before the checks" {
  land_ready
  git checkout -q -b elsewhere
  run bash "$SCRIPT" land feat 2 feature/feat
  stops_at solve "branch changed to 'elsewhere'"
  git checkout -q feature/feat
  echo dirt > dirt.txt
  run bash "$SCRIPT" land feat 2 feature/feat
  stops_at solve "working tree left dirty"
  [ ! -f "$STATE/checks.log" ]
  echo "blocked: the coder stopped mid-edit" > .coding-crew/solve-feature/coder.report.md
  run bash "$SCRIPT" land feat 2 feature/feat
  stops_at solve "working tree left dirty; why: $WORK/.coding-crew/solve-feature/coder.report.md"
}

@test "land goes on to the checks when the only leftover change is an untracked setup file or config.json" {
  land_ready
  git rm -q --cached .coding-crew/dev-commands.json && git commit -q -m "commands untracked"
  echo '{"test":"make check"}' > .coding-crew/dev-commands.json
  echo '{"tracker":{"kind":"github"},"x":1}' > .coding-crew/config.json
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$STATE/checks.log" ]
  [ "$(git status --porcelain -uall | sort | tr '\n' ' ')" = " M .coding-crew/config.json ?? .coding-crew/dev-commands.json " ]
}

@test "land stops 'working tree left dirty' for a modified dev commands file the branch tracks: it is the branch's to commit" {
  land_ready
  echo '{"test":"make check"}' > .coding-crew/dev-commands.json
  run bash "$SCRIPT" land feat 2 feature/feat
  stops_at solve "working tree left dirty"
}

@test "land commits the checks' rewrites as their own commit before the push, leaving config.json and an untracked dev commands file out" {
  land_ready
  local coder; coder=$(git rev-parse HEAD)
  git rm -q --cached .coding-crew/dev-commands.json && git commit -q -m "commands untracked"
  coder=$(git rev-parse HEAD)
  echo '{"test":"make check"}' > .coding-crew/dev-commands.json
  echo '{"tracker":{"kind":"github"},"x":1}' > .coding-crew/config.json
  CHECK_REWRITES=work-2.txt run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git log -1 --format=%s)" = "Apply the checks' rewrites" ]
  [ "$(git rev-parse HEAD~1)" = "$coder" ]
  [ "$(git show --name-only --format= HEAD)" = work-2.txt ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  [ "$(git status --porcelain -uall | sort | tr '\n' ' ')" = " M .coding-crew/config.json ?? .coding-crew/dev-commands.json " ]
}

@test "land whose checks leave nothing changed makes no rewrite commit" {
  land_ready
  local coder; coder=$(git rev-parse HEAD)
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD)" = "$coder" ]
}

@test "land after a coder committed [WIP] and left its issue open exits 1 'did not close' naming the coder's report, before the checks" {
  run bash "$SCRIPT" start feat
  echo "stale" > .coding-crew/solve-feature/coder.report.md
  run bash "$SCRIPT" next feat
  # solve-issue's partial: the work committed with a [WIP] marker, the tree clean, the issue not closed.
  echo half > half.txt && git add half.txt && git commit -q -m "[2][WIP] half the work"
  run bash "$SCRIPT" land feat 2 feature/feat
  stops_at solve "coder ran but did not close 2 and left no report at $WORK/.coding-crew/solve-feature/coder.report.md"
  [ ! -f "$STATE/checks.log" ]
  echo "partial: the schema test needs a fixture" > .coding-crew/solve-feature/coder.report.md
  run bash "$SCRIPT" land feat 2 feature/feat
  stops_at solve "coder ran but did not close 2; why: $WORK/.coding-crew/solve-feature/coder.report.md"
}

# --- land never finished: the coder closed the issue, nothing gated it ----------------

@test "a re-run after an interrupted land stops at next naming land instead of nothing landed; land then lets the run go on" {
  land_ready
  # The land call is killed: the issue is closed, its commit unpushed, no PR.
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" next feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"solve-feature: 2 land failed: 2 is done but its land never finished: if its coder finished it, run land feat 2 feature/feat; otherwise reopen 2; then re-run"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"nothing landed"* ]]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: 2 land failed: 2 is done but its land never finished: if its coder finished it, run land feat 2 feature/feat; otherwise reopen 2; then re-run" ]
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = pr=10 ]
  run bash "$SCRIPT" next feat
  [ "$output" = 3 ]
}

@test "with a PR open, a re-run after a later issue's interrupted land names that land too, not the review" {
  land_ready
  run bash "$SCRIPT" land feat 2 feature/feat; [ "${lines[0]}" = pr=10 ]
  run bash "$SCRIPT" next feat; [ "$output" = 3 ]
  coder 3
  run bash "$SCRIPT" next feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"solve-feature: 3 land failed: 3 is done but its land never finished: if its coder finished it, run land feat 3 feature/feat; otherwise reopen 3; then re-run"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *reviewer-model=* ]]
  run bash "$SCRIPT" land feat 3 feature/feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [ "$output" = "$(printf 'red-files=\nreviewer-model=\nreview-base=')" ]
}

@test "a re-run on another branch after an interrupted land names the branch the coder worked on, not the current one" {
  run bash "$SCRIPT" start feat --branch task/feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  coder 2
  # Resumed without --branch: start checks out feature/feat, which lacks the coder's commit.
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" next feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 is done but its land never finished: if its coder finished it, check out task/feat and run land feat 2 task/feat; otherwise reopen 2; then re-run with --branch task/feat"* ]] || { echo "$output"; return 1; }
}

@test "a re-run whose interrupted land's issue no longer exists forgets it and hands out the next ready issue" {
  land_ready
  # Issue 2 deleted (local: its file renamed) after its coder closed it; 3 is ready.
  jq 'map(select(.number != 2))' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  run bash "$SCRIPT" next feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = 3 ]
}

@test "a re-run after a land stop that left the issue open hands the same issue out again" {
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  echo half > half.txt && git add half.txt && git commit -q -m "[2][WIP] half the work"
  run bash "$SCRIPT" land feat 2 feature/feat; [ "$status" -eq 1 ]
  run bash "$SCRIPT" next feat
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
  # A land checks stop reopens the issue: the re-run hands it out again too.
  coder 2
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat; [ "$status" -eq 1 ]
  run bash "$SCRIPT" next feat
  [ "$output" = 2 ]
}

@test "an interrupted land with no dev commands file names /setup-coding-crew before the land" {
  # Pushed too: start branches from origin's default branch.
  git rm -q .coding-crew/dev-commands.json && git commit -q -m "no commands" && git push -q origin HEAD
  land_ready
  run bash "$SCRIPT" next feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"2 is done but its land never finished and no check commands are known: if its coder finished it, run /setup-coding-crew, then land feat 2 feature/feat; otherwise reopen 2; then re-run"* ]] || { echo "$output"; return 1; }
}

@test "another feature's run in the same checkout is not stopped by this feature's interrupted land" {
  land_ready
  # A second feature with no ready issue: its own nothing-landed, not this feature's land.
  run bash "$SCRIPT" next other
  [ "$status" -eq 3 ]
  [[ "$output" == *"nothing landed: no ready issue for other"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"land failed"* ]]
  # This feature's own re-run still names its land.
  run bash "$SCRIPT" next feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"run land feat 2 feature/feat"* ]] || { echo "$output"; return 1; }
}

@test "after a 'did not close' stop, an issue a person took out of ready is not claimed closed by its coder" {
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  echo half > half.txt && git add half.txt && git commit -q -m "[2][WIP] blocked"
  run bash "$SCRIPT" land feat 2 feature/feat; [ "$status" -eq 1 ]
  jq 'map(if .number == 2 then .labels = [] else . end)' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  run bash "$SCRIPT" next feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = 3 ]
}

@test "a coder killed before closing its issue, which then drops out of ready, is no land to finish: next goes on" {
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  jq 'map(if .number == 2 then .labels = [] else . end)' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" next feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = 3 ]
}

@test "an issue a checks stop reopened, then a person took out of ready, is no land to finish either" {
  land_ready
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat; [ "$status" -eq 1 ]
  jq 'map(if .number == 2 then .labels = [] else . end)' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  run bash "$SCRIPT" next feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = 3 ]
}

# handed_back <reason> — land just stopped at checks with the issue reopened and its work on origin, no PR opened.
handed_back() {
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: 2 checks failed: $1; 2 is ready again with its work pushed to feature/feat: "* ]] || { echo "$output"; return 1; }
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  [ ! -f "$STATE/pr-created" ]
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: 2 checks failed: $1; 2 is ready again"* ]]
  [ "$(node "$LIB/tracker/cli.mjs" next --feature-slug feat)" = 2 ]
}

@test "land runs run-checks.sh once; exit 1 or 3 reopens the issue and pushes its work before stopping at checks, 3 sending the user to /setup-coding-crew" {
  land_ready
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  handed_back "run-checks.sh exit 1"
  [[ "$output" == *"fix the cause, then re-run — log: $WORK/.coding-crew/solve-feature/2.checks.log"* ]]
  [ "$(cat "$STATE/checks.log")" = "--project-root $WORK" ]
  [ "$(git log -1 --format=%s)" = "[2] work" ]
  coder 2
  CHECKS_RC=3 run bash "$SCRIPT" land feat 2 feature/feat
  handed_back "no check commands known (DISCOVER): the coder discovered none"
  [[ "$output" == *"run /setup-coding-crew, then re-run"* ]]
  [[ "$output" != *commit* ]]
}

@test "a re-run after a checks stop hands the reopened issue to a coder on the pushed work, in a fresh clone too" {
  land_ready
  local tip; tip=$(git rev-parse HEAD)
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  # An Actions re-run: a new clone of origin, on its default branch.
  cd "$TEMP_DIR" && git clone -q "$TEMP_DIR/origin.git" rerun && cd rerun
  git config user.email t@example.com && git config user.name test
  loop
  [ "$CODED" = "2 3" ]
  git merge-base --is-ancestor "$tip" HEAD
  [ "$(git branch --show-current)" = feature/feat ]
}

@test "a reopen that changes a tracked file is committed alone, what the failed checks left discarded; a failed discard is noted and still hands back; a reopen that fails stops naming land, nothing pushed" {
  land_ready
  echo '{"tracker":{"kind":"github"},"x":1}' > .coding-crew/config.json
  # What a failed check left (a file it made, a rewrite, staged or not): never committed, and gone so a re-run starts on a clean tree.
  CHECK_LEAVES="$WORK/artefact.out" CHECK_REWRITES=work-2.txt CHECK_STAGES="artefact.out work-2.txt" REOPEN_TOUCHES="$WORK/issue-state.md" CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  [ "$(git log -1 --format=%s)" = "Reopen 2: its checks failed" ]
  [ "$(git show --name-only --format= HEAD)" = issue-state.md ]
  [ "$(git status --porcelain)" = " M .coding-crew/config.json" ]
  [ "$(sed -n '/discarded what the failed checks left/,$p' .coding-crew/solve-feature/2.checks.log | tail -n +2 | sort | tr '\n' ' ')" = "artefact.out work-2.txt " ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  git checkout -q -- .coding-crew/config.json

  coder 2
  # A discard that fails is noted in the log; the issue is still handed back.
  printf '#!/usr/bin/env bash\nif [ "$1" = clean ]; then echo "fatal: no" >&2; exit 1; fi\nexec "%s" "$@"\n' "$(command -v git)" > "$STUB/git"
  chmod +x "$STUB/git"
  CHECK_LEAVES="$WORK/artefact.out" CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  handed_back "run-checks.sh exit 1"
  grep -qx "solve-feature: discarding them failed (see above): clean the tree by hand before a re-run" .coding-crew/solve-feature/2.checks.log
  rm "$STUB/git" artefact.out

  coder 2
  REOPEN_RC=1 CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  stops_at checks "run-checks.sh exit 1; reopen 2 failed (see above): once fixed and committed, run land feat 2 feature/feat before a re-run"
}

@test "a checks stop whose push is refused quotes git's reason" {
  land_ready
  refuse_pushes
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  stops_at checks "run-checks.sh exit 1; 2 is ready again but git push failed: pre-receive hook declined; once it can push, fix the cause, then re-run"
}

# --- land: push and PR -----------------------------------------------------------------

@test "the first land pushes and creates the draft PR with a one-line body; a later land edits nothing and no land comments" {
  land_ready
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = pr=10 ]
  [ "$(git rev-parse origin/feature/feat)" = "$(git rev-parse feature/feat)" ]
  grep -qx -- --draft "$STATE/pr-create.1"
  [ "$(cat "$STATE/pr-title")" = Feat ]
  [ "$(body_of pr-create.1)" = "$(cat <<'EOF'
<!-- solve-feature:begin -->
Implemented by solve-feature (`feat`) — in progress.
<!-- solve-feature:slug feat -->
<!-- solve-feature:end -->
EOF
)" ]
  run bash "$SCRIPT" next feat
  coder 3
  run bash "$SCRIPT" land feat 3 feature/feat
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = pr=10 ]
  [ ! -f "$STATE/pr-create.2" ]
  ! grep -qE '^pr (edit|ready|comment)|^api' "$STATE/gh.log" || false
  [ "$(git rev-parse origin/feature/feat)" = "$(git rev-parse feature/feat)" ]
}

@test "an existing open PR is reused as it is: no create, no edit, and only start's conversion to a draft" {
  export PR_EXISTS=1 PR_DRAFT=false
  loop
  [ "$LAST_PR" = 9 ]
  [ ! -f "$STATE/pr-created" ]
  ! grep -qE '^pr (create|edit)' "$STATE/gh.log" || false
  [ "$(grep '^pr ready' "$STATE/gh.log")" = "pr ready 9 --undo" ]
  [ "$(cat "$STATE/pr-body")" = "hand intro" ]
}

@test "a one-slice feature's root is its work issue: it runs, and the PR is titled after the PRD" {
  issues '[{"number":1,"title":"Feat alone","state":"OPEN","labels":[{"name":"ready-for-agent"}],"root":true}]'
  issue_body 1 "Feat alone" "None"
  loop
  [ "$CODED" = 1 ]
  [ "$(cat "$STATE/pr-title")" = Feat ]
}

@test "a feature whose prd exits 3 titles the PR after the first landed issue" {
  rm "$STATE/prd.md"
  loop
  [ "$(cat "$STATE/pr-title")" = Two ]
}

@test "a local tracker: path refs, saved by next before the close moves the file, land from the saved copy" {
  export TRACKER_KIND=local
  issues '[{"number":1,"ref":".coding-crew/scratch/feat/issues/open/01-a.md","title":"A","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":2,"ref":".coding-crew/scratch/feat/issues/open/02-b.md","title":"B","state":"OPEN","labels":[{"name":"ready-for-agent"}]}]'
  issue_body .coding-crew/scratch/feat/issues/open/01-a.md "Local A" None
  issue_body .coding-crew/scratch/feat/issues/open/02-b.md "Local B" None
  printf '# PRD\n\nlocal prd without a title note\n' > "$STATE/prd.md"
  run bash "$SCRIPT" start feat
  grep -qx '### 01-a — Local A' .coding-crew/solve-feature/spec.md
  run bash "$SCRIPT" next feat
  [ "$output" = .coding-crew/scratch/feat/issues/open/01-a.md ]
  coder .coding-crew/scratch/feat/issues/open/01-a.md
  rm "$STATE/.coding-crew_scratch_feat_issues_open_01-a.md.md" # the close moved it: fetch now exits 3
  run bash "$SCRIPT" land feat .coding-crew/scratch/feat/issues/open/01-a.md feature/feat
  [ "$status" -eq 0 ]
  [ -f "$WORK/.coding-crew/solve-feature/.coding-crew_scratch_feat_issues_open_01-a.md.checks.log" ]
  [ "$(cat "$STATE/pr-title")" = "Local A" ]
  ! grep -q '^config' "$STATE/node.log" || false
}

@test "start, next and land reach the tracker through features, spec, next, fetch, status and reopen only, and name no tracker kind" {
  loop
  [ "$(cut -d' ' -f1 "$STATE/node.log" | sort -u | paste -sd' ' -)" = "features fetch next spec" ]
  grep -q '"$CLI" reopen' "$SCRIPT"
  grep -q '"$CLI" status' "$SCRIPT"
  ! grep -nE 'KIND|github|scratch|"\$CLI" config|\$REF" =~' "$SCRIPT" || false
}

@test "land, sync and fix each gate once, and only the gate merges origin's branch, runs the checks, commits their rewrites and pushes the branch" {
  local f
  for f in land sync fix; do
    [ "$(sed -n "/^$f() {/,/^}/p" "$SCRIPT" | grep -cE '^[[:space:]]*gate ')" = 1 ] || { echo "$f does not call gate once"; return 1; }
  done
  [ "$(grep -c 'run-checks.sh" --project-root' "$SCRIPT")" = 1 ]
  [ "$(grep -cE '(^|[^_])commit_rewrites( |$)' "$SCRIPT")" = 2 ]
  [ "$(grep -c 'merge_in "origin/\$BRANCH"' "$SCRIPT")" = 1 ]
  [ "$(grep -c 'push -u origin "\$BRANCH" ||' "$SCRIPT")" = 4 ]
  sed -n '/^gate() {/,/^}/p' "$SCRIPT" | grep -q 'run-checks.sh'
}

@test "a refused land push reopens the issue, quotes git's reason and sends the user to re-run where git can push, not to land" {
  land_ready
  refuse_pushes
  run bash "$SCRIPT" land feat 2 feature/feat
  stops_at push "git push failed: pre-receive hook declined; 2 is ready again: re-run where git can push (a re-run in this checkout starts from its unpushed commits)"
  [[ "$output" != *"run land"* ]]
  ! grep -q 'run land' .coding-crew/solve-feature/outcome || false
  [ "$(node "$LIB/tracker/cli.mjs" next --feature-slug feat)" = 2 ]
  # git's own stderr still reaches the terminal.
  [[ "$output" == *"! [remote rejected] feature/feat -> feature/feat (pre-receive hook declined)"* ]]
}

@test "with a file tracker, a refused land push commits the reopen's file move on the branch, unpushed, after the coder's commit" {
  land_ready
  local coded; coded=$(git rev-parse HEAD)
  refuse_pushes
  REOPEN_TOUCHES="$WORK/issue-state.md" run bash "$SCRIPT" land feat 2 feature/feat
  stops_at push "git push failed: pre-receive hook declined; 2 is ready again"
  [ "$(git log -1 --format=%s)" = "Reopen 2: its push failed" ]
  [ "$(git show --name-only --format= HEAD)" = issue-state.md ]
  [ "$(git rev-parse HEAD~1)" = "$coded" ]
  [ -z "$(git status --porcelain)" ]
}

@test "a refused land push whose reopen fails names both failures and says to reopen the ref by hand before a re-run" {
  land_ready
  refuse_pushes
  REOPEN_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  stops_at push "git push failed: pre-receive hook declined; reopen 2 failed (see above): reopen 2 by hand, then re-run where git can push"
}

# pr_stopped <reason> — land just stopped at pr with the issue ready again; no PR opened.
pr_stopped() {
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: 2 pr failed: $1"* ]] || { echo "$output"; return 1; }
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: 2 pr failed: $1"* ]]
  [[ "$output" != *"run land"* ]]
  ! grep -q 'run land' .coding-crew/solve-feature/outcome || false
  [ ! -f "$STATE/pr-created" ]
  [ "$(node "$LIB/tracker/cli.mjs" next --feature-slug feat)" = 2 ]
}

@test "a failed gh pr create reopens the issue, quotes gh's reason, points at the guide's Actions section and sends the user to re-run" {
  land_ready
  local reason="GraphQL: GitHub Actions is not permitted to create or approve pull requests (createPullRequest)"
  GH_CREATE_FAIL="$reason" run bash "$SCRIPT" land feat 2 feature/feat
  local tail="2 is ready again with its work pushed to feature/feat: fix the cause (on GitHub Actions, the setting coding-crew's guide names under \"solve-feature on GitHub Actions\"), then re-run"
  pr_stopped "gh pr create failed: $reason; $tail"
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: 2 pr failed: gh pr create failed: $reason; $tail" ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  # gh's own stderr still reaches the terminal.
  [[ "$output" == *"pull request create failed"* ]]

  coder 2
  GH_CREATE_FAIL=silent run bash "$SCRIPT" land feat 2 feature/feat
  pr_stopped "gh pr create failed; 2 is ready again with its work pushed"
}

@test "with a file tracker, a failed gh pr create commits the reopen's file move and pushes it; a refused push there quotes git's reason" {
  land_ready
  local coded; coded=$(git rev-parse HEAD)
  REOPEN_TOUCHES="$WORK/issue-state.md" GH_CREATE_FAIL=boom run bash "$SCRIPT" land feat 2 feature/feat
  pr_stopped "gh pr create failed: boom; 2 is ready again with its work pushed"
  [ "$(git log -1 --format=%s)" = "Reopen 2: its PR creation failed" ]
  [ "$(git show --name-only --format= HEAD)" = issue-state.md ]
  [ "$(git rev-parse HEAD~1)" = "$coded" ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  [ -z "$(git status --porcelain)" ]

  rm issue-state.md && git commit -qam "drop state"
  coder 2
  GH_CREATE_HOOK="$TEMP_DIR/origin.git/hooks/pre-receive" REOPEN_TOUCHES="$WORK/issue-state.md" GH_CREATE_FAIL=boom \
    run bash "$SCRIPT" land feat 2 feature/feat
  pr_stopped "gh pr create failed: boom; 2 is ready again but git push failed: pre-receive hook declined; once it can push, fix the cause"
  [[ "$output" == *"then re-run"* ]]
  [ "$(git ls-remote origin feature/feat | cut -f1)" != "$(git rev-parse HEAD)" ]
}

@test "a re-run after a failed gh pr create lands the issue once gh can create the PR" {
  land_ready
  GH_CREATE_FAIL=boom run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" next feat
  [ "$output" = 2 ]
  coder 2
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = pr=10 ]
}

@test "land merges a commit others pushed to the branch before its checks, then pushes; nothing new makes no merge commit" {
  land_ready
  local bot; bot=$(branch_moves bot.txt "lint fix")
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out pr)" = 10 ]
  git merge-base --is-ancestor "$bot" HEAD
  [ "$(cat "$STATE/checks.head")" = "$(git rev-parse HEAD)" ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  local merges; merges=$(git rev-list --merges --count HEAD)
  run bash "$SCRIPT" next feat
  coder 3
  run bash "$SCRIPT" land feat 3 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-list --merges --count HEAD)" = "$merges" ]
}

@test "a loop with nothing pushed by others makes no merge commit in land or fix" {
  fix_ready
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-list --merges --count HEAD)" = 0 ]
}

@test "land whose merge of origin's branch conflicts aborts it, reopens the issue, pushes nothing and says how to recover" {
  land_ready
  local coded; coded=$(git rev-parse HEAD)
  branch_moves work-2.txt "the bot's version" >/dev/null
  REOPEN_TOUCHES="$WORK/issue-state.md" run bash "$SCRIPT" land feat 2 feature/feat
  local why="merging origin/feature/feat into feature/feat conflicts in work-2.txt; 2 is ready again: re-run in a fresh clone, which redoes it on origin's branch, or merge it by hand in this checkout, commit, then re-run"
  stops_at merge "$why"
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: 2 merge failed: $why" ]
  [ ! -f "$STATE/checks.log" ]
  [ -z "$(git status --porcelain)" ]
  [ "$(git log -1 --format=%s)" = "Reopen 2: its merge failed" ]
  [ "$(git rev-parse HEAD~1)" = "$coded" ]
  [ "$(node "$LIB/tracker/cli.mjs" next --feature-slug feat)" = 2 ]
}

@test "land's merge conflict with no file move leaves HEAD at the coder's commit; a failed reopen names both failures" {
  land_ready
  local coded; coded=$(git rev-parse HEAD)
  branch_moves work-2.txt "the bot's version" >/dev/null
  REOPEN_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  stops_at merge "merging origin/feature/feat into feature/feat conflicts in work-2.txt; reopen 2 failed (see above): reopen 2 by hand, then re-run in a fresh clone"
  [ "$(git rev-parse HEAD)" = "$coded" ]
  [ -z "$(git status --porcelain)" ]
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$(git rev-parse HEAD)" = "$coded" ]
}

@test "a failed fetch does not stop land on its own: with pushes refused too it reopens the issue and stops at push quoting git's reason" {
  land_ready
  git remote set-url origin "$TEMP_DIR/gone.git"
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: 2 push failed: git push failed: fatal: Could not read from remote repository.; 2 is ready again"* ]] || { echo "$output"; return 1; }
  [ -f "$STATE/checks.log" ]
  [ "$(node "$LIB/tracker/cli.mjs" next --feature-slug feat)" = 2 ]
}

@test "land with the checks library missing exits 1 naming it, before the checks" {
  land_ready
  rm -rf "$LIB/checks"
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"checks library not found"* ]]
  [ ! -f "$STATE/checks.log" ]
  grep -q 'checks library not found' .coding-crew/solve-feature/outcome
}

# --- land: the coder's notes for a person (the run file: solve-feature-notes.bats) ---------

notes() { printf '%s\n' "- tag a release once this merges" "" "- set the CREW_X repo variable" > .coding-crew/solve-feature/coder.notes.md; }

@test "next deletes a leftover coder.notes.md, so an earlier coder's notes never post under the next issue" {
  run bash "$SCRIPT" start feat
  notes
  run bash "$SCRIPT" next feat
  [ "$output" = 2 ]
  [ ! -e .coding-crew/solve-feature/coder.notes.md ]
}

# --- land and next: next's work done in land, sync's in next's exit 3 ----------------------

@test "land prints pr= then next=<ref> when an issue is ready, and next's exit-3 lines plus next-exit=3 when none is, exiting 0" {
  land_ready
  run --separate-stderr bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  [ "$output" = "$(printf 'pr=10\nnext=3')" ]
  # next's own work: the handed-out issue saved for its land.
  [ -s .coding-crew/solve-feature/3.issue.md ]
  coder 3
  run --separate-stderr bash "$SCRIPT" land feat 3 feature/feat
  [ "$status" -eq 0 ] || { echo "$output $stderr"; return 1; }
  [ "$output" = "$(printf 'pr=10\nred-files=\nreviewer-model=\nreview-base=\nnext-exit=3')" ]
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
}

@test "next's exit 3 with an open PR merges the default branch as sync does and prints red-files=, reviewer-model= and review-base=" {
  loop
  main_moves fix.txt "a fix on main" && git checkout -q feature/feat
  run --separate-stderr bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [ "$output" = "$(printf 'red-files=\nreviewer-model=\nreview-base=')" ]
  git merge-base --is-ancestor origin/main HEAD
  [ "$(cat "$STATE/checks.head")" = "$(git rev-parse HEAD)" ]
  pushed
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
}

# conflicting_main — the branch and origin's main both change shared.txt.
conflicting_main() {
  echo mine > shared.txt && git add shared.txt && git commit -q -m "branch's shared"
  main_moves shared.txt "main's version" && git checkout -q feature/feat
}
sync_conflict="stopped: sync failed: merging origin/main into feature/feat conflicts in shared.txt: the resolver did not finish it; finish it (resolve, git add, git commit --no-edit) or undo it with git merge --abort, then re-run"

@test "next's exit 3 whose merge conflicts exits 4 printing conflicts= with sync's outcome and the merge in progress" {
  loop
  conflicting_main
  run --separate-stderr bash "$SCRIPT" next feat
  [ "$status" -eq 4 ]
  [ "$(tail -1 <<<"$output")" = "conflicts=shared.txt" ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "$sync_conflict" ]
  git rev-parse -q --verify MERGE_HEAD >/dev/null
}

@test "land whose embedded sync conflicts exits 4 printing conflicts=, with sync's outcome" {
  land_ready
  run bash "$SCRIPT" land feat 2 feature/feat; [ "$status" -eq 0 ]
  conflicting_main
  coder 3
  run --separate-stderr bash "$SCRIPT" land feat 3 feature/feat
  [ "$status" -eq 4 ] || { echo "$output $stderr"; return 1; }
  [ "$(head -1 <<<"$output")" = pr=10 ]
  [ "$(tail -1 <<<"$output")" = "conflicts=shared.txt" ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "$sync_conflict" ]
}

@test "land whose embedded next fails exits 1 with the stop message and outcome next alone gives" {
  land_ready
  rm "$STATE/3.md"
  run --separate-stderr bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  local said="$stderr" ended; ended=$(cat .coding-crew/solve-feature/outcome)
  [ "$ended" = "stopped: next failed: fetch 3 failed (see above)" ] || { echo "$ended"; return 1; }
  run --separate-stderr bash "$SCRIPT" next feat
  [ "$status" -eq 1 ]
  [[ "$said" == *"$stderr" ]] || { echo "$said"; return 1; }
  [ "$(cat .coding-crew/solve-feature/outcome)" = "$ended" ]
}
