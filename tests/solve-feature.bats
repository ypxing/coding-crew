#!/usr/bin/env bats

# solve-feature.sh start, next and describe, the packaging and the hosts; land is in solve-feature-land.bats,
# fix in solve-feature-fix.bats. Setup and the stubs: helpers/solve-feature.bash.

load helpers/solve-feature
bats_require_minimum_version 1.5.0

# --- usage and preconditions ---------------------------------------------------------

@test "no subcommand, an unknown one or a wrong argument count exits 2 with the usage line" {
  local args
  for args in "" "feat" "run feat" "next" "land feat 2" "sync feat" "sync feat b x" "fix feat 10" "fix feat 10 feature/feat x" "fix feat ten feature/feat" "reviewed feat 10" "reviewed feat ten feature/feat" "describe feat" "describe feat ten" "start feat other"; do
    run bash "$SCRIPT" $args
    [ "$status" -eq 2 ] || { echo "'$args': status $status"; return 1; }
    [[ "$output" == *"usage: solve-feature.sh start <slug> [--branch <name>] [--review-since <sha>] | next <slug> | land <slug> <ref> <branch> | sync <slug> <branch> | reviewed <slug> <pr> <branch> | fix <slug> <pr> <branch> | describe <slug> <pr>"* ]]
  done
  [ ! -f "$STATE/gh.log" ]
  [ ! -e "$WORK/.coding-crew/solve-feature/outcome" ]
}

@test "start: a missing tool, an invalid slug, no tracker CLI or a dirty tree exits 1 before any checkout or gh call" {
  local tool
  for tool in gh jq; do
    local bin="$TEMP_DIR/bin-$tool"
    mkdir -p "$bin"
    for t in bash env git node jq gh dirname cat grep sed awk mkdir hostname date head tail tr printf rm; do
      [ "$t" = "$tool" ] && continue
      p=$(PATH="$STUB:$PATH" command -v "$t") && ln -sf "$p" "$bin/$t"
    done
    PATH="$bin" run "$bin/bash" "$SCRIPT" start feat
    [ "$status" -eq 1 ] || { echo "$tool: status $status"; return 1; }
    [[ "$output" == *"$tool"* ]] || { echo "$tool: $output"; return 1; }
  done

  run bash "$SCRIPT" start '../x'
  [ "$status" -eq 1 ]
  [[ "$output" == *"slug"* ]]

  mv "$LIB/tracker/cli.mjs" "$TEMP_DIR/cli.mjs"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"tracker CLI not found"*"the coding-crew-lib skill"*"npx skills add <that source> -s coding-crew-lib"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"command not found"* ]] || { echo "$output"; return 1; }
  mv "$TEMP_DIR/cli.mjs" "$LIB/tracker/cli.mjs"

  echo dirt > dirt.txt
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"clean"* ]]

  [ "$(git branch --show-current)" = main ]
  [ ! -f "$STATE/gh.log" ]
}

@test "start with a slug features does not list exits 1 naming it and the listed slugs, before any checkout or push" {
  run bash "$SCRIPT" start feta
  [ "$status" -eq 1 ]
  [[ "$output" == *"no feature 'feta'; features: feat other"* ]]
  [ "$(git branch --show-current)" = main ]
  ! git show-ref --verify -q refs/heads/feature/feta || false
  [ "$(git ls-remote --heads origin | grep -c .)" -eq 1 ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: start failed: no feature 'feta'; features: feat other" ]
}

# --- start: the dev commands file -----------------------------------------------------

@test "start with no dev commands file, even beside a compose file, starts: the first coder discovers checks and mode" {
  printf 'services:\n  app:\n    image: node\n' > compose.yml
  git rm -q .coding-crew/dev-commands.json && git add compose.yml && git commit -q -m "no commands"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out branch)" = feature/feat ]
}

@test "start proceeds for a modified or untracked config.json and an untracked dev commands file, and dies for any other change" {
  echo '{"tracker":{"kind":"github"},"solveFeature":{"models":{"coder":"sonnet"}}}' > .coding-crew/config.json
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out coder-model)" = sonnet ]
  [ "$(git status --porcelain)" = " M .coding-crew/config.json" ]

  # A tracked dev commands file is the branch's: an edit to it is work to commit, not a setting to try.
  git checkout -q main && git checkout -q -- .coding-crew && git branch -q -D feature/feat && git push -q origin --delete feature/feat
  echo '{"test":"make check"}' > .coding-crew/dev-commands.json
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"working tree is not clean"* ]]

  git checkout -q -- .coding-crew
  git rm -q --cached .coding-crew/config.json .coding-crew/dev-commands.json && git commit -q -m "setup uncommitted"
  git push -q origin HEAD
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git status --porcelain -uall | sort | tr '\n' ' ')" = "?? .coding-crew/config.json ?? .coding-crew/dev-commands.json " ]

  git checkout -q main
  echo dirt > .coding-crew/other.json
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"working tree is not clean"* ]]
}

@test "start whose uncommitted dev commands file origin now commits says to keep one copy, checking out or merging" {
  git rm -q --cached .coding-crew/dev-commands.json && git commit -q -m "commands uncommitted" && git push -q origin HEAD
  git clone -q "$TEMP_DIR/origin.git" "$TEMP_DIR/mate"
  echo '{"test":"make all"}' > "$TEMP_DIR/mate/.coding-crew/dev-commands.json"
  git -C "$TEMP_DIR/mate" add .coding-crew && git -C "$TEMP_DIR/mate" -c user.email=m@m -c user.name=M commit -q -m cmds
  git -C "$TEMP_DIR/mate" push -q origin HEAD
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"origin/main now has .coding-crew/dev-commands.json: compare it with your uncommitted copy, keep one (commit, or move yours aside), then re-run"* ]] || { echo "$output"; return 1; }

  git checkout -q -b feature/feat HEAD && git push -q -u origin feature/feat
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"origin/main now has .coding-crew/dev-commands.json: compare it with your uncommitted copy"* ]] || { echo "$output"; return 1; }
}

