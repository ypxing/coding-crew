#!/usr/bin/env bats

# solve-feature.sh fix: gating, committing and pushing what the review's fixer left. Setup and the stubs:
# helpers/solve-feature.bash.

load helpers/solve-feature

# --- fix: after the review -------------------------------------------------------------

# fix_stops <reason> — exit 1, nothing pushed, the stop in .coding-crew/solve-feature/outcome, the PR left as it was.
fix_stops() {
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: review fix failed: $1"* ]] || { echo "$output"; return 1; }
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$TIP" ] || { echo pushed; return 1; }
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: review fix failed: $1"* ]]
  ! grep -qE '^pr (ready|edit)' "$STATE/gh.log" || false
}

@test "fix on another branch, or with a missing or unreadable report, stops before the checks" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  local checks; checks=$(wc -l < "$STATE/checks.log")
  git checkout -q -b elsewhere
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "branch changed to 'elsewhere'"
  git checkout -q feature/feat
  rm .coding-crew/solve-feature/pr-10.review.json
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "no review report at $WORK/.coding-crew/solve-feature/pr-10.review.json"
  report 'not json'
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "unreadable review report $WORK/.coding-crew/solve-feature/pr-10.review.json"
  [ "$(wc -l < "$STATE/checks.log")" -eq "$checks" ]
  [ "$(cat fixed.txt)" = fixed ]
}

@test "a report whose gaps is not a list stops fix before the checks" {
  fix_ready '{"spec":"met","gaps":"no logout endpoint","findings":[]}'
  TIP=$(git rev-parse HEAD)
  local checks; checks=$(wc -l < "$STATE/checks.log")
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "the review report's gaps is not a list: $WORK/.coding-crew/solve-feature/pr-10.review.json"
  [ "$(wc -l < "$STATE/checks.log")" -eq "$checks" ]
}

@test "fix with failing checks stops naming the log, keeping the fixer's commit and discarding what the checks left, or with none known sends the user to /setup-coding-crew; a second fix once committed completes" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  : > "$STATE/checks.log"
  CHECK_LEAVES="$WORK/artefact.out" CHECK_REWRITES=fixed.txt CHECKS_RC=1 run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "run-checks.sh exit 1; once fixed and committed, run fix feat 10 feature/feat, then describe feat 10"
  [[ "$output" == *"log: $WORK/.coding-crew/solve-feature/pr-10.checks.log"* ]]
  [ "$(cat "$STATE/checks.log")" = "--project-root $WORK" ]
  # The fixer's edits stay in one local, unpushed commit.
  [ "$(git rev-parse HEAD~1)" = "$TIP" ]
  [ "$(git log -1 --format=%s)" = "Fix the review's findings on PR #10" ]
  [ "$(git show --name-only --format= HEAD)" = fixed.txt ]
  [ -z "$(git status --porcelain)" ]
  CHECKS_RC=3 run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "no check commands known (DISCOVER): run /setup-coding-crew, then re-run"

  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pushed
  [ "$(git rev-parse HEAD~1)" = "$TIP" ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=0 review-again=yes" ]
}

@test "the checks run with the fixer's edits committed and the tree clean, so what they leave is only their own rewrites" {
  fix_ready
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  [ -z "$(cat "$STATE/checks.status")" ]
  [ "$(cat "$STATE/checks.head")" = "$(git rev-parse HEAD)" ]
  [ "$(git show --name-only --format= HEAD)" = fixed.txt ]
}

@test "fix commits the checks' rewrites apart from the fixer's commit, before the push" {
  fix_ready
  local tip; tip=$(git rev-parse HEAD)
  CHECK_REWRITES=work-2.txt run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pushed
  [ "$(git log -1 --format=%s)" = "Apply the checks' rewrites" ]
  [ "$(git show --name-only --format= HEAD)" = work-2.txt ]
  [ "$(git log -1 --format=%s HEAD~1)" = "Fix the review's findings on PR #10" ]
  [ "$(git rev-parse HEAD~2)" = "$tip" ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=0 review-again=yes" ]
}

@test "a fixer that changed nothing is still flagged when only the checks' rewrites were committed" {
  fix_ready
  rm fixed.txt
  CHECK_REWRITES=work-2.txt run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git log -1 --format=%s)" = "Apply the checks' rewrites" ]
  [ "$(attention)" = '{"type":"fixer_changed_nothing","round":0}' ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=1 review-again=no" ]
}

@test "a rejected push stops fix quoting git's reason and naming the recovery" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  refuse_pushes
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "git push failed: pre-receive hook declined; once it can push, or once you have pushed it, run fix feat 10 feature/feat, then describe feat 10"
}

