#!/usr/bin/env bats

# afk-feature.sh — one feature's ready issues, in order, on one branch, each gated by checks and a
# verifier the coder cannot influence.
#
# A temp clone with a bare `origin`, and the skill installed user-level under a temp $HOME as
# install.sh lays it out. `claude`, `gh`, `node` (only for the tracker CLI's path; everything else
# reaches the real node), `timeout` and solve-issue's run-checks.sh are stubs that log their argv:
# the coder stub commits a file and swaps the issue's ready-for-agent label for awaiting-merge,
# as solve-issue's mark-done does; the verifier stub writes the report its prompt names.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
  TEMP_DIR=$(mktemp -d)
  export STATE="$TEMP_DIR/state" HOME="$TEMP_DIR/home" AFK_HOST=test-host
  mkdir -p "$STATE" "$HOME"
  unset AFK_SANDBOXED CREW_ORCHESTRATED

  INSTALL="$HOME/.coding-crew"
  mkdir -p "$INSTALL/afk-feature" "$INSTALL/solve-issue/scripts" "$INSTALL/dep-install/scripts" "$INSTALL/tracker"
  cp -R "$REPO_ROOT/skills/afk-feature/scripts" "$INSTALL/afk-feature/scripts"
  mkdir -p "$INSTALL/afk-feature/roles"
  cp "$REPO_ROOT/orchestrator/roles/reviewer.md" "$INSTALL/afk-feature/roles/reviewer.md"
  cp -R "$REPO_ROOT/orchestrator/roles/reviewer" "$INSTALL/afk-feature/roles/reviewer"
  : > "$INSTALL/tracker/cli.mjs"
  SCRIPT="$INSTALL/afk-feature/scripts/afk-feature.sh"

  WORK="$TEMP_DIR/work"
  git init -q -b main "$WORK"
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name test
  mkdir -p "$WORK/.coding-crew"
  echo '{"tracker":{"kind":"github"}}' > "$WORK/.coding-crew/config.json"
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m init
  git clone -q --bare "$WORK" "$TEMP_DIR/origin.git"
  git -C "$WORK" remote add origin "$TEMP_DIR/origin.git"
  git -C "$WORK" fetch -q origin
  git -C "$WORK" remote set-head origin main
  git -C "$WORK" branch -q -u origin/main

  STUB="$TEMP_DIR/stub"
  mkdir -p "$STUB"
  REAL_NODE="$(command -v node)"
  write_stubs
  export PATH="$STUB:$PATH"

  # Feature `feat`: root #1 (the PRD), work issues #2 and #3 ready.
  issues '[{"number":1,"title":"PRD: Feat","state":"OPEN","labels":[],"root":true},
           {"number":3,"title":"Three","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":2,"title":"Two","state":"OPEN","labels":[{"name":"ready-for-agent"}]}]'
  issue_body 2 "None - can start immediately"
  issue_body 3 "None - can start immediately"
  echo "# PRD: Feat" > "$STATE/prd.md"
  echo '[]' > "$STATE/comments.json"
  cd "$WORK"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

issues() { printf '%s\n' "$1" > "$STATE/issues.json"; }

# issue_body <n> <Blocked by text>
issue_body() {
  printf '# Issue %s\n\n## What to build\n\nx\n\n## Acceptance criteria\n\n- [ ] works for `<before>` & co\n\n## Blocked by\n\n%s\n' "$1" "$2" > "$STATE/$1.md"
}

write_stubs() {
  cat > "$STUB/node" <<EOF
#!/usr/bin/env bash
case "\$1" in */.coding-crew/tracker/cli.mjs) ;; *) exec "$REAL_NODE" "\$@" ;; esac
printf '%s\n' "\${*:2}" >> "\$STATE/node.log"
case "\$2" in
  config) echo "tracker=\${TRACKER_KIND:-github}"; echo configured=yes ;;
  feature-issues) cat "\$STATE/issues.json" ;;
  fetch) cat "\$STATE/\$3.md" ;;
  prd) [ -f "\$STATE/prd.md" ] || exit 3; cat "\$STATE/prd.md" ;;
  closing-refs) jq -r 'sort_by(.number) | .[] | select(.state == "OPEN" and any(.labels[]; .name == "awaiting-merge")) | "Closes #\(.number)"' "\$STATE/issues.json" ;;
  *) exit 2 ;;
esac
EOF

  cat > "$STUB/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF

  # Each call's argv, one arg per line, in claude.<k>; the verifier is the call with a system prompt file.
  cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