@test "start blocked by a tracked, modified setup file leaves the error to git, not blaming origin" {
  git checkout -q -b feature/feat && echo '{"tracker":{"kind":"github"},"x":2}' > .coding-crew/config.json
  git commit -qam "branch config" && git push -q -u origin feature/feat && git checkout -q main
  echo '{"tracker":{"kind":"github"},"x":1}' > .coding-crew/config.json
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" != *"origin/main now has"* ]] || { echo "$output"; return 1; }
}

@test "start in a linked worktree whose tree has no config.json reads the models from the main checkout's" {
  git rm -q .coding-crew/config.json && git commit -q -m "no config" && git push -q origin HEAD
  echo '{"tracker":{"kind":"github"},"solveFeature":{"models":{"coder":"sonnet","reviewer":"opus"}}}' > .coding-crew/config.json
  git fetch -q origin
  git worktree add -q --detach "$TEMP_DIR/wt" origin/HEAD
  cd "$TEMP_DIR/wt"
  [ ! -e .coding-crew/config.json ]
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out coder-model)" = sonnet ]
  [ "$(out reviewer-model)" = opus ]
}

# --- start: the branch ---------------------------------------------------------------

@test "start on the default branch creates feature/<slug> from origin/main, pushes it with upstream and prints branch=" {
  git commit -q --allow-empty -m "local only, not on origin"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ]
  [ "$(out branch)" = feature/feat ]
  [ "$(git branch --show-current)" = feature/feat ]
  [ "$(git ls-remote --heads origin feature/feat | grep -c .)" -eq 1 ]
  [ "$(git rev-parse --abbrev-ref '@{upstream}')" = origin/feature/feat ]
  [ "$(git merge-base feature/feat main)" = "$(git rev-parse origin/main)" ]
  [ "$(git rev-parse main)" != "$(git rev-parse origin/main)" ]
}

@test "--branch names the branch made from the default branch, and an existing one is checked out as it was left" {
  git branch mine origin/main
  git checkout -q mine && git commit -q --allow-empty -m "earlier run" && git checkout -q main
  local tip; tip=$(git rev-parse mine)
  run bash "$SCRIPT" start feat --branch mine
  [ "$(out branch)" = mine ]
  [ "$(git rev-parse HEAD)" = "$tip" ]
}

@test "a branch only on origin is checked out tracking it" {
  git push -q origin origin/main:refs/heads/remote-only
  git fetch -q origin
  run bash "$SCRIPT" start feat --branch remote-only
  [ "$(out branch)" = remote-only ]
  [ "$(git rev-parse --abbrev-ref '@{upstream}')" = origin/remote-only ]
}

@test "start merges origin's default branch into an existing branch and pushes the merge" {
  git checkout -q -b mine origin/main && echo mine > mine.txt && git add mine.txt && git commit -q -m "earlier run"
  git push -q -u origin mine
  local tip; tip=$(git rev-parse mine)
  main_moves fix.txt "a fix on main"
  run bash "$SCRIPT" start feat --branch mine
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git merge-base --is-ancestor "$tip" HEAD
  git merge-base --is-ancestor origin/main HEAD
  [ "$(git ls-remote origin mine | cut -f1)" = "$(git rev-parse HEAD)" ]
  # Already up to date: no new commit.
  local merged; merged=$(git rev-parse HEAD)
  run bash "$SCRIPT" start feat --branch mine
  [ "$status" -eq 0 ]
  [ "$(git rev-parse HEAD)" = "$merged" ]
}

@test "start whose merge of the default branch conflicts exits 1 naming the files, with the branch as it was" {
  git checkout -q -b mine origin/main && echo mine > shared.txt && git add shared.txt && git commit -q -m "earlier run"
  git push -q -u origin mine
  local tip; tip=$(git rev-parse mine)
  main_moves shared.txt "main's version"
  run bash "$SCRIPT" start feat --branch mine
  [ "$status" -eq 1 ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: start failed: merging origin/main into mine conflicts in shared.txt: merge it by hand, push mine, then re-run" ]
  [ "$(git rev-parse HEAD)" = "$tip" ]
  [ -z "$(git status --porcelain)" ]
  [ "$(git ls-remote origin mine | cut -f1)" = "$tip" ]
}

@test "start from another branch or a detached HEAD switches to --branch, else feature/<slug>" {
  git checkout -q -b topic
  run bash "$SCRIPT" start feat --branch other
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out branch)" = other ]
  [ "$(git branch --show-current)" = other ]
  git checkout -q topic
  run bash "$SCRIPT" start feat
  [ "$(out branch)" = feature/feat ]
  [ "$(git branch --show-current)" = feature/feat ]
  git checkout -q --detach main
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out branch)" = feature/feat ]
  [ "$(git branch --show-current)" = feature/feat ]
}

@test "start with an unreachable origin, or a branch it cannot push, exits 1 and writes a stopped outcome; a re-run pushes it" {
  git remote set-url origin "$TEMP_DIR/missing.git"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: start failed: git fetch origin failed"* ]]
  git remote set-url origin "$TEMP_DIR/origin.git"
  chmod -w "$TEMP_DIR/origin.git/refs/heads"
  run bash "$SCRIPT" start feat
  chmod +w "$TEMP_DIR/origin.git/refs/heads"
  [ "$status" -eq 1 ]
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: start failed: cannot push feature/feat"* ]]
  # The refused push left the local branch behind; a re-run pushes it rather than reuse it unpushed.
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  [ "$(git rev-parse --abbrev-ref '@{u}')" = origin/feature/feat ]
}

@test "start's push of a new branch, and its push after merging the default branch, quote git's reason" {
  refuse_pushes
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: start failed: cannot push feature/feat: pre-receive hook declined" ]
  rm "$TEMP_DIR/origin.git/hooks/pre-receive"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ]
  main_moves other.txt x
  git checkout -q feature/feat
  refuse_pushes
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: start failed: cannot push feature/feat after merging origin/main into it: pre-receive hook declined" ]
}