@test "fix merges a commit others pushed during the review after committing the fixer's edits and before its checks, then pushes" {
  fix_ready
  local tip bot; tip=$(git rev-parse HEAD); bot=$(branch_moves bot.txt "lint fix")
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=0 review-again=yes" ]
  git merge-base --is-ancestor "$bot" HEAD
  [ "$(git log -1 --format=%s HEAD^1)" = "Fix the review's findings on PR #10" ]
  [ "$(git rev-parse HEAD^1~1)" = "$tip" ]
  [ "$(cat "$STATE/checks.head")" = "$(git rev-parse HEAD)" ]
  pushed
}

@test "a fixer that changed nothing is flagged when others pushed to the branch, before the round's head was recorded or after" {
  fix_ready
  rm fixed.txt
  branch_moves bot.txt "after" >/dev/null
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = '{"type":"fixer_changed_nothing","round":0}' ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=1 review-again=no" ]
  pushed
  # The bot pushes before fix records the round's head, which is then the bot's commit.
  rereview
  PR_HEAD_OID=$(branch_moves bot2.txt "before") run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = '{"type":"fixer_changed_nothing","round":1}' ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=1 review-again=no" ]
  pushed
}

@test "a fixer that changed nothing is still flagged on a re-run after fix merged others' commits and then stopped" {
  fix_ready
  rm fixed.txt
  branch_moves bot.txt "lint fix" >/dev/null
  CHECKS_RC=1 run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = '{"type":"fixer_changed_nothing","round":0}' ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=1 review-again=no" ]
}

@test "fix whose merge of origin's branch conflicts aborts it, pushes nothing and says how to recover" {
  fix_ready
  local tip; tip=$(git rev-parse HEAD)
  TIP=$(branch_moves fixed.txt "the bot's version")
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "merging origin/feature/feat into feature/feat conflicts in fixed.txt; merge it by hand in this checkout, commit, then run fix feat 10 feature/feat, then describe feat 10; or re-run in a fresh clone"
  [ -z "$(git status --porcelain)" ]
  [ "$(git log -1 --format=%s)" = "Fix the review's findings on PR #10" ]
  [ "$(git rev-parse HEAD~1)" = "$tip" ]
}

@test "a failed fetch does not stop fix on its own: with pushes refused too it stops at its push" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  git remote set-url origin "$TEMP_DIR/gone.git"
  run bash "$SCRIPT" fix feat 10 feature/feat
  git remote set-url origin "$TEMP_DIR/origin.git"
  fix_stops "git push failed: fatal: Could not read from remote repository.; once it can push"
}

# push_says <stderr> — a git whose push prints <stderr> and fails; every other git command is the real one.
push_says() {
  local real; real=$(command -v git)
  printf '#!/usr/bin/env bash\nif [ "$1" = push ]; then printf "%%s\\n" "$PUSH_SAYS" >&2; exit 1; fi\nexec "%s" "$@"\n' "$real" > "$STUB/git"
  chmod +x "$STUB/git"
  export PUSH_SAYS="$1"
}

@test "a push stop quotes the ! [rejected] line's reason, else git's last fatal:/error: line, else its last non-empty line" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  push_says "$(printf 'To github.com:o/r.git\n ! [rejected]        feature/feat -> feature/feat (fetch first)\nerror: failed to push some refs\nhint: pull first')"
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "git push failed: fetch first; once it can push"
  push_says "$(printf "fatal: unable to access 'x': Could not resolve host\nfatal: Could not read from remote repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n")"
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "git push failed: fatal: Could not read from remote repository.; once it can push"
  push_says "$(printf 'something odd\nthe last word\n\n')"
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "git push failed: the last word; once it can push"
}