k=$(( $(ls "$STATE" | grep -c '^claude\.[0-9]*$') + 1 ))
printf '%s\n' "$@" > "$STATE/claude.$k"
env | grep -c '^CREW_ORCHESTRATED=' > "$STATE/claude.$k.env" || true
git branch --show-current > "$STATE/claude.$k.branch"
git ls-remote --heads origin "$(git branch --show-current)" | grep -c . > "$STATE/claude.$k.pushed" || true
git rev-parse --abbrev-ref '@{upstream}' > "$STATE/claude.$k.upstream" 2>/dev/null || true
prompt="$2"
if printf '%s\n' "$@" | grep -qx -- --append-system-prompt-file; then
  report=$(printf '%s\n' "$prompt" | sed -n 's/^Write your structured verdict to \(.*\) as your last action\..*/\1/p')
  [ -n "${VERIFIER_NO_REPORT:-}" ] || printf '{"verdict":"%s","detail":"criterion 1 unmet"}\n' "${VERDICT:-all-met}" > "$report"
  [ -z "${VERIFIER_DIRTY:-}" ] || echo dirt > verifier-dirt.txt
  [ -z "${VERIFIER_COMMIT:-}" ] || git commit -q --allow-empty -m "verifier wrote"
  exit 0
fi
n="${prompt#/solve-issue }"
echo "coder log for #$n"
[ -z "${CODER_EXIT:-}" ] || { for i in $(seq 1 30); do echo "coder line $i"; done; exit "$CODER_EXIT"; }
[ -z "${CODER_SWITCH:-}" ] || git checkout -q -b elsewhere
echo "$n" > "work-$n.txt"
[ -n "${CODER_DIRTY:-}" ] || { git add "work-$n.txt"; git commit -q -m "[$n] work"; }
[ -n "${CODER_NO_CLOSE:-}" ] && exit 0
jq --argjson n "$n" 'map(if .number == $n then .labels = [{"name":"awaiting-merge"}] else . end)' "$STATE/issues.json" > "$STATE/i.tmp"
mv "$STATE/i.tmp" "$STATE/issues.json"
EOF

  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATE/gh.log"
[ -z "${GH_API_FAIL:-}" ] || [ "$1" != api ] || exit 1
body=""; patch=""; path=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -f) body="${args[$((i + 1))]#body=}" ;;
    -X) patch="${args[$((i + 1))]}" ;;
    repos/*) path="${args[$i]}" ;;
  esac
done
case "$1 $2" in
  "pr view") [ -n "${PR_EXISTS:-}" ] || exit 1; [[ "$*" == *url* ]] && echo "https://github.com/o/r/pull/9" || echo '{"number":9}' ;;
  "pr create") printf '%s' "${args[$((${#args[@]} - 1))]}" > "$STATE/pr-body"; echo "https://github.com/o/r/pull/10" ;;
  api*)
    if [ "$patch" = PATCH ]; then
      id="${path##*/}"
      jq --argjson id "$id" --arg b "$body" 'map(if .id == $id then .body = $b else . end)' "$STATE/comments.json" > "$STATE/c.tmp"
      mv "$STATE/c.tmp" "$STATE/comments.json"
    elif [ -n "$body" ]; then
      id=$(( 100 + $(jq length "$STATE/comments.json") ))
      jq --argjson id "$id" --arg b "$body" '. + [{"id": $id, "body": $b}]' "$STATE/comments.json" > "$STATE/c.tmp"
      mv "$STATE/c.tmp" "$STATE/comments.json"
      echo "{\"id\": $id}"
    else
      cat "$STATE/comments.json"
    fi ;;
  *) exit 1 ;;
esac
EOF

  cat > "$HOME/.coding-crew/solve-issue/scripts/run-checks.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATE/checks.log"