@test "start --branch naming the default branch exits 1 naming it" {
  git checkout -q -b topic
  run bash "$SCRIPT" start feat --branch main
  [ "$status" -eq 1 ]
  [[ "$output" == *"'main' is the default branch"* ]]
  [ "$(git branch --show-current)" = topic ]
}

# --- start: what it prints and saves -------------------------------------------------

@test "start prints coder-model= and reviewer-model= from solveFeature.models only (empty when unset), pr= for the branch's open PR" {
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'branch=feature/feat\ncoder-model=\nreviewer-model=\npr=')" ]

  echo '{"tracker":{"kind":"github"},"afk":{"models":{"claude":{"coder":"haiku","reviewer":"haiku"}}}}' > .coding-crew/config.json
  git commit -q -am "afk models"
  PR_EXISTS=1 run bash "$SCRIPT" start feat
  [ "$output" = "$(printf 'branch=feature/feat\ncoder-model=\nreviewer-model=\npr=9')" ]

  echo '{"tracker":{"kind":"github"},"solveFeature":{"models":{"coder":"sonnet","reviewer":"opus"}}}' > .coding-crew/config.json
  git commit -q -am "solveFeature models"
  run bash "$SCRIPT" start feat
  [ "$(out coder-model)" = sonnet ]
  [ "$(out reviewer-model)" = opus ]
}

@test "start converts the branch's open PR to a draft before printing pr= when it is ready; a draft or no PR gets no such call" {
  PR_EXISTS=1 PR_DRAFT=false run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out pr)" = 9 ]
  [ "$(grep '^pr ready' "$STATE/gh.log")" = "pr ready 9 --undo" ]

  : >"$STATE/gh.log"
  PR_EXISTS=1 PR_DRAFT=true run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ]
  [ "$(out pr)" = 9 ]
  ! grep -q '^pr ready' "$STATE/gh.log" || false

  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ]
  ! grep -q '^pr ready' "$STATE/gh.log" || false
}

@test "start whose gh pr ready --undo fails exits 1 naming the command to run, before printing pr=" {
  PR_EXISTS=1 PR_DRAFT=false GH_UNDO_FAIL=1 run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh pr ready 9 --undo"* ]]
  [[ "$output" != *"pr=9"* ]]
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: start failed: "*"gh pr ready 9 --undo"* ]]
}

@test "start takes each model the project's config.json lacks from \$HOME/.coding-crew/config.json" {
  mkdir -p "$HOME/.coding-crew"
  echo '{"solveFeature":{"models":{"coder":"haiku","reviewer":"opus"}}}' > "$HOME/.coding-crew/config.json"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out coder-model)" = haiku ]
  [ "$(out reviewer-model)" = opus ]

  echo '{"tracker":{"kind":"github"},"solveFeature":{"models":{"coder":"sonnet"}}}' > .coding-crew/config.json
  git commit -q -am "project coder only"
  run bash "$SCRIPT" start feat
  [ "$(out coder-model)" = sonnet ]
  [ "$(out reviewer-model)" = opus ]
}

@test "start takes each model from CREW_CODER_MODEL / CREW_REVIEWER_MODEL before both config files, printed as set; an empty one falls through" {
  mkdir -p "$HOME/.coding-crew"
  echo '{"solveFeature":{"models":{"coder":"haiku","reviewer":"haiku"}}}' > "$HOME/.coding-crew/config.json"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  echo '{"tracker":{"kind":"github"},"solveFeature":{"models":{"coder":"sonnet","reviewer":"opus"}}}' > .coding-crew/config.json
  git commit -q -am "project models"
  run env CREW_CODER_MODEL='gpt-5.4' CREW_REVIEWER_MODEL='opus 5.5' bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out coder-model)" = gpt-5.4 ]
  [ "$(out reviewer-model)" = 'opus 5.5' ]

  run env CREW_CODER_MODEL='gpt-5.4' bash "$SCRIPT" start feat
  [ "$(out coder-model)" = gpt-5.4 ]
  [ "$(out reviewer-model)" = opus ] || { echo "$output"; return 1; }
  run env CREW_REVIEWER_MODEL='fable' bash "$SCRIPT" start feat
  [ "$(out coder-model)" = sonnet ]
  [ "$(out reviewer-model)" = fable ]

  run env CREW_CODER_MODEL= CREW_REVIEWER_MODEL= bash "$SCRIPT" start feat
  [ "$(out coder-model)" = sonnet ]
  [ "$(out reviewer-model)" = opus ]

  echo '{"tracker":{"kind":"github"}}' > .coding-crew/config.json
  git commit -q -am "no project models"
  run env CREW_CODER_MODEL='claude-opus-5-5' bash "$SCRIPT" start feat
  [ "$(out coder-model)" = claude-opus-5-5 ]
  [ "$(out reviewer-model)" = haiku ]
}

@test "start writes .coding-crew/solve-feature/spec.md as the tracker's spec op prints it, and stops when spec fails" {
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat .coding-crew/solve-feature/spec.md)" = "$(node "$LIB/tracker/cli.mjs" spec --feature-slug feat)" ]
  grep -qx 'spec --feature-slug feat' "$STATE/node.log"
  ! grep -qE '^(prd|known) ' "$STATE/node.log" || false
  [ ! -e .coding-crew/solve-feature/issues ]
  [ -z "$(git status --porcelain)" ]

  SPEC_RC=1 run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: start failed: "*spec* ]] || { cat .coding-crew/solve-feature/outcome; return 1; }
}