@test "a fix re-run after its push failed and the branch was pushed by hand compares with the head fix first saw" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  refuse_pushes
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "git push failed: pre-receive hook declined"
  [ "$(head -n1 .coding-crew/solve-feature/pr-10.head)" = "$TIP" ]
  rm "$TEMP_DIR/origin.git/hooks/pre-receive"
  git push -q origin feature/feat
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$(attention)" ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=0 review-again=yes" ]
  [ ! -e .coding-crew/solve-feature/pr-10.head ]
}

@test "a fix pushed by hand after fix stopped still counts as the fixer's after a later run stops again" {
  fix_ready
  CHECKS_RC=1 run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -ne 0 ]
  git push -q origin feature/feat
  CHECKS_RC=1 run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -ne 0 ]
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$(attention)" ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=0 review-again=yes" ]
}

@test "a second review round compares with its own head: a round-2 fixer that changed nothing is flagged" {
  fix_ready
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=0 review-again=yes" ]
  [ ! -e .coding-crew/solve-feature/pr-10.head ]
  rereview
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = '{"type":"fixer_changed_nothing","round":1}' ]
}

@test "a fixer that changed nothing fixed nothing: the findings need attention" {
  fix_ready
  rm fixed.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = '{"type":"fixer_changed_nothing","round":0}' ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=1 review-again=no" ]
  # A fixer that said why it changed nothing is listed for what it said, not twice; so is one whose file is off its
  # shape, kept whole as one item. A fixer that wrote an empty list claims every fix it never made.
  echo '[{"finding": 0, "why": "needs a design call"}, {"why": "too"}]' > .coding-crew/solve-feature/pr-10.unfixed.json
  rereview
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$(attention)" = "$(printf '%s\n' '{"type":"unfixed","round":1,"finding":0,"severity":"HIGH","why":"needs a design call"}' \
    '{"type":"unfixed","round":1,"severity":null,"why":"too"}')" ]
  printf -- '- a:1 needs a design call\n' > .coding-crew/solve-feature/pr-10.unfixed.json
  rereview
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$(attention)" = '{"type":"unfixed","round":2,"severity":null,"why":"- a:1 needs a design call\n"}' ]
  echo '[]' > .coding-crew/solve-feature/pr-10.unfixed.json
  rereview
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$(attention)" = '{"type":"fixer_changed_nothing","round":3}' ]
}

@test "fix commits a dirty tree as one commit and pushes it, never marks the PR ready, and writes no stopped or reviewed file" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  echo more > more.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD~1)" = "$TIP" ]
  [ "$(git diff --name-only HEAD~1 HEAD | sort | tr '\n' ' ')" = "fixed.txt more.txt " ]
  [ -z "$(git status --porcelain)" ]
  pushed
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=0 review-again=yes" ]
  [ "$(cat .coding-crew/solve-feature/pr-10.attention.json)" = '[]' ]
  [ -z "$(attention)" ]
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ ! -e .coding-crew/solve-feature/stopped ]
  [ ! -e .coding-crew/solve-feature/reviewed ]
  [ ! -e .coding-crew/solve-feature/outcome ]
}

@test "fix leaves config.json and an untracked dev commands file out of its commit and stages every other change" {
  fix_ready
  git rm -q --cached .coding-crew/config.json .coding-crew/dev-commands.json && git commit -q -m "setup untracked"
  echo '{"test":"make check"}' > .coding-crew/dev-commands.json
  echo more > more.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git diff --name-only HEAD~1 HEAD | sort | tr '\n' ' ')" = "fixed.txt more.txt " ]
  [ "$(git status --porcelain -uall | sort | tr '\n' ' ')" = "?? .coding-crew/config.json ?? .coding-crew/dev-commands.json " ]
}

@test "fix commits a dev commands file the branch tracks with its fixes, and still leaves a modified config.json out" {
  fix_ready
  echo '{"test":"make check"}' > .coding-crew/dev-commands.json
  echo '{"tracker":{"kind":"github"},"x":1}' > .coding-crew/config.json
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git diff --name-only HEAD~1 HEAD | sort | tr '\n' ' ')" = ".coding-crew/dev-commands.json fixed.txt " ]
  [ "$(git status --porcelain -uall)" = " M .coding-crew/config.json" ]
}

