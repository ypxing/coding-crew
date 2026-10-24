#!/usr/bin/env bats

# solve-feature.sh start, next and describe, the packaging and the hosts; land is in solve-feature-land.bats,
# fix in solve-feature-fix.bats. Setup and the stubs: helpers/solve-feature.bash.

load helpers/solve-feature
load helpers/yaml

# --- usage and preconditions ---------------------------------------------------------

@test "no subcommand, an unknown one or a wrong argument count exits 2 with the usage line" {
  local args
  for args in "" "feat" "run feat" "next" "land feat 2" "fix feat 10" "fix feat 10 feature/feat x" "fix feat ten feature/feat" "reviewed feat 10" "reviewed feat ten feature/feat" "describe feat" "describe feat ten" "start feat other"; do
    run bash "$SCRIPT" $args
    [ "$status" -eq 2 ] || { echo "'$args': status $status"; return 1; }
    [[ "$output" == *"usage: solve-feature.sh start <slug> [--branch <name>] | next <slug> | land <slug> <ref> <branch> | reviewed <slug> <pr> <branch> | fix <slug> <pr> <branch> | describe <slug> <pr>"* ]]
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
  [[ "$output" == *"tracker CLI not found"*"the coding-crew-lib skill"*"npx skills add ypxing/coding-crew -s coding-crew-lib"* ]] || { echo "$output"; return 1; }
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

# main_moves <file> <text> — a commit on origin's main after the branch was made
main_moves() {
  git checkout -q main && echo "$2" > "$1" && git add "$1" && git commit -q -m "main: $1" && git push -q origin main
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

@test "start writes .coding-crew/solve-feature/spec.md: the PRD, then each issue known writes with its criteria as plain bullets" {
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat .coding-crew/solve-feature/spec.md)" = "$(cat <<'EOF'
<!-- PRD issue #1: PRD: Feat -->
# PRD: Feat

the prd

### 2-two — Two
## Acceptance criteria

- works for `<before>` & co
- Two done

### 3-three — Three
## Acceptance criteria

- works for `<before>` & co
- Three done
EOF
)" ]
  grep -qx 'known --feature-slug feat --out .*' "$STATE/node.log"
  [ -z "$(git status --porcelain)" ]
}

@test "start writes a spec with no PRD when prd exits 3, closed issues included, and removes an old outcome and review files" {
  mkdir -p .coding-crew/solve-feature && echo '*' > .coding-crew/solve-feature/.gitignore && echo 'ready pr=7' > .coding-crew/solve-feature/outcome
  echo old > .coding-crew/solve-feature/pr-7.unfixed.md && echo old > .coding-crew/solve-feature/pr-7.review.json && echo old > .coding-crew/solve-feature/pr-7.head
  echo old > .coding-crew/solve-feature/pr-7.summary.md && echo old > .coding-crew/solve-feature/pr-7.attention.md
  echo old > .coding-crew/solve-feature/pr-7.discarded.md && echo old > .coding-crew/solve-feature/review.base
  rm "$STATE/prd.md"
  jq 'map(if .number == 2 then .state = "CLOSED" else . end)' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(head -1 .coding-crew/solve-feature/spec.md)" = "### 2-two — Two" ]
  grep -qx '### 3-three — Three' .coding-crew/solve-feature/spec.md
  ! grep -q PRD .coding-crew/solve-feature/spec.md || false
  [ ! -e .coding-crew/solve-feature/outcome ]
  [ ! -e .coding-crew/solve-feature/pr-7.unfixed.md ]
  [ ! -e .coding-crew/solve-feature/pr-7.review.json ]
  [ ! -e .coding-crew/solve-feature/pr-7.summary.md ]
  [ ! -e .coding-crew/solve-feature/pr-7.attention.md ]
  [ ! -e .coding-crew/solve-feature/pr-7.head ]
  [ ! -e .coding-crew/solve-feature/pr-7.discarded.md ]
  [ ! -e .coding-crew/solve-feature/review.base ]
}

# --- next ------------------------------------------------------------------------------

@test "next prints the ready ref and saves its issue; exit 3 when none is left, with reviewer-model=; a ref fetch rejects exits 1" {
  run bash "$SCRIPT" next feat
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
  [ "$(cat .coding-crew/solve-feature/2.issue.md)" = "$(cat "$STATE/2.md")" ]
  jq 'map(.state = "CLOSED")' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  echo extra > extra.txt && git add extra.txt && git commit -q -m extra
  PR_EXISTS=1 run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [ "$output" = "reviewer-model=" ]
  # Printed again beside the review step, resolved as start resolves it.
  PR_EXISTS=1 CREW_REVIEWER_MODEL=opus run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [ "$output" = "reviewer-model=opus" ]
  # The reviewer runs next, from this head.
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
# summary — what the writer subagent leaves: write-pr's title line and body.
summary() { printf '# Let users log in\n\n## Why\n\nUsers need accounts.\n\n**Tested:** checks pass\n' > .coding-crew/solve-feature/pr-10.summary.md; }

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

**Tested:** checks pass

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

@test "describe's Spec line names only the feature for a PRD without an issue header, and when prd exits 3" {
  fixed
  printf '# PRD: Feat\n\nthe prd\n' > "$STATE/prd.md"
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep '^Spec: ' "$STATE/pr-body")" = 'Spec: feature `feat`' ]

  rm "$STATE/prd.md"
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(grep '^Spec: ' "$STATE/pr-body")" = 'Spec: feature `feat`' ]
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

@test "a report whose spec is unmet, with no gap or finding, leaves the PR a draft and writes needs-attention" {
  fixed '{"spec":"unmet","gaps":[],"findings":[]}'
  [ "$(attention)" = "the reviewer found the spec unmet" ]
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ "$(cat .coding-crew/solve-feature/outcome)" = "needs-attention pr=10" ]
}

@test "a PR already ready is not marked again; with no summary describe keeps land's title and still decides readiness" {
  fixed
  PR_DRAFT=false run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ "$(cat "$STATE/pr-title")" = Feat ]
  [ "$(head -4 "$STATE/pr-body")" = "$(printf '<!-- solve-feature:begin -->\n%s\n\nSpec: PRD #1, feature `feat`' "$ATTRIBUTION")" ]
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

@test "SKILL.md reviews once more only on review-again=yes after the first review, then goes on to the PR body" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'FIX: findings=<k> needs-attention=<a> review-again=yes|no' "$skill"
  grep -qF '`review-again=yes` means run 3.1–3.3 once more; after the second review, go on to 3.4 whatever it prints' "$skill"
}

@test "SKILL.md starts the fixer on reviewed's findings=, and a stop's recovery is for a person, never the agent" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'solve-feature.sh" reviewed <slug> <n> <branch>' "$skill"
  grep -qF 'Only when it prints `findings=` greater than 0' "$skill"
  ! grep -qF "jq '.findings" "$skill" || false
  grep -qF 'A non-zero exit of `fix` stops the run like any other: do not start a subagent or fix the checks yourself' "$skill"
  grep -qF "a stop's recovery steps are for a person, never for you to carry out" "$skill"
}