@test "start removes an old outcome and review files" {
  mkdir -p .coding-crew/solve-feature && echo '*' > .coding-crew/solve-feature/.gitignore && echo 'ready pr=7' > .coding-crew/solve-feature/outcome
  echo old > .coding-crew/solve-feature/pr-7.unfixed.json && echo old > .coding-crew/solve-feature/pr-7.review.json && echo old > .coding-crew/solve-feature/pr-7.head
  echo old > .coding-crew/solve-feature/pr-7.summary.md && echo old > .coding-crew/solve-feature/pr-7.attention.json
  echo old > .coding-crew/solve-feature/pr-7.describe-attention.json
  echo old > .coding-crew/solve-feature/pr-7.discarded.md && echo old > .coding-crew/solve-feature/review.base
  echo old > .coding-crew/solve-feature/pr-7.notes.md && echo old > .coding-crew/solve-feature/pr-7.coder-notes.json
  echo old > .coding-crew/solve-feature/pr-7.prev-fixer-note.md
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e .coding-crew/solve-feature/outcome ]
  [ ! -e .coding-crew/solve-feature/pr-7.unfixed.json ]
  [ ! -e .coding-crew/solve-feature/pr-7.review.json ]
  [ ! -e .coding-crew/solve-feature/pr-7.summary.md ]
  [ ! -e .coding-crew/solve-feature/pr-7.attention.json ]
  [ ! -e .coding-crew/solve-feature/pr-7.describe-attention.json ]
  [ ! -e .coding-crew/solve-feature/pr-7.head ]
  [ ! -e .coding-crew/solve-feature/pr-7.discarded.md ]
  [ ! -e .coding-crew/solve-feature/pr-7.notes.md ]
  [ ! -e .coding-crew/solve-feature/pr-7.coder-notes.json ]
  [ ! -e .coding-crew/solve-feature/pr-7.prev-fixer-note.md ]
  [ ! -e .coding-crew/solve-feature/review.base ]
}

# --- next ------------------------------------------------------------------------------

@test "next prints the ready ref and saves its issue; exit 3 when none is left, with red-files= and reviewer-model=; a ref fetch rejects exits 1" {
  run bash "$SCRIPT" next feat
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
  [ "$(cat .coding-crew/solve-feature/2.issue.md)" = "$(cat "$STATE/2.md")" ]
  # As a finished land leaves it: otherwise a closed issue it handed out reads as a land that never finished.
  rm .coding-crew/solve-feature/landing-feat
  jq 'map(.state = "CLOSED")' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  echo extra > extra.txt && git add extra.txt && git commit -q -m extra
  PR_EXISTS=1 run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [ "$output" = "$(printf 'red-files=\nreviewer-model=\nreview-base=')" ]
  # Printed again beside the review step, resolved as start resolves it.
  PR_EXISTS=1 CREW_REVIEWER_MODEL=opus run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [ "$output" = "$(printf 'red-files=\nreviewer-model=opus\nreview-base=')" ]
  # Its sync saved the reviewer's starting head.
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
  [ ! -e .coding-crew/solve-feature/outcome ]
  NEXT_PRINTS='2; rm -rf /' run bash "$SCRIPT" next feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"fetch 2; rm -rf / failed"* ]]
}

@test "next with no ready issue and no open PR on the branch exits 3 and writes the nothing-landed stop" {
  run bash "$SCRIPT" start feat
  jq 'map(.state = "CLOSED")' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [[ "$output" == *"nothing landed: no ready issue for feat and no open PR"* ]]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: next failed: nothing landed: no ready issue for feat and no open PR" ]
}

@test "next after a stop keeps the stop's outcome line, still exiting 3 with its stderr" {
  run bash "$SCRIPT" start feat
  jq 'map(.state = "CLOSED")' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  echo "stopped: land failed: gh pr create failed" > .coding-crew/solve-feature/outcome
  run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [[ "$output" == *"nothing landed: no ready issue for feat and no open PR"* ]]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: land failed: gh pr create failed" ]
  # A die in next leaves it too.
  NEXT_PRINTS='2; rm -rf /' run bash "$SCRIPT" next feat
  [ "$status" -eq 1 ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: land failed: gh pr create failed" ]
}

# --- sync: the default branch merged in before the review ------------------------------

# synced_branch — both issues landed on feature/feat in PR #10: sync's input as the loop leaves it; TIP is its head.
synced_branch() {
  loop
  [ "$LAST_PR" = 10 ]
  TIP=$(git rev-parse HEAD)
  rm -f "$STATE/checks.log" .coding-crew/solve-feature/review.base
}

@test "sync with origin's default branch already in the branch exits 0, runs no checks, pushes nothing and saves HEAD as review.base" {
  synced_branch
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD)" = "$TIP" ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$TIP" ]
  [ ! -e "$STATE/checks.log" ]
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$TIP" ]
  [ ! -e .coding-crew/solve-feature/outcome ]
}