@test "fix in a repo that gitignores .coding-crew/ commits the fixer's edits and leaves a tracked config.json's edit out" {
  fix_ready
  echo .coding-crew/ >> .gitignore
  git add .gitignore && git rm -q --cached .coding-crew/dev-commands.json && git commit -q -m "ignore setup"
  echo '{"tracker":{"kind":"github"},"x":1}' > .coding-crew/config.json
  echo more > more.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git diff --name-only HEAD~1 HEAD | sort | tr '\n' ' ')" = "fixed.txt more.txt " ]
  [ "$(git status --porcelain -uall)" = " M .coding-crew/config.json" ]
}

@test "fix commits the fixer's removal of a dev commands file the branch tracks" {
  fix_ready
  rm .coding-crew/dev-commands.json
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git diff --name-status HEAD~1 HEAD | tr '\t\n' '  ')" = "D .coding-crew/dev-commands.json A fixed.txt " ]
  [ -z "$(git status --porcelain -uall)" ]
}

@test "fix stops, committing nothing, when staging the fixer's edits fails" {
  fix_ready
  git config filter.boom.clean false && git config filter.boom.required true
  echo 'fixed.txt filter=boom' > .git/info/attributes
  local head; head=$(git rev-parse HEAD)
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"fix failed: git add failed"* ]]
  [ "$(git rev-parse HEAD)" = "$head" ]
}

@test "fix with no findings on a clean tree commits nothing" {
  loop
  report '{"spec":"met","gaps":[],"findings":[]}'
  TIP=$(git rev-parse HEAD)
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD)" = "$TIP" ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=0 needs-attention=0 review-again=no" ]
}

@test "fix pushes the fixer's own commits as they are" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  git add fixed.txt && git commit -q -m "fixer's commit"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD~1)" = "$TIP" ]
  [ "$(git log -1 --format=%s)" = "fixer's commit" ]
  pushed
}

@test "an unmet spec and each finding left in unfixed.json are handed to describe as typed items, by index" {
  fix_ready '{"spec":"unmet","gaps":["no logout endpoint","no login"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"},{"severity":"MEDIUM","location":"b:2","issue":"j","fix":"g"}]}'
  echo '[{"finding": 1, "why": "w"}, {"finding": 7, "why": "out of range"}]' > .coding-crew/solve-feature/pr-10.unfixed.json
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = "$(printf '%s\n' '{"type":"spec_unmet","round":0,"gaps":[0,1]}' \
    '{"type":"unfixed","round":0,"finding":1,"severity":"MEDIUM","why":"w"}' \
    '{"type":"unfixed","round":0,"finding":7,"severity":null,"why":"out of range"}')" ]
  [ ! -e .coding-crew/solve-feature/pr-10.unfixed.json ]
  [ "$(cat .coding-crew/solve-feature/pr-10.r1.unfixed.json)" = '[{"finding": 1, "why": "w"}, {"finding": 7, "why": "out of range"}]' ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=3 review-again=yes" ]

  # The spec unmet with no gap named, or anything but met (none, missing, unknown), still needs a person.
  local spec
  for spec in '"spec":"unmet",' '"spec":"none",' '' '"spec":"maybe",' '"spec":3,'; do
    report "{${spec}\"gaps\":[],\"findings\":[]}"
    run bash "$SCRIPT" fix feat 10 feature/feat
    [ "$status" -eq 0 ] || { echo "$spec: $output"; return 1; }
    [ "$(attention)" = "$(jq -nc --argjson r "$(($(ls .coding-crew/solve-feature/pr-10.r*.review.json | wc -l) - 1))" '{type: "spec_unmet", round: $r, gaps: []}')" ] ||
      { echo "$spec: $(attention)"; return 1; }
  done
  # An unreadable file is one item with no finding and its raw text, never dropped.
  report '{"spec":"met","gaps":[],"findings":[{"severity":"LOW","location":"b:2","issue":"j","fix":"g"}]}'
  printf 'not json' > .coding-crew/solve-feature/pr-10.unfixed.json
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$(attention)" = '{"type":"unfixed","round":6,"severity":null,"why":"not json"}' ]
}