@test "install.sh claude --skill solve-feature ships the script, crew-review and setup-coding-crew, and no Actions host" {
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

# --- hosts -------------------------------------------------------------------------------

@test "the caller template (setup-coding-crew's hosts/github-actions.yml) parses: the issue, review and dispatch triggers, five write permissions (actions: write so it can approve or dispatch PR CI) and id-token: write, and one job calling the reusable workflow at the release tag with the four secrets by name" {
  local caller="$REPO_ROOT/skills/setup-coding-crew/hosts/github-actions.yml" cjson="$TEMP_DIR/caller.json"
  run yaml_to_json "$caller" "$cjson"
  [ "$status" -ne 3 ] || skip "no YAML parser on this machine (node js-yaml or python3 PyYAML)"
  [ "$status" -eq 0 ]
  # A YAML 1.1 parser (PyYAML) reads the `on` key as the boolean true.
  local on='(.on // .["true"])'
  [ "$(jq -c "$on | keys" "$cjson")" = '["issues","pull_request_review","workflow_dispatch"]' ]
  [ "$(jq -c "$on.issues.types" "$cjson")" = '["labeled","unlabeled","closed"]' ]
  [ "$(jq -c "$on.pull_request_review.types" "$cjson")" = '["submitted"]' ]
  [ "$(jq -r "$on.workflow_dispatch.inputs.slug.required" "$cjson")" = true ]
  grep -q '^ *# *schedule:' "$caller"
  [ "$(jq -r '.permissions | "\(.contents) \(.issues) \(.["pull-requests"]) \(.["copilot-requests"]) \(.actions) \(.["id-token"])"' "$cjson")" = "write write write write write write" ]
  [ "$(jq '.jobs | length' "$cjson")" -eq 1 ]
  # The tag is whatever release the template names: each release commit bumps it.
  jq -e '.jobs[] | (.uses | test("^ypxing/coding-crew/\\.github/workflows/crew-solve-feature\\.yml@v[0-9]+\\.[0-9]+\\.[0-9]+$"))
    and .with.slug == "${{ inputs.slug }}" and (has("steps") | not)' "$cjson" >/dev/null
  # The secrets by name, not `inherit`: the caller decides what the reusable workflow gets.
  [ "$(jq -c '.jobs[].secrets' "$cjson")" = '{"ANTHROPIC_API_KEY":"${{ secrets.ANTHROPIC_API_KEY }}","CLAUDE_CODE_OAUTH_TOKEN":"${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}","COPILOT_GITHUB_TOKEN":"${{ secrets.COPILOT_GITHUB_TOKEN }}","NPM_TOKEN":"${{ secrets.NPM_TOKEN }}"}' ]

  # This repo's own caller is the template with a local uses: (the same commit), and no env of its own.
  local own="$REPO_ROOT/.github/workflows/solve-feature.yml" ojson="$TEMP_DIR/own.json"
  yaml_to_json "$own" "$ojson"
  [ "$(jq -c "del(.jobs[].uses)" "$ojson")" = "$(jq -c "del(.jobs[].uses)" "$cjson")" ]
  [ "$(jq -r '.jobs[].uses' "$ojson")" = ./.github/workflows/crew-solve-feature.yml ]
  ! grep -q 'ANTHROPIC_DEFAULT_\|CODING_CREW_REF\|^env:' "$own" || false
}

@test "the reusable workflow (.github/workflows/crew-solve-feature.yml) parses: workflow_call inputs and optional secrets, a label gate, a slug concurrency group, the skill launched by the agent, the logs kept, then a step reading the outcome" {
  local wf="$REPO_ROOT/.github/workflows/crew-solve-feature.yml" json="$TEMP_DIR/wf.json" line
  run yaml_to_json "$wf" "$json"
  [ "$status" -ne 3 ] || skip "no YAML parser on this machine (node js-yaml or python3 PyYAML)"
  [ "$status" -eq 0 ]
  local on='(.on // .["true"])'
  [ "$(jq -c "$on | keys" "$json")" = '["workflow_call"]' ]
  jq -e "$on.workflow_call.inputs | (.slug.type == \"string\") and (.slug.required == false)
    and (.[\"timeout-minutes\"].type == \"number\") and (.[\"timeout-minutes\"].default == 360)" "$json" >/dev/null
  [ "$(jq -c "$on.workflow_call.secrets | to_entries | map(\"\\(.key)=\\(.value.required)\")" "$json")" = \
    '["ANTHROPIC_API_KEY=false","CLAUDE_CODE_OAUTH_TOKEN=false","COPILOT_GITHUB_TOKEN=false","NPM_TOKEN=false"]' ]
  [ "$(jq -r '.jobs.solve["timeout-minutes"]' "$json")" = '${{ inputs.timeout-minutes }}' ]
  # The slug job admits exactly: a dispatch, run-agent labelled, ready-for-human removed, an issue closed with
  # ready-for-human on, and a review other than an approval; the label clauses only on issue events.
  local cond; cond="$(jq -r '.jobs.slug.if | gsub("\\s+"; " ")' "$json")"
  [ "$cond" = "github.event_name == 'workflow_dispatch' || (github.event_name == 'issues' && github.event.action == 'labeled' && github.event.label.name == 'run-agent') || (github.event_name == 'issues' && github.event.action == 'unlabeled' && github.event.label.name == 'ready-for-human') || (github.event_name == 'issues' && github.event.action == 'closed' && contains(github.event.issue.labels.*.name, 'ready-for-human')) || (github.event_name == 'pull_request_review' && github.event.review.state != 'approved')" ] || { echo "$cond"; return 1; }
  # The trigger label is `run-agent`, not the skill's name: a label named after the skill reads as a topic tag.
  jq -e '[.jobs[].if // empty] | any(test("github.event.label.name == .run-agent."))' "$json" >/dev/null
  ! jq -e '[.jobs[].if // empty] | any(test("solve-feature"))' "$json" >/dev/null || false
  # The group holds the slug, so it is on the job that has it: a workflow-level group would only see the issue number.
  local conc; conc="$(jq -c '[.concurrency // empty, (.jobs[] | .concurrency // empty)]' "$json")"
  [ "$(jq 'length' <<<"$conc")" -eq 1 ]
  jq -e '.[0] | (.group | test("solve-feature-.*slug")) and .["cancel-in-progress"] == false' <<<"$conc" >/dev/null
  [ "$(jq -r '.jobs.solve.env.CREW_AGENT' "$json")" = "\${{ vars.CREW_AGENT || 'copilot' }}" ]
  [ "$(jq -r '.jobs.solve.env.CREW_MODEL' "$json")" = '${{ vars.CREW_MODEL }}' ]
  [ "$(jq -r '.jobs.solve.env.CREW_CODER_MODEL' "$json")" = '${{ vars.CREW_CODER_MODEL }}' ]
  [ "$(jq -r '.jobs.solve.env.CREW_REVIEWER_MODEL' "$json")" = '${{ vars.CREW_REVIEWER_MODEL }}' ]
  grep -qxF '      CREW_CODER_MODEL: ${{ vars.CREW_CODER_MODEL }}' "$wf"
  grep -qxF '      CREW_REVIEWER_MODEL: ${{ vars.CREW_REVIEWER_MODEL }}' "$wf"
  # The skills come from the install action at the caller template's release tag, never a clone of a branch.
  ! grep -q 'git clone\|CODING_CREW_REF' "$wf" || false
  local tag; tag=$(sed -nE 's#^ *uses: ypxing/coding-crew/\.github/workflows/crew-solve-feature\.yml@(v[0-9]+\.[0-9]+\.[0-9]+)$#\1#p' "$REPO_ROOT/skills/setup-coding-crew/hosts/github-actions.yml")
  [ -n "$tag" ]
  jq -e --arg tag "$tag" '.jobs.solve.steps[] | select(.name == "Install coding-crew (user-level)")
    | .uses == "ypxing/coding-crew/actions/install@\($tag)" and .with.agent == "${{ env.CREW_AGENT }}"' "$json" >/dev/null
  # The logs step runs whatever the run step did, and keeps .coding-crew/solve-feature/, hidden files included.
  jq -e '.jobs.solve.steps[-2] | .if == "always()" and (.uses | startswith("actions/upload-artifact@"))
    and .with.path == ".coding-crew/solve-feature/" and .with["include-hidden-files"] == true' "$json" >/dev/null
  ! grep -q 'solve-feature\.sh' "$wf" || false
  ! grep -q 'SOLVE_FEATURE_HOST' "$wf" || false
  ! grep -q 'review-pr' "$wf" || false

  # The run step, with each agent CLI stubbed: copilot by default; claude only with a non-empty secret, which it
  # gets with the empty one unset.
  jq -r '.jobs.solve.steps[] | select(.name == "Run solve-feature") | .run' "$json" > "$TEMP_DIR/run-step.sh"
  for a in copilot claude; do
    printf '#!/usr/bin/env bash\necho "%s $*"; env | grep -E "^(ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)=" | sort\n' "$a" > "$STUB/$a"
    chmod +x "$STUB/$a"
  done
  # Copilot streams JSON too: the whole stream is kept for the artifact, its CLI logs beside it, and the log gets
  # one line per event that is not ephemeral.
  local cp_flags='--output-format json --log-dir .coding-crew/solve-feature/copilot-logs'
  run env CREW_AGENT=copilot CREW_MODEL= SLUG=feat ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN= bash -e "$TEMP_DIR/run-step.sh"
  [ "$status" -eq 0 ]
  [ "$(head -n 1 .coding-crew/solve-feature/session.jsonl)" = "copilot -p Use the solve-feature skill on feat --allow-all --no-color $cp_flags" ]
  run env CREW_AGENT=copilot CREW_MODEL=gpt-5 SLUG=feat ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN= bash -e "$TEMP_DIR/run-step.sh"
  [ "$(head -n 1 .coding-crew/solve-feature/session.jsonl)" = "copilot -p Use the solve-feature skill on feat --allow-all --no-color --model gpt-5 $cp_flags" ]
  cat > "$STUB/copilot" <<'SH'
#!/usr/bin/env bash
cat <<'J'
{"type":"assistant.message_delta","data":{"deltaContent":"Sta"},"ephemeral":true}
{"type":"assistant.message","data":{"model":"claude-sonnet-5.5","content":"Starting."}}
{"type":"assistant.message","data":{"model":"claude-sonnet-5.5","content":""}}
{"type":"tool.execution_start","data":{"toolName":"bash","arguments":{"command":"bash s.sh start feat\necho"}}}
{"type":"tool.execution_start","data":{"toolName":"task","arguments":{"description":"Review","model":"claude-opus-5.5"}}}
{"type":"tool.execution_start","data":{"toolName":"skill","arguments":{"skill":"crew-review"},"parentToolCallId":"t1"}}
{"type":"tool.execution_complete","data":{"success":true,"shellExecution":{"exitCode":2},"result":{"content":"no such file\nmore"},"parentToolCallId":"t1"}}
{"type":"tool.execution_complete","data":{"success":true,"shellExecution":{"exitCode":0},"parentToolCallId":"t1"}}
{"type":"subagent.completed","data":{"agentDisplayName":"reviewer","model":"claude-opus-5.5"}}
{"type":"result","exitCode":0,"usage":{"premiumRequests":1,"sessionDurationMs":381782}}
J
exit 4
SH
  run env CREW_AGENT=copilot CREW_MODEL= SLUG=feat ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN= bash -e "$TEMP_DIR/run-step.sh"
  [ "$status" -eq 4 ]
  [ "$output" = "$(printf '%s\n' Starting. '$ bash s.sh start feat' '> subagent: Review (claude-opus-5.5)' '    skill crew-review' \
    '      failed: no such file' '< subagent reviewer ran on claude-opus-5.5' 'session: exit 0, 6 min, 1 premium requests')" ]
  [ "$(wc -l < .coding-crew/solve-feature/session.jsonl)" -eq 10 ]
  run env CREW_AGENT=claude CREW_MODEL= SLUG=feat ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN= bash -e "$TEMP_DIR/run-step.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs the repo secret ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"* ]]
  # Claude streams JSON: the whole stream is kept for the artifact, the log gets one line per event it knows, and
  # the session's exit code comes through the pipe.
  run env CREW_AGENT=claude CREW_MODEL= SLUG=feat ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN=tok bash -e "$TEMP_DIR/run-step.sh"
  [ "$status" -eq 0 ]
  [ "$(cat .coding-crew/solve-feature/session.jsonl)" = "$(printf 'claude -p /solve-feature feat --dangerously-skip-permissions --output-format stream-json --verbose\nCLAUDE_CODE_OAUTH_TOKEN=tok')" ]
  [ "$(cat .coding-crew/solve-feature/.gitignore)" = '*' ]
  cat > "$STUB/claude" <<'SH'
#!/usr/bin/env bash
echo "$*" >"$TEMP_DIR/claude-argv"
cat <<'J'
{"type":"system","subtype":"init","model":"claude-opus-5-5"}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"Starting."},{"type":"tool_use","name":"Bash","input":{"command":"bash s.sh start feat\necho"}}]},"parent_tool_use_id":null}
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"tool_use","name":"Agent","input":{"description":"Coder for 7","model":"opus"}}]},"parent_tool_use_id":null}
{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"no such file\nmore"}]},"parent_tool_use_id":"t2"}
{"type":"result","subtype":"error_max_turns","num_turns":3,"duration_ms":120000,"total_cost_usd":1.5}
J
exit 4
SH
  run env CREW_AGENT=claude CREW_MODEL=opus SLUG=feat ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN=tok TEMP_DIR="$TEMP_DIR" bash -e "$TEMP_DIR/run-step.sh"
  [ "$status" -eq 4 ]
  [ "$(cat "$TEMP_DIR/claude-argv")" = "-p /solve-feature feat --dangerously-skip-permissions --model opus --output-format stream-json --verbose" ]
  [ "$output" = "$(printf '%s\n' 'model: claude-opus-5-5' Starting. '$ bash s.sh start feat' '> subagent: Coder for 7 (opus)' \
    '      failed: no such file' 'session: error_max_turns, 3 turns, 2 min, $1.5')" ]
  [ "$(wc -l < .coding-crew/solve-feature/session.jsonl)" -eq 5 ]
  jq -r '.jobs.solve.steps[] | select(.name == "Install the agent CLI") | .run' "$json" > "$TEMP_DIR/install-step.sh"
  run env CREW_AGENT=codex bash -e "$TEMP_DIR/install-step.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CREW_AGENT is 'codex': copilot or claude"* ]]
  # No dependency lifecycle scripts run with the runner's token; claude then fetches its binary by its own script.
  printf '#!/usr/bin/env bash\n[ "$1" = root ] && { echo /g; exit; }\necho "npm $*" >>"$TEMP_DIR/install-argv"\n' > "$STUB/npm"
  printf '#!/usr/bin/env bash\necho "node $*" >>"$TEMP_DIR/install-argv"\n' > "$STUB/node"
  chmod +x "$STUB/npm" "$STUB/node"
  : > "$TEMP_DIR/install-argv"
  env CREW_AGENT=copilot TEMP_DIR="$TEMP_DIR" bash -e "$TEMP_DIR/install-step.sh"
  [ "$(cat "$TEMP_DIR/install-argv")" = "npm install -g --ignore-scripts @github/copilot" ]
  : > "$TEMP_DIR/install-argv"
  env CREW_AGENT=claude TEMP_DIR="$TEMP_DIR" bash -e "$TEMP_DIR/install-step.sh"
  [ "$(cat "$TEMP_DIR/install-argv")" = "$(printf '%s\n' 'npm install -g --ignore-scripts @anthropic-ai/claude-code' \
    'node /g/@anthropic-ai/claude-code/install.cjs')" ]

  # The last step, run as Actions would in the checkout whatever the run step did: red unless the outcome line
  # starts with `ready`, and a summary page naming the outcome, the PR, the model and what to read next.
  [ "$(jq -r '.jobs.solve.steps[-1].if' "$json")" = "always()" ]
  jq -r '.jobs.solve.steps[-1].run' "$json" > "$TEMP_DIR/last-step.sh"
  export GITHUB_STEP_SUMMARY="$TEMP_DIR/summary.md" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r \
    CREW_AGENT=claude CREW_MODEL= SLUG=feat
  rm -rf .coding-crew/solve-feature
  run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never finished"* ]]
  grep -qF '### solve-feature feat: `` never finished' "$GITHUB_STEP_SUMMARY"
  grep -qxF -- '- Agent: claude, model unpinned (the CLI default)' "$GITHUB_STEP_SUMMARY"
  mkdir -p .coding-crew/solve-feature
  echo 'needs-attention pr=10' > .coding-crew/solve-feature/outcome
  echo '- the flaky test' > .coding-crew/solve-feature/pr-10.attention.md
  echo 'report of the last coder' > .coding-crew/solve-feature/coder.report.md
  echo '{"type":"system","subtype":"init","model":"claude-opus-5-5"}' > .coding-crew/solve-feature/session.jsonl
  : > "$GITHUB_STEP_SUMMARY"
  run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs-attention pr=10"* ]]
  grep -qxF -- '- PR: https://github.com/o/r/pull/10' "$GITHUB_STEP_SUMMARY"
  grep -qxF -- '- Agent: claude, model claude-opus-5-5' "$GITHUB_STEP_SUMMARY"
  ! grep -q 'Subagent models' "$GITHUB_STEP_SUMMARY" || false
  grep -qxF -- '- the flaky test' "$GITHUB_STEP_SUMMARY"
  ! grep -q 'report of the last coder' "$GITHUB_STEP_SUMMARY" || false
  # The models the subagents ran on: distinct, in first-seen order, right after the Agent line; the main session's
  # own messages, Claude Code's made-up <synthetic> ones and a message with no model add nothing.
  cat >> .coding-crew/solve-feature/session.jsonl <<'J'
{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]},"parent_tool_use_id":null}
{"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[]},"parent_tool_use_id":"t1"}
{"type":"assistant","message":{"model":"<synthetic>","content":[]},"parent_tool_use_id":"t1"}
{"type":"assistant","message":{"model":"claude-haiku-5-5","content":[]},"parent_tool_use_id":"t2"}
{"type":"assistant","message":{"content":[]},"parent_tool_use_id":"t2"}
{"type":"assistant","message":{"model":"claude-sonnet-5-5","content":[]},"parent_tool_use_id":"t3"}
J
  : > "$GITHUB_STEP_SUMMARY"
  run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -ne 0 ]
  [ "$(grep -A1 -xF -- '- Agent: claude, model claude-opus-5-5' "$GITHUB_STEP_SUMMARY" | tail -n 1)" = \
    '- Subagent models: claude-sonnet-5-5, claude-haiku-5-5' ]
  # Copilot's session: the model of its first top-level message, and each subagent's from its completed event.
  cp .coding-crew/solve-feature/session.jsonl "$TEMP_DIR/claude-session.jsonl"
  cat > .coding-crew/solve-feature/session.jsonl <<'J'
{"type":"assistant.message","data":{"model":"claude-opus-5.5","content":"","parentToolCallId":"t1"}}
{"type":"assistant.message","data":{"model":"claude-sonnet-5.5","content":"Starting."}}
{"type":"subagent.completed","data":{"model":"claude-opus-5.5"}}
{"type":"subagent.completed","data":{"model":"claude-sonnet-5.5"}}
J
  : > "$GITHUB_STEP_SUMMARY"
  CREW_AGENT=copilot run bash -e "$TEMP_DIR/last-step.sh"
  [ "$(grep -A1 -xF -- '- Agent: copilot, model claude-sonnet-5.5' "$GITHUB_STEP_SUMMARY" | tail -n 1)" = \
    '- Subagent models: claude-opus-5.5, claude-sonnet-5.5' ]
  mv "$TEMP_DIR/claude-session.jsonl" .coding-crew/solve-feature/session.jsonl
  echo 'stopped: 2 checks failed: run-checks.sh exit 1' > .coding-crew/solve-feature/outcome
  echo 'FAIL: test_x' > .coding-crew/solve-feature/2.checks.log
  : > "$GITHUB_STEP_SUMMARY"
  run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stopped: 2 checks failed: run-checks.sh exit 1"* ]]
  grep -qxF 'report of the last coder' "$GITHUB_STEP_SUMMARY"
  grep -qxF 'FAIL: test_x' "$GITHUB_STEP_SUMMARY"
  # Each stop shows the files of the step it names: a coder's stop not an earlier issue's passing checks log, a
  # fix stop the PR's checks log and no coder's report.
  echo 'stopped: 3 solve failed: coder ran but did not close 3; why: x' > .coding-crew/solve-feature/outcome
  : > "$GITHUB_STEP_SUMMARY"
  run bash -e "$TEMP_DIR/last-step.sh"
  grep -qxF 'report of the last coder' "$GITHUB_STEP_SUMMARY"
  ! grep -q 'FAIL: test_x' "$GITHUB_STEP_SUMMARY" || false
  echo 'stopped:  fix failed: run-checks.sh exit 1; once fixed' > .coding-crew/solve-feature/outcome
  echo 'FAIL: test_after_fix' > .coding-crew/solve-feature/pr-10.checks.log
  : > "$GITHUB_STEP_SUMMARY"
  run bash -e "$TEMP_DIR/last-step.sh"
  grep -qxF 'FAIL: test_after_fix' "$GITHUB_STEP_SUMMARY"
  ! grep -q 'report of the last coder' "$GITHUB_STEP_SUMMARY" || false
  # git's reason for a refused workflow-file push quotes names in backticks: the heading stays one code span.
  line='stopped: 3 land push refused: refusing to allow a GitHub App to create or update workflow `.github/workflows/ci.yml` without `workflows` permission'
  echo "$line" > .coding-crew/solve-feature/outcome
  : > "$GITHUB_STEP_SUMMARY"
  run bash -e "$TEMP_DIR/last-step.sh"
  grep -qxF "### solve-feature feat: \`\` $line \`\`" "$GITHUB_STEP_SUMMARY"
  echo 'ready pr=10' > .coding-crew/solve-feature/outcome
  : > "$GITHUB_STEP_SUMMARY"
  run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ready pr=10"* ]]
  ! grep -q 'FAIL: test_x' "$GITHUB_STEP_SUMMARY" || false
}