echo "=== test: make test"
echo "test: ${CHECK_RESULT:-pass}"
echo "lint: NOT RUN: no command found"
[ "${CHECKS_RC:-0}" != 3 ] || { echo DISCOVER; exit 3; }
[ "${CHECKS_RC:-0}" = 0 ] && echo "CHECKS: pass" || echo "CHECKS: fail"
exit "${CHECKS_RC:-0}"
EOF
  chmod +x "$STUB"/* "$HOME/.coding-crew/solve-issue/scripts/run-checks.sh"
}

# claude_call <k> — the k-th claude argv, one arg per line.
claude_call() { cat "$STATE/claude.$1"; }
claude_calls() { ls "$STATE" | grep -c '^claude\.[0-9]*$' || true; }
# The value after flag $2 in claude call $1.
claude_flag() { claude_call "$1" | grep -A1 -x -- "$2" | tail -1; }

# --- preconditions -------------------------------------------------------------------

@test "a missing tool, a non-github tracker, an invalid slug or a dirty tree exits 1 before any checkout, claude or gh" {
  local tool
  for tool in claude gh jq timeout; do
    local bin="$TEMP_DIR/bin-$tool"
    mkdir -p "$bin"
    for t in bash env git node jq gh claude timeout dirname cat grep sed awk mkdir hostname date head tail tr printf rm; do
      [ "$t" = "$tool" ] && continue
      p=$(PATH="$STUB:$PATH" command -v "$t") && ln -sf "$p" "$bin/$t"
    done
    PATH="$bin" run "$bin/bash" "$SCRIPT" feat
    [ "$status" -eq 1 ] || { echo "$tool: status $status"; return 1; }
    [[ "$output" == *"$tool"* ]] || { echo "$tool: $output"; return 1; }
  done

  TRACKER_KIND=local run bash "$SCRIPT" feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"tracker=local"* ]]

  run bash "$SCRIPT" '../x'
  [ "$status" -eq 1 ]
  [[ "$output" == *"slug"* ]]

  echo dirt > dirt.txt
  run bash "$SCRIPT" feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"clean"* ]]

  [ "$(git branch --show-current)" = main ]
  [ "$(claude_calls)" -eq 0 ]
  [ ! -f "$STATE/gh.log" ]
}

# --- branch ------------------------------------------------------------------------

@test "on the default branch it creates feature/<slug> from origin/main and pushes it with upstream before the first claude call" {
  git commit -q --allow-empty -m "local only, not on origin"
  run bash "$SCRIPT" feat
  [ "$(cat "$STATE/claude.1.branch")" = feature/feat ]
  [ "$(cat "$STATE/claude.1.pushed")" = 1 ]
  [ "$(cat "$STATE/claude.1.upstream")" = origin/feature/feat ]
  [ "$(git merge-base feature/feat main)" = "$(git rev-parse origin/main)" ]
  [ "$(git rev-parse main)" != "$(git rev-parse origin/main)" ]
}

@test "--branch names the branch made from the default branch, and an existing one is checked out as it was left" {
  git branch mine origin/main
  git checkout -q mine && git commit -q --allow-empty -m "earlier run" && git checkout -q main
  local tip; tip=$(git rev-parse mine)
  run bash "$SCRIPT" feat --branch mine
  [ "$(cat "$STATE/claude.1.branch")" = mine ]
  git merge-base --is-ancestor "$tip" mine
}

@test "a branch only on origin is checked out tracking it" {
  git push -q origin origin/main:refs/heads/remote-only
  git fetch -q origin
  run bash "$SCRIPT" feat --branch remote-only
  [ "$(cat "$STATE/claude.1.branch")" = remote-only ]
  [ "$(cat "$STATE/claude.1.upstream")" = origin/remote-only ]
}

@test "on another branch it uses that branch, ignoring --branch" {
  git checkout -q -b topic
  run bash "$SCRIPT" feat --branch other
  [ "$(cat "$STATE/claude.1.branch")" = topic ]
  [ "$(git branch --show-current)" = topic ]
  ! git show-ref --verify -q refs/heads/other
  ! git show-ref --verify -q refs/heads/feature/feat
}

# --- selection -----------------------------------------------------------------------

# coder_issues — the issue numbers the coder was run on, in order.
coder_issues() {
  local k
  for k in $(seq 1 "$(claude_calls)"); do
    claude_call "$k" | grep -qx -- --append-system-prompt-file || claude_flag "$k" -p | sed 's|^/solve-issue ||'
  done | paste -sd' ' -
}

@test "issues run lowest number first, skipping the root, closed issues and any whose blocker is neither CLOSED nor awaiting-merge" {
  issues '[{"number":1,"title":"PRD: Feat","state":"OPEN","labels":[{"name":"ready-for-agent"}],"root":true},
           {"number":7,"title":"Seven","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":3,"title":"Three","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":2,"title":"Two","state":"CLOSED","labels":[{"name":"ready-for-agent"}]},
           {"number":4,"title":"Four","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":5,"title":"Five","state":"OPEN","labels":[{"name":"ready-for-human"}]},
           {"number":6,"title":"Six","state":"OPEN","labels":[{"name":"ready-for-agent"}]}]'
  issue_body 3 "- Issue #2"
  issue_body 4 "- Issue #5"
  issue_body 6 "- Issue #99"
  issue_body 7 "- Issue #3"
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(coder_issues)" = "3 7" ]
}

@test "the same issue selected twice in a row stops: coder ran but did not close #<n>" {
  CODER_NO_CLOSE=1 run bash "$SCRIPT" feat
  [ "$status" -ne 0 ]
  [[ "$output" == *"coder ran but did not close #2"* ]]
  [ "$(coder_issues)" = "2" ]
}

# --- the gate ------------------------------------------------------------------------

@test "after the coder the script runs run-checks.sh, then a read-only verifier whose prompt names the issue file, the diff and the report" {
  local base; base=$(git rev-parse origin/main)
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(claude_calls)" -eq 4 ]
  [ "$(head -1 "$STATE/checks.log")" = "--project-root $WORK --main-root $WORK --dep-scripts $HOME/.coding-crew/dep-install/scripts" ]
  [ "$(wc -l < "$STATE/checks.log")" -eq 2 ]

  claude_call 2 | grep -qx -- --append-system-prompt-file
  [[ "$(claude_flag 2 --append-system-prompt-file)" == */roles/reviewer.md ]]
  [ -f "$(claude_flag 2 --append-system-prompt-file)" ]
  [ "$(claude_call 2 | grep -A3 -x -- --tools | tail -3 | paste -sd' ' -)" = "Bash Read ToolSearch" ]
  [ "$(claude_flag 2 --max-budget-usd)" = 2 ]
  [ "$(claude_flag 2 --settings)" = '{"disableClaudeAiConnectors":true,"disableBundledSkills":true}' ]
  local prompt; prompt=$(sed -n '/^-p$/,/^--append-system-prompt-file$/p' "$STATE/claude.2")
  [[ "$prompt" == *"Issue file: $WORK/.afk-logs/2.issue.md"* ]]
  [[ "$prompt" == *"Gather the diff: git diff $base..HEAD"* ]]
  [[ "$prompt" == *"Write your structured verdict to $WORK/.afk-logs/2.verify.json as your last action."* ]]
  [[ "$prompt" == *"Branch: feature/feat"* ]]
  [[ "$prompt" == *"Slug: feat"* ]]
  [[ "$prompt" == *'- [ ] works for `<before>` & co'* ]]
  [[ "$prompt" == *"Review assets: $HOME/.coding-crew/afk-feature/roles/reviewer"* ]]
  [[ "$prompt" == *"Checks already run by the pipeline in this branch's worktree: test=pass, lint=not_run."* ]]
  [[ "$prompt" == *"PRD: $WORK/.afk-logs/prd.md"* ]]
  [ "$(cat "$WORK/.afk-logs/prd.md")" = "# PRD: Feat" ]
  [ -z "$(git status --porcelain)" ]
}