@test "fix asks for a re-review after a CRITICAL, HIGH or MEDIUM finding when the fixer left a change, committed by fix or by the fixer" {
  fix_ready
  for sev in CRITICAL HIGH MEDIUM; do
    report "{\"spec\":\"met\",\"gaps\":[],\"findings\":[{\"severity\":\"LOW\",\"location\":\"b:2\",\"issue\":\"j\",\"fix\":\"g\"},{\"severity\":\"$sev\",\"location\":\"a:1\",\"issue\":\"i\",\"fix\":\"f\"}]}"
    echo "$sev" > fixed.txt
    run bash "$SCRIPT" fix feat 10 feature/feat
    [ "$status" -eq 0 ] || { echo "$sev: $output"; return 1; }
    [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=0 review-again=yes" ] || { echo "$sev: $output"; return 1; }
  done
  # The fixer's own commit, with nothing left for fix to commit.
  report '{"spec":"met","gaps":[],"findings":[{"severity":"MEDIUM","location":"a:1","issue":"i","fix":"f"}]}'
  echo again > fixed.txt && git add fixed.txt && git commit -q -m "fixer's commit"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=1 needs-attention=0 review-again=yes" ]
}

@test "fix asks for no re-review after only LOW findings, no findings, a severity it does not know, or a fixer that changed nothing" {
  fix_ready '{"spec":"met","gaps":[],"findings":[{"severity":"LOW","location":"b:2","issue":"j","fix":"g"}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=1 needs-attention=0 review-again=no" ]
  report '{"spec":"met","gaps":[],"findings":[]}'
  echo more > fixed.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=0 needs-attention=0 review-again=no" ]
  report '{"spec":"met","gaps":[],"findings":[{"location":"a:1","issue":"i","fix":"f"},{"severity":"high","location":"b:2","issue":"j","fix":"g"},"a string"]}'
  echo again > fixed.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=3 needs-attention=0 review-again=no" ]
  report '{"spec":"met","gaps":[],"findings":[{"severity":"CRITICAL","location":"a:1","issue":"i","fix":"f"}]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=1 needs-attention=1 review-again=no" ]
}

@test "a second fix after a re-review leaves only its own gaps and unfixed findings needing attention" {
  fix_ready '{"spec":"unmet","gaps":["first gap"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}]}'
  echo '[{"finding": 0, "why": "first"}]' > .coding-crew/solve-feature/pr-10.unfixed.json
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$(attention)" = "$(printf '%s\n' '{"type":"spec_unmet","round":0,"gaps":[0]}' '{"type":"unfixed","round":0,"finding":0,"severity":"HIGH","why":"first"}')" ]
  # A gap named under a spec the report calls met still needs a person.
  report '{"spec":"met","gaps":["second gap"],"findings":[{"severity":"LOW","location":"b:2","issue":"j","fix":"g"}]}'
  echo '[{"finding": 0, "why": "second"}]' > .coding-crew/solve-feature/pr-10.unfixed.json
  echo second > fixed.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = "$(printf '%s\n' '{"type":"spec_unmet","round":1,"gaps":[0]}' '{"type":"unfixed","round":1,"finding":0,"severity":"LOW","why":"second"}')" ]
}

@test "fix posts nothing on the PR" {
  fix_ready '{"spec":"unmet","gaps":["g"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}]}'
  echo '[{"finding": 0, "why": "x"}]' > .coding-crew/solve-feature/pr-10.unfixed.json
  : > "$STATE/gh.log"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  [ "$(grep -E '^(pr|api|issue|repo) ' "$STATE/gh.log" | cut -d' ' -f1-3 | sort -u)" = "pr view 10" ]
}

# --- reviewed: between the reviewer and the fixer ----------------------------------------

# reviewed_ready [<report json>] — both issues landed in PR #10 and sync saved the reviewer's starting head;
# the reviewer's report is there (default: met, two findings).
reviewed_ready() {
  loop
  [ "$LAST_PR" = 10 ]
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
  local two='{"spec":"met","gaps":[],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"},{"severity":"LOW","location":"b:2","issue":"j","fix":"g"}]}'
  report "${1:-$two}"
}
discarded() { cat .coding-crew/solve-feature/pr-10.discarded.md; }