@test "the reusable workflow: commits no push reached go into the artifact's unpushed.bundle, which the summary says how to fetch; a pushed run writes none" {
  local wf="$REPO_ROOT/.github/workflows/crew-solve-feature.yml" json="$TEMP_DIR/wf.json"
  run yaml_to_json "$wf" "$json"
  [ "$status" -ne 3 ] || skip "no YAML parser on this machine (node js-yaml or python3 PyYAML)"
  [ "$status" -eq 0 ]
  jq -e '.jobs.solve.steps[-3] | .name == "Bundle the unpushed commits" and .if == "always()"' "$json" >/dev/null
  jq -r '.jobs.solve.steps[-3].run' "$json" > "$TEMP_DIR/bundle-step.sh"
  jq -r '.jobs.solve.steps[-1].run' "$json" > "$TEMP_DIR/last-step.sh"
  export GITHUB_STEP_SUMMARY="$TEMP_DIR/summary.md" GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=o/r \
    GITHUB_RUN_ID=99 GITHUB_RUN_ATTEMPT=1 CREW_AGENT=claude CREW_MODEL= SLUG=feat

  run bash -e "$TEMP_DIR/bundle-step.sh"
  [ "$status" -eq 0 ]
  [ ! -e .coding-crew/solve-feature/unpushed.bundle ]
  echo 'stopped: 3 push failed: refused' > .coding-crew/solve-feature/outcome
  : > "$GITHUB_STEP_SUMMARY"
  run bash -e "$TEMP_DIR/last-step.sh"
  ! grep -q 'Unpushed commits' "$GITHUB_STEP_SUMMARY" || false

  git switch -q -c feature/feat
  echo x > x.txt && git add x.txt && git commit -q -m 'the coder'
  run bash -e "$TEMP_DIR/bundle-step.sh"
  [ "$status" -eq 0 ]
  [ "$(git bundle list-heads .coding-crew/solve-feature/unpushed.bundle)" = "$(git rev-parse HEAD) refs/heads/feature/feat" ]
  run bash -e "$TEMP_DIR/last-step.sh"
  grep -qF -- '- Unpushed commits: ' "$GITHUB_STEP_SUMMARY"
  grep -qF '`gh run download 99 -n solve-feature-feat-1 -D /tmp/sf-99 && git fetch /tmp/sf-99/unpushed.bundle '\''refs/heads/*:refs/heads/*'\''`, then run /solve-feature feat there' "$GITHUB_STEP_SUMMARY"
  # The fetch it prints recovers the branch in a clone that has only origin.
  git clone -q "$TEMP_DIR/origin.git" "$TEMP_DIR/clone"
  git -C "$TEMP_DIR/clone" fetch -q "$PWD/.coding-crew/solve-feature/unpushed.bundle" 'refs/heads/*:refs/heads/*'
  [ "$(git -C "$TEMP_DIR/clone" rev-parse feature/feat)" = "$(git rev-parse HEAD)" ]
}

@test "the reusable workflow: after the run, the runs held on the PR's head are approved, a refused one's workflow dispatched on the PR's branch instead, warning when both fail" {
  local wf="$REPO_ROOT/.github/workflows/crew-solve-feature.yml" json="$TEMP_DIR/wf.json"
  run yaml_to_json "$wf" "$json"
  [ "$status" -ne 3 ] || skip "no YAML parser on this machine (node js-yaml or python3 PyYAML)"
  [ "$status" -eq 0 ]
  # Its own job, after solve whatever solve's result, on the PR solve's outcome named.
  jq -e '.jobs["approve-ci"] | .needs == "solve" and (.if | startswith("always()"))
    and (.steps | length) == 1 and .steps[0].name == "Start the PR'"'"'s CI"
    and .steps[0].env.PR == "${{ needs.solve.outputs.pr }}"' "$json" >/dev/null
  [ "$(jq -r '.jobs.solve.outputs.pr' "$json")" = '${{ steps.outcome.outputs.pr }}' ]
  jq -r '.jobs["approve-ci"].steps[0].run' "$json" > "$TEMP_DIR/ci-step.sh"

  cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$STATE/gh.log"
case "$1 $2" in
  "pr view") echo "feature/$3 sha$3 ${GH_CROSS:-false} ${GH_BLOCK:-true}" ;;
  "api -X") [ -z "$GH_APPROVE_FAIL" ] || { echo "HTTP 403" >&2; exit 1; } ;;
  "api "*) [ -z "$GH_HELD" ] || printf '%s\n' "$GH_HELD" ;;
  "workflow run") [ -z "$GH_WF_FAIL" ] || { echo "HTTP 403" >&2; exit 1; } ;;
esac
SH
  chmod +x "$STUB/gh"
  mkdir -p .coding-crew/solve-feature
  export GITHUB_REPOSITORY=o/r GH_HELD=$'7 .github/workflows/ci.yml\n8 .github/workflows/lint.yml'

  export PR=12
  for line in 'ready pr=12' 'needs-attention pr=12'; do
    rm -f "$STATE/gh.log"
    run bash -e "$TEMP_DIR/ci-step.sh"
    [ "$status" -eq 0 ]
    grep -q 'gh api repos/o/r/actions/runs?head_sha=sha12&event=pull_request&status=action_required' "$STATE/gh.log"
    [ "$(grep -c 'api -X POST' "$STATE/gh.log")" -eq 2 ]
    grep -q 'api -X POST repos/o/r/actions/runs/7/approve' "$STATE/gh.log"
    grep -q 'api -X POST repos/o/r/actions/runs/8/approve' "$STATE/gh.log"
    ! grep -q 'workflow run' "$STATE/gh.log" || false
  done

  rm -f "$STATE/gh.log"
  GH_APPROVE_FAIL=1 run bash -e "$TEMP_DIR/ci-step.sh"
  [ "$status" -eq 0 ]
  [ "$(grep 'workflow run' "$STATE/gh.log")" = $'gh workflow run ci.yml --ref feature/12\ngh workflow run lint.yml --ref feature/12' ]
  [[ "$output" == *"::warning::could not approve ci.yml"* ]]

  GH_APPROVE_FAIL=1 GH_WF_FAIL=1 run bash -e "$TEMP_DIR/ci-step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::could not approve or dispatch lint.yml"* ]]

  rm -f "$STATE/gh.log"
  GH_HELD= run bash -e "$TEMP_DIR/ci-step.sh"
  [ "$status" -eq 0 ]
  ! grep -q 'api -X POST\|workflow run' "$STATE/gh.log" || false

  # The agent wrote the outcome: a fork's PR, or one with no solve-feature block, gets no approval or dispatch.
  local v
  for v in GH_CROSS=true GH_BLOCK=false; do
    rm -f "$STATE/gh.log"
    run env $v bash -e "$TEMP_DIR/ci-step.sh"
    [ "$status" -eq 0 ] && [[ "$output" == *"::warning::PR #12 is not a solve-feature PR from this repo"* ]]
    ! grep -q 'actions/runs\|workflow run' "$STATE/gh.log" || false
  done
}

@test "the reusable workflow: the outcome step gives solve's outputs, the PR of any outcome naming one and ready only for ready pr=<n>" {
  local wf="$REPO_ROOT/.github/workflows/crew-solve-feature.yml" json="$TEMP_DIR/wf.json"
  run yaml_to_json "$wf" "$json"
  [ "$status" -ne 3 ] || skip "no YAML parser on this machine (node js-yaml or python3 PyYAML)"
  [ "$status" -eq 0 ]
  jq -e '.jobs.solve.outputs.ready == "${{ steps.outcome.outputs.ready }}"
    and (.jobs.solve.steps[] | select(.id == "outcome") | .if == "always()")' "$json" >/dev/null
  jq -r '.jobs.solve.steps[] | select(.id == "outcome") | .run' "$json" > "$TEMP_DIR/outcome-step.sh"
  export GITHUB_OUTPUT="$TEMP_DIR/out"
  mkdir -p .coding-crew/solve-feature
  local line want
  for line in 'ready pr=12|pr=12 ready=true' 'needs-attention pr=12|pr=12 ready=false' \
    'stopped: 2 checks failed: x|pr= ready=false' '|pr= ready=false'; do
    want=${line#*|} line=${line%%|*}
    rm -f .coding-crew/solve-feature/outcome; : > "$GITHUB_OUTPUT"
    [ -z "$line" ] || echo "$line" > .coding-crew/solve-feature/outcome
    run bash -e "$TEMP_DIR/outcome-step.sh"
    [ "$status" -eq 0 ]
    [ "$(tr '\n' ' ' < "$GITHUB_OUTPUT")" = "$want " ] || { echo "$line: $(cat "$GITHUB_OUTPUT")"; return 1; }
  done
}

@test "the reusable workflow's run step passes Claude Code each ANTHROPIC_DEFAULT_*_MODEL repo variable only when it is set" {
  local wf="$REPO_ROOT/.github/workflows/crew-solve-feature.yml" json="$TEMP_DIR/wf.json" v
  run yaml_to_json "$wf" "$json"
  [ "$status" -ne 3 ] || skip "no YAML parser on this machine (node js-yaml or python3 PyYAML)"
  [ "$status" -eq 0 ]
  for v in HAIKU SONNET OPUS; do
    jq -e --arg v "ANTHROPIC_DEFAULT_${v}_MODEL" '.jobs.solve.steps[] | select(.name == "Run solve-feature")
      | .env[$v] == "${{ vars.\($v) }}"' "$json" >/dev/null || { echo "$v"; return 1; }
  done
  jq -r '.jobs.solve.steps[] | select(.name == "Run solve-feature") | .run' "$json" > "$TEMP_DIR/run-step.sh"
  printf '#!/usr/bin/env bash\nenv | grep -E "^ANTHROPIC_DEFAULT_" | sort\n' > "$STUB/claude"
  chmod +x "$STUB/claude"
  run env CREW_AGENT=claude CREW_MODEL= SLUG=feat ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN=tok \
    ANTHROPIC_DEFAULT_HAIKU_MODEL= ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5-5 ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-5-5[1m]' \
    bash -e "$TEMP_DIR/run-step.sh"
  [ "$status" -eq 0 ]
  [ "$(cat .coding-crew/solve-feature/session.jsonl)" = "$(printf '%s\n' 'ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-5-5[1m]' 'ANTHROPIC_DEFAULT_SONNET_MODEL=claude-sonnet-5-5')" ]
}

@test "the install action is a composite whose one step installs solve-feature, crew-review and address-pr-comments into \$HOME from the action's own repo" {
  local action="$REPO_ROOT/actions/install/action.yml" json="$TEMP_DIR/action.json" a
  run yaml_to_json "$action" "$json"
  [ "$status" -ne 3 ] || skip "no YAML parser on this machine (node js-yaml or python3 PyYAML)"
  [ "$status" -eq 0 ]
  jq -e '.runs.using == "composite" and (.runs.steps | length) == 1 and .runs.steps[0].shell == "bash"
    and .inputs.agent.required == true and .runs.steps[0].env.CREW_AGENT == "${{ inputs.agent }}"' "$json" >/dev/null
  jq -r '.runs.steps[0].run' "$json" > "$TEMP_DIR/install-action.sh"
  grep -qF '"$GITHUB_ACTION_PATH/../../install.sh"' "$TEMP_DIR/install-action.sh"
  for a in claude copilot; do
    local home="$TEMP_DIR/home-$a"
    mkdir -p "$home"
    run env -u TARGET_REPO HOME="$home" GITHUB_ACTION_PATH="$REPO_ROOT/actions/install" CREW_AGENT="$a" bash -e "$TEMP_DIR/install-action.sh"
    [ "$status" -eq 0 ] || { echo "$a: $output"; return 1; }
    local s
    for s in solve-feature crew-review address-pr-comments coding-crew-lib; do
      [ -n "$(find "$home" -path "*/skills/$s/SKILL.md" | head -n 1)" ] || { echo "$a: no $s under $home"; find "$home" -maxdepth 3; return 1; }
    done
  done
}