@test "sync whose merge is clean merges origin's default branch, gates it with the checks, pushes it and saves the merged HEAD" {
  synced_branch
  main_moves fix.txt "a fix on main" && git checkout -q feature/feat
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git merge-base --is-ancestor origin/main HEAD
  git merge-base --is-ancestor "$TIP" HEAD
  [ "$(cat "$STATE/checks.head")" = "$(git rev-parse HEAD)" ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
}

@test "sync commits the checks' rewrites of the merged tree as their own commit, then pushes it" {
  synced_branch
  main_moves fix.txt "a fix on main" && git checkout -q feature/feat
  CHECK_REWRITES=fix.txt run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git log -1 --format=%s)" = "Apply the checks' rewrites" ]
  [ "$(git show --name-only --format= HEAD)" = fix.txt ]
  [ -z "$(git status --porcelain)" ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
}

@test "sync whose checks fail on the merged tree exits 1 with an outcome naming their log, pushing nothing, what they left discarded" {
  synced_branch
  main_moves fix.txt "a fix on main" && git checkout -q feature/feat
  CHECK_LEAVES="$WORK/artefact.out" CHECK_REWRITES=fix.txt CHECK_NESTS="$WORK/fixture" CHECKS_RC=1 run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 1 ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: sync failed: run-checks.sh exit 1 on feature/feat merged with origin/main — log: $WORK/.coding-crew/solve-feature/sync.checks.log; once fixed and committed, re-run" ]
  [ -s .coding-crew/solve-feature/sync.checks.log ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$TIP" ]
  [ ! -e .coding-crew/solve-feature/review.base ]
  [ -z "$(git status --porcelain)" ]
}

@test "sync whose merge conflicts exits 4 printing conflicts= with the merge in progress; resolved and committed, sync again pushes it" {
  synced_branch
  echo mine > shared.txt && git add shared.txt && git commit -q -m "branch's shared" && git push -q origin feature/feat
  TIP=$(git rev-parse HEAD)
  main_moves shared.txt "main's version" && git checkout -q feature/feat
  # stdout is that one line; git's own conflict report and the stop's reason go to stderr.
  run --separate-stderr bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 4 ]
  [ "$output" = "conflicts=shared.txt" ]
  git rev-parse -q --verify MERGE_HEAD >/dev/null
  [ "$(git diff --name-only --diff-filter=U)" = shared.txt ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: sync failed: merging origin/main into feature/feat conflicts in shared.txt: the resolver did not finish it; finish it (resolve, git add, git commit --no-edit) or undo it with git merge --abort, then re-run" ]
  # A second exit 4 is relayed as printed, so stderr carries the same recovery as the outcome.
  [[ "$stderr" == *"solve-feature: merging origin/main into feature/feat conflicts in shared.txt: the resolver did not finish it; finish it (resolve, git add, git commit --no-edit) or undo it with git merge --abort, then re-run"* ]]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$TIP" ]
  [ ! -e .coding-crew/solve-feature/review.base ]
  # What the resolver subagent does.
  echo both > shared.txt && git add shared.txt && git commit -q --no-edit
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git merge-base --is-ancestor origin/main HEAD
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
  [ ! -e .coding-crew/solve-feature/outcome ]
}

@test "sync merges a commit someone else pushed to origin's branch with the default branch's, gating and pushing both" {
  synced_branch
  local bot; bot=$(branch_moves bot.txt "a bot's commit")
  main_moves fix.txt "a fix on main" && git checkout -q feature/feat
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  git merge-base --is-ancestor "$bot" HEAD
  git merge-base --is-ancestor origin/main HEAD
  [ "$(cat "$STATE/checks.head")" = "$(git rev-parse HEAD)" ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  [ "$(cat .coding-crew/solve-feature/review.base)" = "$(git rev-parse HEAD)" ]
}

@test "sync re-run with the merge still in progress exits 1 naming the files and the recovery, not a dirty tree" {
  synced_branch
  echo mine > shared.txt && git add shared.txt && git commit -q -m "branch's shared" && git push -q origin feature/feat
  main_moves shared.txt "main's version" && git checkout -q feature/feat
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 4 ]
  local why="a merge into feature/feat is still in progress (shared.txt): finish it (resolve, git add, git commit --no-edit) or undo it with git merge --abort, then re-run"
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 1 ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: sync failed: $why" ]
  # Resolved and staged, but not committed: MERGE_HEAD alone.
  echo both > shared.txt && git add shared.txt
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 1 ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: sync failed: $why" ]
  [[ "$output" != *"not clean"* ]]
}

@test "sync on another branch, a dirty tree or a refused push exits 1 naming it" {
  synced_branch
  run bash "$SCRIPT" sync feat other
  [ "$status" -eq 1 ]
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: sync failed: branch changed to 'feature/feat'" ]]
  echo dirt > dirt.txt
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"working tree is not clean"* ]]
  rm dirt.txt
  main_moves fix.txt "a fix on main" && git checkout -q feature/feat
  refuse_pushes
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 1 ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "stopped: sync failed: git push failed: pre-receive hook declined; once it can push, or once you have pushed it, re-run" ]
}

# --- --review-since: a follow-up run's review scoped to the commits since a sha ---------

@test "start --review-since <sha> then sync prints review-base=<sha> when origin's default branch is in it and it is in HEAD" {
  synced_branch
  run bash "$SCRIPT" start feat --review-since "$TIP"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  coder 9
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out review-base)" = "$TIP" ]
}

@test "--review-since at a commit that merged the default branch in counts as up to date" {
  synced_branch
  main_moves fix.txt "a fix on main" && git checkout -q feature/feat
  git merge -q --no-ff --no-edit origin/main && git push -q origin feature/feat
  local merged; merged=$(git rev-parse HEAD)
  run bash "$SCRIPT" start feat --review-since "$merged"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  coder 9
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out review-base)" = "$merged" ]
}

@test "sync prints an empty review-base= when the default branch moved past the sha, the sha is not in HEAD, or none was given" {
  synced_branch
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"review-base="* ]] && [ -z "$(out review-base)" ]

  run bash "$SCRIPT" start feat --review-since "$TIP"
  [ "$status" -eq 0 ]
  main_moves fix.txt "a fix on main" && git checkout -q feature/feat
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"review-base="* ]] && [ -z "$(out review-base)" ]

  git checkout -q -b aside origin/main && echo aside > aside.txt && git add aside.txt && git commit -q -m aside
  local aside; aside=$(git rev-parse HEAD); git checkout -q feature/feat
  run bash "$SCRIPT" start feat --review-since "$aside"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"review-base="* ]] && [ -z "$(out review-base)" ]

  # A later start without the flag forgets the earlier one's sha.
  run bash "$SCRIPT" start feat --review-since "$(git rev-parse HEAD)"
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"review-base="* ]] && [ -z "$(out review-base)" ]
}

@test "start --review-since naming no commit exits 1 naming it with a stopped outcome; a sha only origin had before the fetch is accepted" {
  synced_branch
  run bash "$SCRIPT" start feat --review-since nosuchref
  [ "$status" -eq 1 ]
  [[ "$output" == *"nosuchref"* ]] || { echo "$output"; return 1; }
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: start failed: "*"nosuchref"* ]]
  [ -f .coding-crew/solve-feature/result.json ]

  run bash "$SCRIPT" start feat --review-since
  [ "$status" -eq 2 ]

  local remote; remote=$(branch_moves bot.txt "a bot's commit")
  ! git cat-file -e "$remote^{commit}" 2>/dev/null || false
  run bash "$SCRIPT" start feat --review-since "$remote"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" sync feat feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out review-base)" = "$remote" ]
}