@test "the verifier prompt omits PRD: when the tracker has no PRD (exit 3)" {
  rm "$STATE/prd.md"
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  grep -q '^Issue file: ' "$STATE/claude.2"
  ! grep -q '^PRD:' "$STATE/claude.2"
}

@test "the loop continues only on an all-met verdict" {
  VERDICT=unmet run bash "$SCRIPT" feat
  [ "$status" -ne 0 ]
  [ "$(claude_calls)" -eq 2 ]
  [[ "$output" == *"criterion 1 unmet"* ]]
  [[ "$output" == *"$WORK/.afk-logs/2.verify.log"* ]]
}

# --- stops ---------------------------------------------------------------------------

# fails_with <log> <env…> — the run stops non-zero after issue #2's coder, naming <log> on stdout.
fails_with() {
  local log="$1"; shift
  # Each scenario starts as setup left it: #2 ready, no claude calls, a clean tree.
  [ -f "$STATE/issues.orig" ] || cp "$STATE/issues.json" "$STATE/issues.orig"
  cp "$STATE/issues.orig" "$STATE/issues.json"
  rm -f "$STATE"/claude.*
  git checkout -q -f "$(git show-ref --verify -q refs/heads/feature/feat && echo feature/feat || echo main)"
  git clean -qfd
  run env "$@" bash "$SCRIPT" feat
  [ "$status" -ne 0 ] || { echo "$*: exit 0"; return 1; }
  [[ "$output" == *"$WORK/.afk-logs/$log"* ]] || { echo "$*: $output"; return 1; }
  [ "$(coder_issues)" = 2 ] || { echo "$*: coder ran on $(coder_issues)"; return 1; }
  [ -f "$WORK/.afk-logs/$log" ] || { echo "$*: no $log"; return 1; }
}