# wf_json — the reusable workflow as $JSON, or skips the test when the machine has no YAML parser.
wf_json() {
  WF="$REPO_ROOT/.github/workflows/crew-solve-feature.yml" JSON="$TEMP_DIR/wf.json"
  run yaml_to_json "$WF" "$JSON"
  [ "$status" -ne 3 ] || skip "no YAML parser on this machine (node js-yaml or python3 PyYAML)"
  [ "$status" -eq 0 ]
}
# solve_step <name> — the solve job's step of that name's run script, into $TEMP_DIR/step.sh.
solve_step() {
  jq -r --arg n "$1" '.jobs.solve.steps[] | select(.name == $n) | .run' "$JSON" > "$TEMP_DIR/step.sh"
  [ -s "$TEMP_DIR/step.sh" ]
}

@test "the reusable workflow: per-job permissions, actions: write only on approve-ci, id-token: write only on solve; every outside action pinned by SHA" {
  wf_json
  [ "$(jq 'has("permissions")' "$JSON")" = false ]
  [ "$(jq -c '[.jobs | to_entries[] | select(.value.permissions.actions == "write") | .key]' "$JSON")" = '["approve-ci"]' ]
  [ "$(jq -c '[.jobs | to_entries[] | select(.value.permissions["id-token"] == "write") | .key]' "$JSON")" = '["solve"]' ]
  [ "$(jq -c '[.jobs | to_entries[] | select(.value.permissions == null) | .key]' "$JSON")" = '[]' ]
  [ "$(jq -c '.jobs.solve.permissions' "$JSON")" = '{"contents":"write","issues":"write","pull-requests":"write","copilot-requests":"write","id-token":"write"}' ]
  [ "$(jq -c '.jobs.slug.permissions' "$JSON")" = '{"issues":"write"}' ]
  [ "$(jq -r '.jobs["request-copilot-review"].permissions | to_entries | map("\(.key)=\(.value)") | join(",")' "$JSON")" = 'pull-requests=read' ]
  # A tag can move; a commit cannot. The tag stays readable in the comment.
  local n=0 line
  while read -r line; do
    n=$((n + 1))
    [[ "$line" =~ uses:\ [a-z-]+/[a-z-]+@[0-9a-f]{40}\ \#\ v[0-9] ]] || { echo "unpinned: $line"; return 1; }
  done < <(grep -E '^ *(- )?uses:' "$WF" | grep -v 'ypxing/coding-crew/')
  [ "$n" -eq 4 ]
  for a in actions/checkout actions/setup-node actions/upload-artifact aws-actions/configure-aws-credentials; do
    grep -qE "uses: $a@[0-9a-f]{40} # v" "$WF" || { echo "$a"; return 1; }
  done
}

@test "the reusable workflow: NPM_TOKEN only in the install step before the agent, which runs dev-commands.json's install in host mode and skips saying why otherwise" {
  wf_json
  local name="Install the project's dependencies"
  [ "$(jq -c '[.jobs[].steps[] | select(tostring | test("secrets.NPM_TOKEN")) | .name]' "$JSON")" = "[\"$name\"]" ]
  jq -e --arg n "$name" '.jobs.solve.steps[] | select(.name == $n) | .env == {"NPM_TOKEN": "${{ secrets.NPM_TOKEN }}"}' "$JSON" >/dev/null
  [ "$(jq -r --arg n "$name" '.jobs.solve.steps | map(.name) | (index($n) != null) and (index($n) < index("Run solve-feature"))' "$JSON")" = true ]
  solve_step "$name"
  ! grep -q 'registry_auth\|\.env\b' "$TEMP_DIR/step.sh" || false

  rm -f .coding-crew/dev-commands.json
  run env NPM_TOKEN=t bash -e "$TEMP_DIR/step.sh"
  [ "$status" -eq 0 ] && [[ "$output" == *"No .coding-crew/dev-commands.json: skipped"* ]]
  mkdir -p .coding-crew
  echo '{"test":"x","install":null,"registry_auth":"touch registry-auth-ran"}' > .coding-crew/dev-commands.json
  run env NPM_TOKEN=t bash -e "$TEMP_DIR/step.sh"
  [ "$status" -eq 0 ] && [[ "$output" == *"no install command: skipped"* ]]
  [ ! -e registry-auth-ran ]
  echo '{"install":"echo \"token=$NPM_TOKEN\" > \"$STATE/installed\"","install_mode":"docker"}' > .coding-crew/dev-commands.json
  run env NPM_TOKEN=t bash -e "$TEMP_DIR/step.sh"
  [ "$status" -eq 0 ] && [[ "$output" == *"::notice::"*"install_mode docker: skipped"* ]]
  [ ! -e "$STATE/installed" ]
  # Host mode runs the raw install with the token, never registry_auth; a failed install fails the job before the agent.
  echo '{"install":"echo \"token=$NPM_TOKEN\" > \"$STATE/installed\"","install_mode":"host","registry_auth":"touch \"$STATE/registry-auth-ran\""}' > .coding-crew/dev-commands.json
  run env NPM_TOKEN=t bash -e "$TEMP_DIR/step.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/installed")" = token=t ]
  [ ! -e "$STATE/registry-auth-ran" ]
  # solve-feature refuses a dirty tree: a rewritten lockfile and an untracked output are dropped, ignored files kept.
  echo node_modules/ > .gitignore && echo '{}' > package-lock.json
  echo '{"install":"echo rewritten > package-lock.json && mkdir -p node_modules && touch node_modules/dep stray"}' > .coding-crew/dev-commands.json
  git add -f .gitignore package-lock.json .coding-crew/dev-commands.json && git commit -q -m deps
  run env NPM_TOKEN= bash -e "$TEMP_DIR/step.sh"
  [ "$status" -eq 0 ]
  [ -z "$(git status --porcelain)" ]
  [ "$(cat package-lock.json)" = '{}' ] && [ -f node_modules/dep ] && [ ! -e stray ]
  echo '{"install":"exit 7"}' > .coding-crew/dev-commands.json
  run env NPM_TOKEN= bash -e "$TEMP_DIR/step.sh"
  [ "$status" -eq 7 ]
}

@test "the reusable workflow: a review round installs on the default branch, then hands the agent the PR's branch, past address-pr-comments' branch check" {
  wf_json
  # pull_request_review's github.ref is refs/pull/<n>/merge: the feature branch the agent wrote, merged in, which the
  # NPM_TOKEN install must not run.
  [ "$(jq -r '.jobs.solve.steps[] | select(.uses // "" | startswith("actions/checkout@")) | .with.ref' "$JSON")" = \
    "\${{ github.event_name == 'pull_request_review' && github.event.repository.default_branch || '' }}" ]
  local names; names=$(jq -r '.jobs.solve.steps[].name // empty' "$JSON")
  local install switch run
  install=$(grep -nxF "Install the project's dependencies" <<<"$names" | cut -d: -f1)
  switch=$(grep -nxF "Check out the review round's PR branch" <<<"$names" | cut -d: -f1)
  run=$(grep -nxF "Run solve-feature" <<<"$names" | cut -d: -f1)
  [ -n "$switch" ]
  [ "$install" -lt "$switch" ]
  [ "$switch" -lt "$run" ]
  local step; step=$(jq -c '.jobs.solve.steps[] | select(.name == "Check out the review round'"'"'s PR branch")' "$JSON")
  [ "$(jq -r '.if' <<<"$step")" = "github.event_name == 'pull_request_review'" ]
  [ "$(jq -r '.env.HEAD_REF' <<<"$step")" = '${{ github.event.pull_request.head.ref }}' ]
  jq -r '.run' <<<"$step" > "$TEMP_DIR/switch.sh"

  # What actions/checkout leaves for ref: main (git checkout -B main refs/remotes/origin/main), after the install.
  local GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  git init -q -b main "$TEMP_DIR/origin" && echo '{}' > "$TEMP_DIR/origin/package-lock.json"
  git -C "$TEMP_DIR/origin" add . && git -C "$TEMP_DIR/origin" commit -q -m init
  git -C "$TEMP_DIR/origin" checkout -q -b feature/x && echo pr > "$TEMP_DIR/origin/pr.txt"
  git -C "$TEMP_DIR/origin" add pr.txt && git -C "$TEMP_DIR/origin" commit -q -m pr && git -C "$TEMP_DIR/origin" checkout -q main
  git clone -q "$TEMP_DIR/origin" "$TEMP_DIR/ws" && cd "$TEMP_DIR/ws"
  git remote set-head origin -d
  mkdir node_modules && touch node_modules/dep && echo '{"rewritten":1}' > package-lock.json
  local check="$REPO_ROOT/lib/git-workflow/branch-safety-check.sh"
  run bash "$check"
  [ "$status" -eq 1 ]
  run env HEAD_REF=feature/x bash -e "$TEMP_DIR/switch.sh"
  [ "$status" -eq 0 ]
  [ "$(git rev-parse --abbrev-ref HEAD)" = feature/x ]
  [ -f pr.txt ]
  [ -f node_modules/dep ]
  [ -z "$(git status --porcelain --untracked-files=no)" ]
  [ "$(git rev-parse --abbrev-ref '@{upstream}')" = origin/feature/x ]
  run bash "$check"
  [ "$status" -eq 0 ]
}

@test "the reusable workflow's run step hides the OIDC request variables from either agent; no step after it in solve references a secret, COPILOT_GITHUB_TOKEN only in request-copilot-review" {
  wf_json
  solve_step "Run solve-feature"
  local a
  for a in copilot claude; do
    # Its parent's /proc environ too: an `unset` leaves the variables there, readable by any child (Linux only).
    printf '#!/usr/bin/env bash\n{ env; [ ! -r /proc/$PPID/environ ] || tr "\\\\0" "\\\\n" < /proc/$PPID/environ; } | grep -E "^ACTIONS_ID_TOKEN_REQUEST_" | sort; echo end\n' > "$STUB/$a" && chmod +x "$STUB/$a"
  done
  run env ACTIONS_ID_TOKEN_REQUEST_TOKEN=tok ACTIONS_ID_TOKEN_REQUEST_URL=https://x CREW_AGENT=copilot CREW_MODEL= SLUG=feat bash -e "$TEMP_DIR/step.sh"
  [ "$status" -eq 0 ]
  [ "$(cat .coding-crew/solve-feature/session.jsonl)" = end ]
  run env ACTIONS_ID_TOKEN_REQUEST_TOKEN=tok ACTIONS_ID_TOKEN_REQUEST_URL=https://x CREW_AGENT=claude CREW_MODEL= SLUG=feat CLAUDE_CODE_OAUTH_TOKEN=t bash -e "$TEMP_DIR/step.sh"
  [ "$status" -eq 0 ]
  [ "$(cat .coding-crew/solve-feature/session.jsonl)" = end ]

  local i; i="$(jq '.jobs.solve.steps | map(.name) | index("Run solve-feature")' "$JSON")"
  [ "$(jq -c ".jobs.solve.steps[$i + 1:] | map(select(tostring | test(\"secrets[.]\"))) | map(.name)" "$JSON")" = '[]' ]
  [ "$(jq -c '[.jobs | to_entries[] | select(.value | tostring | test("secrets.COPILOT_GITHUB_TOKEN")) | .key]' "$JSON")" = '["request-copilot-review"]' ]
  jq -e '.jobs["request-copilot-review"] | .needs == "solve" and (.if | startswith("always()"))
    and .steps[0].env.PR == "${{ needs.solve.outputs.pr }}" and .steps[0].env.READY == "${{ needs.solve.outputs.ready }}"' "$JSON" >/dev/null
}

@test "the reusable workflow on Bedrock: the provider check, the role assumed for the job's timeout before the agent, and claude on Bedrock with no Anthropic secret" {
  wf_json
  jq -e '.jobs.solve.env | .CREW_CLAUDE_PROVIDER == "${{ vars.CREW_CLAUDE_PROVIDER }}"
    and .CREW_AWS_ROLE_ARN == "${{ vars.CREW_AWS_ROLE_ARN }}" and .CREW_AWS_REGION == "${{ vars.CREW_AWS_REGION }}"' "$JSON" >/dev/null
  local names; names="$(jq -c '.jobs.solve.steps | map(.name)' "$JSON")"
  local aws; aws="$(jq -c '.jobs.solve.steps[] | select((.uses // "") | startswith("aws-actions/configure-aws-credentials@"))' "$JSON")"
  jq -e '.if == "env.CREW_CLAUDE_PROVIDER == '"'bedrock'"' && env.CREW_AGENT == '"'claude'"'"
    and .with["role-to-assume"] == "${{ vars.CREW_AWS_ROLE_ARN }}" and .with["aws-region"] == "${{ vars.CREW_AWS_REGION }}"
    and .with["role-duration-seconds"] == "${{ steps.provider.outputs.duration }}"' <<<"$aws" >/dev/null
  [ "$(jq -r '(index("Check the Claude provider") < index("AWS credentials for Bedrock")) and (index("AWS credentials for Bedrock") < index("Run solve-feature"))' <<<"$names")" = true ]
  jq -e '.jobs.solve.steps[] | select(.id == "provider") | .env.TIMEOUT_MINUTES == "${{ inputs.timeout-minutes }}"' "$JSON" >/dev/null

  jq -r '.jobs.solve.steps[] | select(.id == "provider") | .run' "$JSON" > "$TEMP_DIR/provider.sh"
  export GITHUB_OUTPUT="$TEMP_DIR/out"
  : > "$GITHUB_OUTPUT"
  run env CREW_CLAUDE_PROVIDER=bedrock CREW_AGENT=claude CREW_AWS_ROLE_ARN=arn:aws:iam::1:role/r CREW_AWS_REGION=us-east-1 TIMEOUT_MINUTES=75 bash -e "$TEMP_DIR/provider.sh"
  [ "$status" -eq 0 ] && [[ "$output" != *"::error::"* ]]
  [ "$(cat "$GITHUB_OUTPUT")" = duration=4500 ]
  run env CREW_CLAUDE_PROVIDER=bedrock CREW_AGENT=copilot CREW_AWS_ROLE_ARN=a CREW_AWS_REGION=r TIMEOUT_MINUTES=360 bash -e "$TEMP_DIR/provider.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"::error::"*"CREW_AGENT is 'copilot'"* ]]
  run env CREW_CLAUDE_PROVIDER=bedrock CREW_AGENT=claude CREW_AWS_ROLE_ARN= CREW_AWS_REGION=r TIMEOUT_MINUTES=360 bash -e "$TEMP_DIR/provider.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"::error::"*"CREW_AWS_ROLE_ARN"* ]] && [[ "$output" != *"CREW_AWS_REGION"* ]]
  run env CREW_CLAUDE_PROVIDER=bedrock CREW_AGENT=claude CREW_AWS_ROLE_ARN=a CREW_AWS_REGION= TIMEOUT_MINUTES=360 bash -e "$TEMP_DIR/provider.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"::error::"*"CREW_AWS_REGION"* ]]
  : > "$GITHUB_OUTPUT"
  run env CREW_CLAUDE_PROVIDER= CREW_AGENT=copilot bash -e "$TEMP_DIR/provider.sh"
  [ "$status" -eq 0 ] && [ ! -s "$GITHUB_OUTPUT" ]

  solve_step "Run solve-feature"
  printf '#!/usr/bin/env bash\nenv | grep -E "^(CLAUDE_CODE_USE_BEDROCK|AWS_REGION|ANTHROPIC_API_KEY|CLAUDE_CODE_OAUTH_TOKEN)=" | sort\n' > "$STUB/claude"
  chmod +x "$STUB/claude"
  run env CREW_CLAUDE_PROVIDER=bedrock CREW_AWS_REGION=eu-west-1 CREW_AGENT=claude CREW_MODEL= SLUG=feat ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN= bash -e "$TEMP_DIR/step.sh"
  [ "$status" -eq 0 ] && [[ "$output" != *"::error::"* ]]
  [ "$(cat .coding-crew/solve-feature/session.jsonl)" = "$(printf '%s\n' AWS_REGION=eu-west-1 CLAUDE_CODE_USE_BEDROCK=1)" ]
  # Unset, the Anthropic secret is still required.
  run env CREW_CLAUDE_PROVIDER= CREW_AGENT=claude CREW_MODEL= SLUG=feat ANTHROPIC_API_KEY= CLAUDE_CODE_OAUTH_TOKEN= bash -e "$TEMP_DIR/step.sh"
  [ "$status" -ne 0 ] && [[ "$output" == *"needs the repo secret ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"* ]]
}