# reviewed_stops <reason> — exit 1, the stop in outcome under the review's reviewer step.
reviewed_stops() {
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: review reviewer failed: $1"* ]] || { echo "$output"; return 1; }
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: review reviewer failed: $1"* ]]
}

@test "reviewed on the tree and head the reviewer left as it found them prints findings= and changes nothing" {
  reviewed_ready
  local tip; tip=$(git rev-parse HEAD)
  echo kept > ignored.log && echo ignored.log >> .git/info/exclude
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[${#lines[@]}-1]}" = "findings=2" ]
  [ "$(git rev-parse HEAD)" = "$tip" ]
  [ -z "$(git status --porcelain)" ]
  [ "$(cat ignored.log)" = kept ]
  [ ! -e .coding-crew/solve-feature/pr-10.discarded.md ]
  report '{"spec":"met","gaps":[],"findings":[]}'
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "${lines[${#lines[@]}-1]}" = "findings=0" ]
}

@test "reviewed discards a reviewer's commit, modified file and untracked files, keeps ignored and run files, and lists what it discarded" {
  reviewed_ready
  local base; base=$(git rev-parse HEAD)
  echo kept > ignored.log && echo ignored.log >> .git/info/exclude
  echo rev > rev.txt && git add rev.txt && git commit -q -m "reviewer's commit"
  echo changed >> work-2.txt
  mkdir -p sub && echo x > sub/new.txt && echo y > new.txt
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[${#lines[@]}-1]}" = "findings=2" ]
  [ "$(git rev-parse HEAD)" = "$base" ]
  [ -z "$(git status --porcelain -uall)" ]
  [ "$(cat ignored.log)" = kept ]
  [ -f .coding-crew/solve-feature/spec.md ] && [ -f .coding-crew/solve-feature/pr-10.review.json ]
  [ "$(discarded)" = "$(printf 'new.txt\nrev.txt\nsub/new.txt\nwork-2.txt')" ]
}

@test "reviewed discards a nested git repository the reviewer cloned into the tree, so fix never commits it" {
  reviewed_ready
  local base; base=$(git rev-parse HEAD)
  git init -q scratch && echo x > scratch/f.txt
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e scratch ]
  [ -z "$(git status --porcelain -uall)" ]
  [ "$(discarded)" = "scratch/" ]
}

@test "reviewed keeps config.json and an untracked dev commands file" {
  loop
  git rm -q --cached .coding-crew/config.json .coding-crew/dev-commands.json && git commit -q -m "setup untracked"
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[]}'
  local base; base=$(git rev-parse HEAD)
  echo '{"test":"make check"}' > .coding-crew/dev-commands.json
  echo scratch > reviewer.txt
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD)" = "$base" ]
  [ "$(cat .coding-crew/dev-commands.json)" = '{"test":"make check"}' ]
  [ -f .coding-crew/config.json ]
  [ "$(discarded)" = "reviewer.txt" ]
}

@test "reviewed keeps a tracked config.json's uncommitted local edit when it discards the reviewer's changes" {
  reviewed_ready
  local base; base=$(git rev-parse HEAD)
  git ls-files --error-unmatch .coding-crew/config.json >/dev/null
  echo '{"local":"edit"}' > .coding-crew/config.json
  echo rev > rev.txt && git add rev.txt && git commit -q -m "reviewer's commit"
  echo y > new.txt
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD)" = "$base" ]
  [ "$(cat .coding-crew/config.json)" = '{"local":"edit"}' ]
  [ "$(git status --porcelain -uall)" = " M .coding-crew/config.json" ]
  [ "$(discarded)" = "$(printf 'new.txt\nrev.txt')" ]
}

@test "after a discard fix flags it, and describe leaves the PR a draft needing attention" {
  reviewed_ready
  echo y > new.txt
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ]
  echo fixed > fixed.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = '{"type":"reviewer_changed_tree","paths":["new.txt"]}' ]
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "needs-attention pr=10" ]
  ! grep -q '^pr ready' "$STATE/gh.log" || false
}