@test "a coder non-zero exit, a branch change or a dirty tree after the coder stops with the coder log's path" {
  fails_with 2.log CODER_EXIT=3
  fails_with 2.log CODER_SWITCH=1
  fails_with 2.log CODER_DIRTY=1
}

@test "run-checks.sh exit 1 or 3 stops with the checks log's path; 3 says to discover the checks by hand" {
  fails_with 2.checks.log CHECKS_RC=1
  [ "$(claude_calls)" -eq 1 ]
  fails_with 2.checks.log CHECKS_RC=3
  [[ "$output" == *"run /solve-issue or dep-install once by hand first"* ]]
}

@test "a missing report, a dirty tree or a moved HEAD after the verifier, or a verdict other than all-met stops with the verifier log's path" {
  fails_with 2.verify.log VERIFIER_NO_REPORT=1
  fails_with 2.verify.log VERIFIER_DIRTY=1
  fails_with 2.verify.log VERIFIER_COMMIT=1
  [[ "$output" == *"HEAD moved"* ]]
  fails_with 2.verify.log VERDICT=unmet
}

@test "a re-run with the failed issue closed proceeds to the next issue on the same branch" {
  VERDICT=unmet run bash "$SCRIPT" feat
  [ "$status" -ne 0 ]
  local tip; tip=$(git rev-parse HEAD)
  jq 'map(if .number == 2 then .state = "CLOSED" else . end)' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  rm -f "$STATE"/claude.*
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(coder_issues)" = 3 ]
  git merge-base --is-ancestor "$tip" HEAD
  [ "$(git branch --show-current)" = feature/feat ]
}

# --- permissions and models ----------------------------------------------------------

# allowed_tools <k> — the args after --allowedTools in claude call k, up to the next flag.
allowed_tools() { claude_call "$1" | sed -n '/^--allowedTools$/,$p' | sed '1d' | sed '/^--/,$d'; }

@test "without AFK_SANDBOXED every claude call gets acceptEdits, no prompts, and an allow-list with each dev-commands.json check" {
  git checkout -q -b topic
  cat > .coding-crew/dev-commands.json <<'JSON'
{"test": "make test", "lint": "npm run lint", "typecheck": null, "install": "npm ci", "install_mode": "host", "env": null, "credential_target": "x", "docker_service": "app", "coverage": "make cov", "integration": null}
JSON
  git add -A && git commit -q -m "dev commands"
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  local k expected
  expected=$(printf '%s\n' 'Bash(git *)' 'Bash(node *)' 'Bash(gh *)' 'Bash(bash *)' 'Bash(npm run lint)' 'Bash(make test)' 'Bash(make cov)')
  [ "$(claude_calls)" -eq 4 ]
  for k in 1 2 3 4; do
    [ "$(claude_flag "$k" --permission-mode)" = acceptEdits ] || { echo "call $k"; return 1; }
    [ "$(claude_flag "$k" --permission-prompts)" = none ] || { echo "call $k"; return 1; }
    [ "$(allowed_tools "$k")" = "$expected" ] || { echo "call $k: $(allowed_tools "$k")"; return 1; }
    ! grep -qE 'bypassPermissions|--dangerously-skip-permissions' "$STATE/claude.$k"
  done
}

@test "with AFK_SANDBOXED=1 every claude call gets bypassPermissions and no allow-list" {
  AFK_SANDBOXED=1 run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  local k
  for k in 1 2 3 4; do
    [ "$(claude_flag "$k" --permission-mode)" = bypassPermissions ] || { echo "call $k"; return 1; }
    ! grep -qE '^--allowedTools$|--dangerously-skip-permissions' "$STATE/claude.$k"
  done
}

@test "models default to sonnet and opus, and the coder never sees CREW_ORCHESTRATED" {
  CREW_ORCHESTRATED=1 run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(claude_flag 1 --model)" = sonnet ]
  [ "$(claude_flag 2 --model)" = opus ]
  [ "$(cat "$STATE/claude.1.env")" = 0 ]
}

@test "models come from afk.models.claude.coder and .reviewer" {
  git checkout -q -b topic
  echo '{"tracker":{"kind":"github"},"afk":{"models":{"claude":{"coder":"haiku","reviewer":"sonnet"}}}}' > .coding-crew/config.json
  git commit -q -am "models"
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(claude_flag 1 --model)" = haiku ]
  [ "$(claude_flag 2 --model)" = sonnet ]
}