@test "issues run lowest number first, skipping closed and blocked-labelled issues and any whose blocker is neither CLOSED nor awaiting-merge" {
  issues '[{"number":1,"title":"PRD: Feat","state":"OPEN","labels":[],"root":true},
           {"number":7,"title":"Seven","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":3,"title":"Three","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":2,"title":"Two","state":"CLOSED","labels":[{"name":"ready-for-agent"}]},
           {"number":4,"title":"Four","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":5,"title":"Five","state":"OPEN","labels":[{"name":"ready-for-human"}]},
           {"number":6,"title":"Six","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":8,"title":"Eight","state":"OPEN","labels":[{"name":"ready-for-agent"},{"name":"blocked"}]}]'
  issue_body 3 Three "- Issue #2"
  issue_body 4 Four "- Issue #5"
  issue_body 6 Six "- Issue #99"
  issue_body 7 Seven "- Issue #3"
  issue_body 5 Five None
  issue_body 8 Eight None
  loop
  [ "$CODED" = "3 7" ]
}

# --- describe: the PR body, readiness and the outcome ----------------------------------

# The attribution line describe writes under the begin marker, whatever the writer subagent left.
ATTRIBUTION='> Written by solve-feature (`feat`): its coder, reviewer and fixer were agents; no person has read this body.'
# summary — what the writer subagent leaves: write-pr's title line and body, its Tested line left out as its prompt says.
summary() { printf '# Let users log in\n\n## Why\n\nUsers need accounts.\n' > .coding-crew/solve-feature/pr-10.summary.md; }

@test "describe writes the whole body once in order, titles the PR from the summary, then marks the draft ready and writes ready" {
  fixed
  printf 'hand text\n' > "$STATE/pr-body"
  summary
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$STATE/pr-title")" = "Let users log in" ]
  [ "$(cat "$STATE/pr-body")" = "$(cat <<EOF
<!-- solve-feature:begin -->
$ATTRIBUTION

## Why

Users need accounts.

**Tested:** test pass

Spec: PRD #1, feature \`feat\`

Closes #2
Closes #3
<!-- solve-feature:slug feat -->
<!-- solve-feature:end -->
EOF
)" ]
  [ "$(grep -E '^pr (edit|ready)' "$STATE/gh.log" | cut -d' ' -f1-3)" = "$(printf 'pr edit 10\npr ready 10')" ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "ready pr=10" ]
  [ "${lines[${#lines[@]}-1]}" = "ready pr=10" ]

  # A second describe rewrites the body rather than stacking the summary.
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ]
  [ "$(grep -c '^## Why$' "$STATE/pr-body")" -eq 1 ]
  [ "$(grep -c '^Spec: ' "$STATE/pr-body")" -eq 1 ]
  ! grep -q '<details>' "$STATE/pr-body" || false
  [ -s .coding-crew/solve-feature/spec.md ]
}

@test "describe's Spec line reads spec.md's first line, naming only the feature when it is no PRD-issue line, never calling prd" {
  fixed
  printf '<!-- PRD issue #42: PRD: Other -->\nbody\n' > .coding-crew/solve-feature/spec.md
  : > "$STATE/node.log"
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep '^Spec: ' "$STATE/pr-body")" = 'Spec: PRD #42, feature `feat`' ]
  ! grep -q '^prd' "$STATE/node.log" || false

  printf '# PRD: Feat\n\nthe prd\n' > .coding-crew/solve-feature/spec.md
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep '^Spec: ' "$STATE/pr-body")" = 'Spec: feature `feat`' ]

  printf '### 2-two — Two\n' > .coding-crew/solve-feature/spec.md
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep '^Spec: ' "$STATE/pr-body")" = 'Spec: feature `feat`' ]
  ! grep -q '^prd' "$STATE/node.log" || false
}

@test "with anything needing a person describe lists it under Needs attention, leaves the PR a draft and writes needs-attention" {
  fixed '{"spec":"met","gaps":["no logout endpoint"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}]}'
  summary
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sed -n '/^## Needs attention$/,/^Spec: /p' "$STATE/pr-body")" = "$(printf '## Needs attention\n\n- no logout endpoint\n\nSpec: PRD #1, feature `feat`')" ]
  [ "$(grep -n -m1 '^## Why$' "$STATE/pr-body" | cut -d: -f1)" -lt "$(grep -n -m1 '^## Needs attention$' "$STATE/pr-body" | cut -d: -f1)" ]
  [ "$(sed -n 2p "$STATE/pr-body")" = "$ATTRIBUTION" ]
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ "$(cat .coding-crew/solve-feature/outcome)" = "needs-attention pr=10" ]
}

@test "Needs attention renders one line per gap and per unfixed finding, a gap already a bullet as one bullet" {
  fix_ready '{"spec":"unmet","gaps":["- already a bullet","plain\nline"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}]}'
  echo '[{"finding": 0, "why": "needs a\ndesign call"}, {"finding": 4, "why": "w"}, {"why": "no index"}]' > .coding-crew/solve-feature/pr-10.unfixed.json
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sed -n '/^## Needs attention$/,/^Spec: /{/^- /p;}' "$STATE/pr-body")" = "$(printf -- '%s\n' '- already a bullet' '- plain line' \
    '- the fixer left finding #0 (HIGH, a:1) unfixed: needs a design call' '- the fixer left finding #4 (no severity) unfixed: w' \
    '- the fixer left a finding unfixed: no index')" ]
  [ "${lines[${#lines[@]}-1]}" = "needs-attention pr=10" ]
}

@test "a report whose spec is unmet, with no gap or finding, leaves the PR a draft and writes needs-attention" {
  fixed '{"spec":"unmet","gaps":[],"findings":[]}'
  [ "$(attention)" = '{"type":"spec_unmet","round":0,"gaps":[]}' ]
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sed -n '/^## Needs attention$/,/^Spec: /{/^- /p;}' "$STATE/pr-body")" = '- the reviewer found the spec unmet' ]
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ "$(cat .coding-crew/solve-feature/outcome)" = "needs-attention pr=10" ]
}