@test "a discard stays flagged through a second review round, whose own discard adds to the list" {
  reviewed_ready
  echo y > new.txt
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ]
  echo fixed > fixed.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "${lines[${#lines[@]}-1]}" == *"review-again=yes" ]]
  # Second round: a clean reviewer, then a fixer that fixes everything.
  report '{"spec":"met","gaps":[],"findings":[]}'
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = '{"type":"reviewer_changed_tree","paths":["new.txt"]}' ]
  run bash "$SCRIPT" describe feat 10
  [ "${lines[${#lines[@]}-1]}" = "needs-attention pr=10" ]
  # A second round that discards too lists both rounds' paths.
  echo z > other.txt
  rereview
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ]
  [ "$(discarded)" = "$(printf 'new.txt\nother.txt')" ]
}

@test "the field case: a zero-finding review whose reviewer rewrote yarn.lock and left package-lock.json gets no commit and pushes neither" {
  loop
  echo v1 > yarn.lock && git add yarn.lock && git commit -q -m "yarn.lock" && git push -q origin feature/feat
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[]}'
  local tip; tip=$(git rev-parse HEAD)
  echo v2 > yarn.lock && echo '{}' > package-lock.json
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "${lines[${#lines[@]}-1]}" = "findings=0" ]
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD)" = "$tip" ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$tip" ]
  [ "$(git show origin/feature/feat:yarn.lock)" = v1 ]
  [ ! -e package-lock.json ]
  [ "$(attention)" = '{"type":"reviewer_changed_tree","paths":["package-lock.json","yarn.lock"]}' ]
}

@test "reviewed on another branch, or with no saved head, stops and discards nothing" {
  reviewed_ready
  git checkout -q -b elsewhere
  echo y > new.txt
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  reviewed_stops "branch changed to 'elsewhere'"
  [ -f new.txt ]
  git checkout -q feature/feat
  rm .coding-crew/solve-feature/review.base
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  reviewed_stops "no saved head at $WORK/.coding-crew/solve-feature/review.base: run sync feat feature/feat first"
  [ -f new.txt ]
  [ ! -e .coding-crew/solve-feature/pr-10.discarded.md ]
}

# git_fails <subcommand> — a git whose <subcommand> fails; every other git command is the real one.
git_fails() {
  local real; real=$(command -v git)
  printf '#!/usr/bin/env bash\nif [ "$1" = %s ]; then echo "fatal: no" >&2; exit 1; fi\nexec "%s" "$@"\n' "$1" "$real" > "$STUB/git"
  chmod +x "$STUB/git"
}

@test "a failing reset or clean stops reviewed naming it" {
  reviewed_ready
  local base; base=$(git rev-parse HEAD)
  echo y > new.txt
  git_fails clean
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  reviewed_stops "git clean failed (see above): clean the tree by hand to $base, then run reviewed feat 10 feature/feat"
  git_fails reset
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  reviewed_stops "git reset failed (see above): clean the tree by hand to $base, then run reviewed feat 10 feature/feat"
}

@test "a missing or unreadable report stops reviewed after its discard" {
  reviewed_ready
  echo y > new.txt
  rm .coding-crew/solve-feature/pr-10.review.json
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  reviewed_stops "no review report at $WORK/.coding-crew/solve-feature/pr-10.review.json"
  [ ! -e new.txt ]
  report 'not json'
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  reviewed_stops "unreadable review report $WORK/.coding-crew/solve-feature/pr-10.review.json"
}

@test "fix saves the head after its push, so a second round's reviewed compares with what that reviewer saw" {
  fix_ready
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
  rereview
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e .coding-crew/solve-feature/pr-10.discarded.md ]
}

@test "a re-run after a fix push stop keeps its unpushed local commits: reviewed discards nothing" {
  fix_ready
  refuse_pushes
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 1 ]
  rm "$TEMP_DIR/origin.git/hooks/pre-receive"
  local tip; tip=$(git rev-parse HEAD)
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" next feat; [ "$status" -eq 3 ]
  run bash "$SCRIPT" sync feat feature/feat; [ "$status" -eq 0 ]
  report '{"spec":"met","gaps":[],"findings":[]}'
  run bash "$SCRIPT" reviewed feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD)" = "$tip" ]
  [ ! -e .coding-crew/solve-feature/pr-10.discarded.md ]
}