# --- progress comment ----------------------------------------------------------------

# progress_body — the one afk-progress comment's body; fails unless exactly one exists.
progress_body() {
  [ "$(jq '[.[] | select(.body | contains("<!-- afk-progress -->"))] | length' "$STATE/comments.json")" = 1 ] || return 1
  jq -r '.[] | select(.body | contains("<!-- afk-progress -->")) | .body' "$STATE/comments.json"
}

@test "one progress comment on the root issue, created once then edited in place, with a line per issue and the PR command" {
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  local body; body=$(progress_body)
  grep -qE '^afk — feature feat — host test-host — [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' <<<"$body"
  grep -qx '#2  solve ✓  checks ✓  verify ✓' <<<"$body"
  grep -qx '#3  solve ✓  checks ✓  verify ✓' <<<"$body"
  grep -q 'gh pr create' <<<"$body"
  [ "$(grep -c '^api repos/{owner}/{repo}/issues/1/comments -f body=' "$STATE/gh.log")" -eq 1 ]
  [ "$(grep -c '^api -X PATCH repos/{owner}/{repo}/issues/comments/100 -f body=' "$STATE/gh.log")" -ge 8 ]

  # A re-run finds the comment by its marker and edits it: still one, never a second create.
  run bash "$SCRIPT" feat
  progress_body >/dev/null
  [ "$(grep -c '^api repos/{owner}/{repo}/issues/1/comments -f body=' "$STATE/gh.log")" -eq 1 ]
}

@test "a stop puts the failing step and the last 20 lines of its log in the comment" {
  CODER_EXIT=1 run bash "$SCRIPT" feat
  [ "$status" -ne 0 ]
  local body; body=$(progress_body)
  grep -qx '#2  solve ✗  checks ·  verify ·' <<<"$body"
  grep -q 'solve' <<<"$(grep -i 'stopped' <<<"$body")"
  grep -qx 'coder line 30' <<<"$body"
  grep -qx 'coder line 11' <<<"$body"
  ! grep -qx 'coder line 10' <<<"$body"
  grep -qx '```' <<<"$body"
}

@test "a failing gh api call on the comment warns and leaves the exit code alone" {
  GH_API_FAIL=1 run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"* ]]
  [ "$(coder_issues)" = "2 3" ]
  jq 'map(.labels = (if .root then [] else [{"name":"ready-for-agent"}] end))' "$STATE/issues.json" > "$STATE/i.tmp"
  mv "$STATE/i.tmp" "$STATE/issues.json"
  GH_API_FAIL=1 VERDICT=unmet run bash "$SCRIPT" feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"#2 verify failed"* ]]
}

# --- finish --------------------------------------------------------------------------

@test "with no ready issue left it pushes the branch and prints a gh pr create command whose body is the closing-refs output" {
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(git rev-parse origin/feature/feat)" = "$(git rev-parse feature/feat)" ]
  [ "$(git ls-remote origin refs/heads/feature/feat | cut -f1)" = "$(git rev-parse feature/feat)" ]
  local last="${lines[${#lines[@]}-1]}"
  [[ "$last" == "gh pr create --fill --body "* ]]
  ! grep -q '^pr create' "$STATE/gh.log"
  eval "$last"
  [ "$(cat "$STATE/pr-body")" = "$(printf 'Closes #2\nCloses #3')" ]
  [ "$(cat "$STATE/pr-body")" = "$(node "$HOME/.coding-crew/tracker/cli.mjs" closing-refs --feature-slug feat)" ]
}

@test "--open-pr creates the PR only when gh pr view finds none, and prints its URL" {
  run bash "$SCRIPT" feat --open-pr
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "https://github.com/o/r/pull/10" ]
  [ "$(cat "$STATE/pr-body")" = "$(printf 'Closes #2\nCloses #3')" ]
  grep -q 'pull/10' <<<"$(progress_body)"

  rm -f "$STATE/pr-body"
  PR_EXISTS=1 run bash "$SCRIPT" feat --open-pr
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "https://github.com/o/r/pull/9" ]
  [ ! -f "$STATE/pr-body" ]
}

@test "afk-feature.sh stays under 150 lines and .afk-logs/ is gitignored here" {
  [ "$(wc -l < "$REPO_ROOT/skills/afk-feature/scripts/afk-feature.sh")" -lt 150 ]
  git -C "$REPO_ROOT" check-ignore -q .afk-logs/x.log
}