@test "a PR already ready is not marked again; with no summary describe keeps land's title and still decides readiness" {
  fixed
  PR_DRAFT=false run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ "$(cat "$STATE/pr-title")" = Feat ]
  [ "$(head -6 "$STATE/pr-body")" = "$(printf '<!-- solve-feature:begin -->\n%s\n\n**Tested:** test pass\n\nSpec: PRD #1, feature `feat`' "$ATTRIBUTION")" ]
  [ "$(cat .coding-crew/solve-feature/outcome)" = "ready pr=10" ]
}

@test "describe with no fix result, a failing closing-refs or a failing gh pr ready stops, never writing ready" {
  fix_ready
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 1 ]
  [[ "$output" == *"run fix feat 10 <branch> first"* ]]
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: describe failed: "* ]]
  ! grep -q '^pr edit' "$STATE/gh.log" || false

  run bash "$SCRIPT" fix feat 10 feature/feat
  CLOSING_REFS_RC=1 run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 1 ]
  [[ "$output" == *"closing-refs failed for 'feat'"* ]]
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: describe failed: closing-refs failed"* ]]
  ! grep -q '^pr edit' "$STATE/gh.log" || false

  GH_READY_FAIL=1 run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 1 ]
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: describe failed: gh pr ready 10 failed"* ]]
}

@test "describe with unresolved review threads across pages lists their count and the PR under Needs attention, leaving it a draft" {
  fixed
  threads "false true" "true false false"
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sed -n '/^## Needs attention$/,/^Spec: /p' "$STATE/pr-body")" = "$(printf '## Needs attention\n\n- 3 unresolved review threads: https://github.com/o/r/pull/10\n\nSpec: PRD #1, feature `feat`')" ]
  grep -q '^api graphql .*--paginate' "$STATE/gh.log"
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ "$(cat .coding-crew/solve-feature/outcome)" = "needs-attention pr=10" ]
  [ "${lines[${#lines[@]}-1]}" = "needs-attention pr=10" ]

  # A second describe counts them again rather than stacking the line.
  run bash "$SCRIPT" describe feat 10
  [ "$(grep -c 'unresolved review threads' "$STATE/pr-body")" -eq 1 ]
}

@test "describe with only resolved review threads marks the PR ready" {
  fixed
  threads "true" "true"
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q 'unresolved review threads' "$STATE/pr-body" || false
  grep -q '^pr ready 10$' "$STATE/gh.log"
  [ "$(cat .coding-crew/solve-feature/outcome)" = "ready pr=10" ]
}

@test "describe whose review-thread query fails stops without marking the PR ready" {
  fixed
  GH_THREADS_FAIL=1 run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 1 ]
  [[ "$output" == *"review threads"* ]]
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: describe failed: "* ]]
}

# --- packaging and the skill -------------------------------------------------------------

@test ".coding-crew/solve-feature/ is gitignored here" {
  git -C "$REPO_ROOT" check-ignore -q .coding-crew/solve-feature/x.log
}

@test "SKILL.md runs its reviewer through the crew-review skill on the spec start wrote, names no other skill's files, and no SOLVE_FEATURE_HOST" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'Use the crew-review skill on branch <branch> against the spec in <repo>/.coding-crew/solve-feature/spec.md; write the report to <repo>/.coding-crew/solve-feature/pr-<n>.review.json' "$skill"
  ! grep -qF 'read-only' "$skill" || false
  ! grep -qF '<skill-dir>/..' "$skill" || false
  ! grep -qF 'SOLVE_FEATURE_HOST' "$skill" || false
  ! grep -qF 'review-pr' "$skill" || false
}

@test "SKILL.md passes --review-since to start, and a non-empty review-base= scopes both review rounds' prompt" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'start <slug> [--branch <name>] [--review-since <sha>]`' "$skill"
  grep -qF 'printed `review-base=`; keep it for both review rounds' "$skill"
  grep -qF 'When `review-base=` is non-empty, `<sha>` its value, the prompt reads `…on branch <branch> base <sha> against the spec…`' "$skill"
  grep -qF '`; Findings cover <sha>..HEAD; judge spec, gaps and criteria on the code at HEAD: the commits before <sha> were already reviewed`' "$skill"
  grep -qE '^\| `--review-since <sha>` +\|' "$skill"
}

@test "SKILL.md's host settings are one line pointing at the guide, which documents them; its PR writer prompt asks for summary.json's four fields" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md" guide="$REPO_ROOT/docs/guide.md"
  ! grep -qE '^\| `(CREW_COMMANDS_FILE|CREW_PUBLISH|CREW_TRACKER|--spec <file> --issue <n>)` +\|' "$skill" || false
  grep -qF '`--spec <file> --issue <n>`, `CREW_PUBLISH`, `CREW_TRACKER` and `CREW_COMMANDS_FILE`, the settings of a host that embeds this skill' "$skill"
  grep -qF 'guide, "Embedding solve-feature"' "$skill"
  grep -qE '^- `CREW_COMMANDS_FILE` .*outside$' "$guide"
  grep -qF '<repo>/.coding-crew/solve-feature/pr-<n>.summary.json as' "$skill"
  grep -qF '{"title": "<the title>", "why": "<the Why text>", "changes": ["<one What changes bullet>", …], "risk": "<the Risk line>"}' "$skill"
}

@test "SKILL.md's fixer prompt asks for pr-<n>.unfixed.json, a list of finding indices with why; no code reads the old unfixed.md or attention.md" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF '<repo>/.coding-crew/solve-feature/pr-<n>.unfixed.json as a' "$skill"
  grep -qF '[{"finding": <its 0-based index in the report'"'"'s findings>, "why": "<why>"}]' "$skill"
  ! grep -rqE 'unfixed\.md|attention\.md' "$REPO_ROOT/skills" "$REPO_ROOT/lib" "$REPO_ROOT/.github" || false
}

@test "SKILL.md reviews once more only on review-again=yes after the first review, then goes on to the PR body" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'FIX: findings=<k> needs-attention=<a> review-again=yes|no' "$skill"
  grep -qF '`review-again=yes` means run 3.1–3.3 once more; after the second review, go on to 3.4 whatever it prints' "$skill"
}

@test "SKILL.md calls next once, then takes the next issue from land; it syncs only after a resolver, and runs the PR writer on coder-model=" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  [ "$(grep -cF 'solve-feature.sh" next <slug>' "$skill")" = 1 ]
  grep -qF 'It prints `pr=<n>`, then `next=<ref>`' "$skill"
  grep -qF '`next-exit=3`' "$skill"
  [ "$(grep -cF 'solve-feature.sh" sync <slug> <branch>' "$skill")" = 1 ]
  ! grep -qF 'Before 3.1, once' "$skill" || false
  grep -qF 'Wait for it to finish, then run `bash "<skill-dir>/scripts/solve-feature.sh" sync <slug> <branch>`' "$skill"
  awk '/^   4\. Run a \*\*fresh subagent\*\*/{f=1} f && /^   5\./{exit} f' "$skill" | grep -qF 'Run it on `coder-model=` as for each issue'"'"'s coder'
}

@test "SKILL.md resolves an exit 4 with one subagent on coder-model= before one sync re-run" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'the repo'"'"'s working directory, on `coder-model=` as for each issue'"'"'s coder — with exactly this prompt: `Finish the' "$skill"
  local prompt; prompt=$(awk '/with exactly this prompt: `Finish the/{f=1} f; f && /ask no questions`/{exit}' "$skill" | tr '\n' ' ' | sed 's/^.*prompt: `//; s/`.*//; s/  */ /g')
  [ "$prompt" = "Finish the merge in progress in <repo>, resolving the conflicts in <files> so that both sides' intent is kept, reading <repo>/.coding-crew/solve-feature/spec.md and the commits being merged in (git log HEAD..MERGE_HEAD); commit with git commit --no-edit. This run is non-interactive; ask no questions" ] || { echo "$prompt"; return 1; }
  grep -qF 'once, keeping its `review-base=`: any non-zero exit of that run, 4 included, stops the run like any other' "$skill"
}

@test "SKILL.md starts the fixer on reviewed's findings=, and a stop's recovery is for a person, never the agent" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'solve-feature.sh" reviewed <slug> <n> <branch>' "$skill"
  grep -qF 'Only when it prints `findings=` greater than 0' "$skill"
  ! grep -qF "jq '.findings" "$skill" || false
  grep -qF 'A non-zero exit of `fix` stops the run like any other: do not start a subagent or fix the checks yourself' "$skill"
  grep -qF "a stop's recovery steps are for a person, never for you to carry out" "$skill"
}

@test "install.sh claude --skill solve-feature ships the script, crew-review and setup-coding-crew" {
  local target="$TEMP_DIR/target"
  mkdir -p "$target" && git -C "$target" init -q -b main
  run bash "$REPO_ROOT/install.sh" claude --skill solve-feature --project "$target"
  [ "$status" -eq 0 ]
  [ -f "$target/.claude/skills/solve-feature/scripts/solve-feature.sh" ]
  [ ! -e "$target/.claude/skills/review-pr" ]
  [ ! -e "$target/.coding-crew/solve-feature" ]
  [ ! -e "$target/.claude/skills/solve-feature/hosts" ]
  [ -f "$target/.claude/skills/solve-feature/SKILL.md" ]
  [ -f "$target/.claude/skills/crew-review/SKILL.md" ]
  # solve-feature's DISCOVER stops send the user to /setup-coding-crew, so it ships alongside.
  [ -f "$target/.claude/skills/setup-coding-crew/SKILL.md" ]
  [ -f "$target/.claude/skills/coding-crew-lib/scripts/checks/run-checks.sh" ]
  [ -f "$target/.claude/skills/coding-crew-lib/scripts/checks/run.sh" ]
  [ -f "$target/.claude/skills/coding-crew-lib/scripts/tracker/cli.mjs" ]
  [ ! -e "$target/.claude/skills/solve-feature/scripts/tracker" ]
  [ "$(jq -c '.skills["solve-feature"].deps' "$REPO_ROOT/registry.json")" = '["solve-issue","crew-review","tdd","write-pr","setup-coding-crew","coding-crew-lib"]' ]
  # The installed script finds the tracker CLI in coding-crew-lib (the node stub answers next for any scripts/tracker/cli.mjs).
  git -C "$target" -c user.email=t@example.com -c user.name=test commit -q --allow-empty -m init
  run bash -c 'cd "$1" && bash .claude/skills/solve-feature/scripts/solve-feature.sh next feat' _ "$target"
  [ "$status" -eq 0 ] && [ "$output" = 2 ] || { echo "exit $status: $output"; return 1; }
}

@test "SKILL.md has the fixer run checks by key through run-checks.sh and other project commands through run.sh, as solve-issue does" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  local prompt; prompt=$(awk '/with exactly this prompt: `Judge each finding/{f=1} f; f && /ask no questions`/{exit}' "$skill" | tr '\n' ' ' | sed 's/  */ /g')
  [[ "$prompt" == *"Run a project check by its key through run-checks.sh in the coding-crew-lib skill (coding-crew-lib/scripts/checks/run-checks.sh --project-root <repo>), never by retyping its command line, and every other project command through run.sh (coding-crew-lib/scripts/checks/run.sh --project-root <repo> -- \"<command>\"), as the solve-issue skill's Step 4 says: they run where the project's dependencies are installed. Use the tdd skill"* ]] || { echo "$prompt"; return 1; }
  grep -qF '<!-- fragment:project-commands -->' "$REPO_ROOT/skills/solve-issue/SKILL.md"
}
