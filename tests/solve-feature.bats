#!/usr/bin/env bats

# solve-feature.sh start|next|land|fix — the guards of solve-feature's loop, which SKILL.md drives with a
# host subagent as each issue's coder: start picks the branch, next saves the next ready issue, land
# asserts what the coder left (branch, clean tree, issue closed, checks) and pushes it into a draft PR,
# and fix gates, commits and pushes what the review's fixer left, then marks the PR ready.
#
# A temp clone with a bare `origin`, and the skill installed user-level under a temp $HOME as
# install.sh lays it out. `gh`, `node` (only for the tracker CLI's path; everything else reaches the
# real node) and solve-issue's run-checks.sh are stubs that log their argv; the node stub answers
# `next` from $STATE/issues.json by the tracker's dispatch rule. `coder <ref>` stands in for the
# subagent: it commits a file and swaps the issue's ready-for-agent label for awaiting-merge, as
# solve-issue's mark-done does.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
  # Physical path: the script's paths come from `git rev-parse --show-toplevel`, which resolves
  # macOS's /var → /private/var symlink on the temp dir.
  TEMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
  export STATE="$TEMP_DIR/state" HOME="$TEMP_DIR/home" SOLVE_FEATURE_HOST=test-host
  mkdir -p "$STATE" "$HOME"
  unset CREW_ORCHESTRATED PR_EXISTS PR_DRAFT PR_HEAD_OID PR_STATE PR_HEAD_REF CHECK_WRITES TRACKER_KIND

  INSTALL="$HOME/.coding-crew"
  mkdir -p "$INSTALL/solve-feature" "$INSTALL/solve-issue/scripts" "$INSTALL/dep-install/scripts" "$INSTALL/tracker"
  cp -R "$REPO_ROOT/skills/solve-feature/scripts" "$INSTALL/solve-feature/scripts"
  : > "$INSTALL/tracker/cli.mjs"
  SCRIPT="$INSTALL/solve-feature/scripts/solve-feature.sh"

  WORK="$TEMP_DIR/work"
  git init -q -b main "$WORK"
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name test
  mkdir -p "$WORK/.coding-crew"
  echo '{"tracker":{"kind":"github"}}' > "$WORK/.coding-crew/config.json"
  echo '{"test":"make test"}' > "$WORK/.coding-crew/dev-commands.json"
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
  issue_body 2 Two "None - can start immediately"
  issue_body 3 Three "None - can start immediately"
  printf '<!-- PRD issue #1: PRD: Feat -->\n# PRD: Feat\n\nthe prd\n' > "$STATE/prd.md"
  echo '[]' > "$STATE/comments.json"
  cd "$WORK"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

issues() { printf '%s\n' "$1" > "$STATE/issues.json"; }

# issue_body <ref> <title> <Blocked by text> — what `fetch <ref>` prints, under the ref with / → _
issue_body() {
  printf '# %s\n\n## What to build\n\nx\n\n## Acceptance criteria\n\n- [ ] works for `<before>` & co\n- [ ] %s done\n\n## Blocked by\n\n%s\n' "$2" "$2" "$3" > "$STATE/${1//\//_}.md"
}

write_stubs() {
  # `next`: the lowest open ready-for-agent issue not labelled blocked whose every `## Blocked by`
  # number is CLOSED or awaiting-merge (the tracker's `done`), the root included; exit 3 when none.
  cat > "$STUB/node" <<EOF
#!/usr/bin/env bash
case "\$1" in */.coding-crew/tracker/cli.mjs) ;; *) exec "$REAL_NODE" "\$@" ;; esac
printf '%s\n' "\${*:2}" >> "\$STATE/node.log"
case "\$2" in
  config) echo "tracker=\${TRACKER_KIND:-github}"; echo configured=yes ;;
  next) [ "\$4" = feat ] || exit 3
    [ -z "\${NEXT_PRINTS:-}" ] || { echo "\$NEXT_PRINTS"; exit 0; }
    done=" \$(jq -r '[.[] | select(.state == "CLOSED" or any(.labels[]; .name == "awaiting-merge")) | .number] | join(" ")' "\$STATE/issues.json") "
    for c in \$(jq -r '[.[] | select(.state == "OPEN" and any(.labels[]; .name == "ready-for-agent") and (any(.labels[]; .name == "blocked") | not))] | sort_by(.number) | .[] | .ref // (.number | tostring)' "\$STATE/issues.json"); do
      ok=1; for b in \$(awk '/^## Blocked by/{f=1;next} /^## /{f=0} f' "\$STATE/\${c//\//_}.md" | grep -oE '#[0-9]+' | tr -d '#'); do
        [[ "\$done" == *" \$b "* ]] || ok=0; done
      [ "\$ok" = 1 ] && { echo "\$c"; exit 0; }
    done; exit 3 ;;
  fetch) [ -f "\$STATE/\${3//\//_}.md" ] || exit 3; cat "\$STATE/\${3//\//_}.md" ;;
  prd) [ -f "\$STATE/prd.md" ] || exit 3; cat "\$STATE/prd.md" ;;
  closing-refs) [ -z "\${CLOSING_REFS_RC:-}" ] || { echo "gh: boom" >&2; exit "\$CLOSING_REFS_RC"; }
    [ "\${TRACKER_KIND:-github}" = github ] || exit 0; jq -r 'sort_by(.number) | .[] | select(.state == "OPEN" and any(.labels[]; .name == "awaiting-merge")) | "Closes #\(.number)"' "\$STATE/issues.json" ;;
  *) exit 2 ;;
esac
EOF

  # `pr view` answers from the PR this run created ($STATE/pr-body) or PR_EXISTS (#9, body from
  # $STATE/pr-body when present, else a hand-written one); `pr create`/`pr edit` keep the body there.
  # Its head commit is what was pushed to origin/feature/feat, or PR_HEAD_OID; PR_STATE and PR_HEAD_REF
  # override its state and head branch.
  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATE/gh.log"
[ -z "${GH_API_FAIL:-}" ] || [ "$1" != api ] || exit 1
body=""; patch=""; path=""; file=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -f) body="${args[$((i + 1))]#body=}" ;;
    -X) patch="${args[$((i + 1))]}" ;;
    --body-file) file="${args[$((i + 1))]}" ;;
    --title) printf '%s' "${args[$((i + 1))]}" > "$STATE/pr-title" ;;
    repos/*) path="${args[$i]}" ;;
  esac
done
case "$1 $2" in
  "pr view")
    if [ -f "$STATE/pr-created" ]; then n=10; elif [ -n "${PR_EXISTS:-}" ]; then n=9; else exit 1; fi
    [ -f "$STATE/pr-body" ] || printf 'hand intro\n' > "$STATE/pr-body"
    oid=${PR_HEAD_OID:-$(git rev-parse -q --verify refs/remotes/origin/feature/feat || true)}
    jq -n --argjson n "$n" --argjson d "${PR_DRAFT:-true}" --rawfile b "$STATE/pr-body" --arg o "$oid" \
      --arg s "${PR_STATE:-OPEN}" --arg h "${PR_HEAD_REF:-feature/feat}" \
      '{number: $n, state: $s, url: "https://github.com/o/r/pull/\($n)", isDraft: $d, body: $b, headRefOid: $o, headRefName: $h}' ;;
  "pr create") k=$(( $(ls "$STATE" | grep -c '^pr-create\.[0-9]*$') + 1 )); printf '%s\n' "$@" > "$STATE/pr-create.$k"
    cp "$file" "$STATE/pr-body"; touch "$STATE/pr-created"; echo "https://github.com/o/r/pull/10" ;;
  "pr edit") k=$(( $(ls "$STATE" | grep -c '^pr-edit\.[0-9]*$') + 1 )); printf '%s\n' "$@" > "$STATE/pr-edit.$k"; cp "$file" "$STATE/pr-body" ;;
  "pr ready") ;;
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
[ -z "${CHECK_WRITES:-}" ] || echo rewritten >> "$CHECK_WRITES"
for i in $(seq 1 30); do echo "check line $i"; done
echo "test: ${CHECK_RESULT:-pass}"
[ "${CHECKS_RC:-0}" != 3 ] || { echo DISCOVER; exit 3; }
[ "${CHECKS_RC:-0}" = 0 ] && echo "CHECKS: pass" || echo "CHECKS: fail"
exit "${CHECKS_RC:-0}"
EOF
  chmod +x "$STUB"/* "$HOME"/.coding-crew/*/scripts/*.sh
}

# coder <ref> — what the subagent's solve-issue leaves: a commit, and the issue out of `next`.
coder() {
  echo "$1" > "work-${1//\//_}.txt"
  git add "work-${1//\//_}.txt" && git commit -q -m "[$1] work"
  jq --arg r "$1" 'map(if (.ref // (.number | tostring)) == $r then .labels = [{"name":"awaiting-merge"}] else . end)' "$STATE/issues.json" > "$STATE/i.tmp"
  mv "$STATE/i.tmp" "$STATE/issues.json"
}
# out <key> — the value of start's or land's `<key>=` line in $output.
out() { sed -n "s/^$1=//p" <<<"$output" | tail -1; }
# loop — SKILL.md's loop: start, then next → coder → land until next exits 3. CODED collects the refs,
# LAST_PR is the last `pr=` printed.
loop() {
  run bash "$SCRIPT" start feat "$@"
  [ "$status" -eq 0 ] || { echo "start: $output"; return 1; }
  local branch ref; branch=$(out branch); CODED="" LAST_PR=$(out pr)
  while :; do
    run bash "$SCRIPT" next feat
    [ "$status" -ne 3 ] || return 0
    [ "$status" -eq 0 ] || { echo "next: $output"; return 1; }
    ref="$output"; CODED="${CODED:+$CODED }$ref"
    coder "$ref"
    run bash "$SCRIPT" land feat "$ref" "$branch"
    [ "$status" -eq 0 ] || { echo "land $ref: $output"; return 1; }
    LAST_PR=$(out pr)
  done
}
# progress_body — the one solve-feature-progress comment's body; fails unless exactly one exists.
progress_body() {
  [ "$(jq '[.[] | select(.body | contains("<!-- solve-feature-progress -->"))] | length' "$STATE/comments.json")" = 1 ] || return 1
  jq -r '.[] | select(.body | contains("<!-- solve-feature-progress -->")) | .body' "$STATE/comments.json"
}
# body_of <pr-create.k|pr-edit.k> — the body file that call was given.
body_of() { cat "$(grep -A1 -x -- --body-file "$STATE/$1" | tail -1)"; }
# land_ready — start on feature/feat, #2 saved by next and coded: land's input as the loop leaves it.
land_ready() {
  run bash "$SCRIPT" start feat; [ "$status" -eq 0 ]
  run bash "$SCRIPT" next feat; [ "$output" = 2 ]
  coder 2
}

# --- usage and preconditions ---------------------------------------------------------

@test "no subcommand, an unknown one, a wrong argument count or a removed flag exits 2 with the usage line" {
  local args
  for args in "" "feat" "run feat" "next" "land feat 2" "fix feat 10" "fix feat 10 feature/feat x" "fix feat ten feature/feat" "start feat --agent copilot" "start feat --budget 5" "start feat --open-pr" "start feat other"; do
    run bash "$SCRIPT" $args
    [ "$status" -eq 2 ] || { echo "'$args': status $status"; return 1; }
    [[ "$output" == *"usage: solve-feature.sh start <slug> [--branch <name>] | next <slug> | land <slug> <ref> <branch> | fix <slug> <pr> <branch>"* ]]
  done
  [ ! -f "$STATE/gh.log" ]
  [ ! -e "$WORK/.solve-feature/stopped" ]
}

@test "start: a missing tool, an invalid slug, no tracker CLI, a dirty tree, no dev-commands.json or CREW_ORCHESTRATED exits 1 before any checkout or gh call" {
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

  mv "$INSTALL/tracker/cli.mjs" "$TEMP_DIR/cli.mjs"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"tracker CLI not found"* ]]
  mv "$TEMP_DIR/cli.mjs" "$INSTALL/tracker/cli.mjs"

  git rm -q .coding-crew/dev-commands.json && git commit -q -m "no commands"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *".coding-crew/dev-commands.json"* ]]
  git revert --no-edit HEAD >/dev/null

  CREW_ORCHESTRATED=1 run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"CREW_ORCHESTRATED"* ]]

  echo dirt > dirt.txt
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"clean"* ]]

  [ "$(git branch --show-current)" = main ]
  [ ! -f "$STATE/gh.log" ]
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

@test "start on another branch uses that branch, ignoring --branch" {
  git checkout -q -b topic
  run bash "$SCRIPT" start feat --branch other
  [ "$(out branch)" = topic ]
  [ "$(git branch --show-current)" = topic ]
  ! git show-ref --verify -q refs/heads/other
  ! git show-ref --verify -q refs/heads/feature/feat
}

# --- start: what it prints and saves -------------------------------------------------

@test "start prints coder-model= and reviewer-model= from solveFeature.models only (empty when unset), pr= for the branch's open PR" {
  git checkout -q -b topic
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'branch=topic\ncoder-model=\nreviewer-model=\npr=')" ]

  echo '{"tracker":{"kind":"github"},"afk":{"models":{"claude":{"coder":"haiku","reviewer":"haiku"}}}}' > .coding-crew/config.json
  git commit -q -am "afk models"
  PR_EXISTS=1 run bash "$SCRIPT" start feat
  [ "$output" = "$(printf 'branch=topic\ncoder-model=\nreviewer-model=\npr=9')" ]

  echo '{"tracker":{"kind":"github"},"solveFeature":{"models":{"coder":"sonnet","reviewer":"opus"}}}' > .coding-crew/config.json
  git commit -q -am "solveFeature models"
  run bash "$SCRIPT" start feat
  [ "$(out coder-model)" = sonnet ]
  [ "$(out reviewer-model)" = opus ]
}

@test "start writes .solve-feature/prd.md when the feature has a PRD, none when prd exits 3, and removes stale stopped, reviewed and unfixed markers" {
  mkdir -p .solve-feature && echo '*' > .solve-feature/.gitignore && echo old > .solve-feature/stopped && echo old > .solve-feature/reviewed
  echo old > .solve-feature/pr-7.unfixed.md && echo kept > .solve-feature/pr-7.review.json
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ]
  [ "$(cat .solve-feature/prd.md)" = "$(cat "$STATE/prd.md")" ]
  [ ! -e .solve-feature/stopped ] && [ ! -e .solve-feature/reviewed ] && [ ! -e .solve-feature/pr-7.unfixed.md ]
  [ -e .solve-feature/pr-7.review.json ]
  rm "$STATE/prd.md"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ]
  [ ! -e .solve-feature/prd.md ]
  [ -z "$(git status --porcelain)" ]
}

# --- next ------------------------------------------------------------------------------

@test "next prints the ready ref and saves its issue; exit 3 when none is left; a ref fetch rejects exits 1" {
  run bash "$SCRIPT" next feat
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
  [ "$(cat .solve-feature/2.issue.md)" = "$(cat "$STATE/2.md")" ]
  jq 'map(.state = "CLOSED")' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ ! -e .solve-feature/stopped ]
  NEXT_PRINTS='2; rm -rf /' run bash "$SCRIPT" next feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"fetch 2; rm -rf / failed"* ]]
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
  loop
  [ "$CODED" = "3 7" ]
}

# --- land: guards ----------------------------------------------------------------------

# stops_at <step> <reason> — land just exited 1: nothing pushed, the reason in .solve-feature/stopped.
stops_at() {
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: 2 $1 failed: $2"* ]] || { echo "$output"; return 1; }
  [ "$(git ls-remote origin feature/feat | cut -f1)" != "$(git rev-parse HEAD)" ] || { echo pushed; return 1; }
  [ ! -f "$STATE/pr-created" ]
  grep -qF "$2" .solve-feature/stopped
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
}

@test "land with the issue still first in next exits 1 'did not close', before the checks" {
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" next feat
  git commit -q --allow-empty -m "partial"
  run bash "$SCRIPT" land feat 2 feature/feat
  stops_at solve "coder ran but did not close 2 (its report says why)"
  [ ! -f "$STATE/checks.log" ]
}

@test "land runs run-checks.sh once; exit 1 or 3 stops at checks naming the log, 3 saying to discover the checks by hand" {
  land_ready
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  stops_at checks "run-checks.sh exit 1; once fixed and committed, run land feat 2 feature/feat before a re-run"
  [[ "$output" == *"$WORK/.solve-feature/2.checks.log"* ]]
  [ "$(cat "$STATE/checks.log")" = "--project-root $WORK --main-root $WORK --dep-scripts $HOME/.coding-crew/dep-install/scripts" ]
  CHECKS_RC=3 run bash "$SCRIPT" land feat 2 feature/feat
  stops_at checks "no check commands known (DISCOVER): run /solve-issue or dep-install once by hand"
  # The recovery the stop names: land again once the checks pass, and the issue's commits are pushed.
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
}

@test "with no PR yet a stop prints its row and Stopped note on stdout; with one it goes in the progress comment with the checks log's last 20 lines" {
  land_ready
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  grep -qx '2  solve ✓  checks ✗' <<<"$output"
  grep -qx 'Stopped at checks: run-checks.sh exit 1; once fixed and committed, run land feat 2 feature/feat before a re-run' <<<"$output"
  [ "$(jq length "$STATE/comments.json")" -eq 0 ]

  CHECKS_RC=1 PR_EXISTS=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  local body; body=$(progress_body)
  grep -qx '2  solve ✓  checks ✗' <<<"$body"
  grep -qx 'Stopped at checks: run-checks.sh exit 1; once fixed and committed, run land feat 2 feature/feat before a re-run' <<<"$body"
  grep -qx 'CHECKS: fail' <<<"$body"
  grep -qx 'check line 13' <<<"$body"
  ! grep -qx 'check line 12' <<<"$body"
  grep -qx '```' <<<"$body"
}

@test "a re-run after a stop lands on the same branch: start keeps it, the closed issue's next is the following one" {
  land_ready
  local tip; tip=$(git rev-parse HEAD)
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  jq 'map(if .number == 2 then .state = "CLOSED" else . end)' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  loop
  [ "$CODED" = 3 ]
  git merge-base --is-ancestor "$tip" HEAD
  [ "$(git branch --show-current)" = feature/feat ]
}

# --- land: push and PR -----------------------------------------------------------------

@test "the first land pushes and creates the draft PR with the spec block, printing pr=; the next one appends by pr edit" {
  land_ready
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = pr=10 ]
  [ "$(git rev-parse origin/feature/feat)" = "$(git rev-parse feature/feat)" ]
  grep -qx -- --draft "$STATE/pr-create.1"
  [ "$(cat "$STATE/pr-title")" = Feat ]
  [ "$(body_of pr-create.1)" = "$(cat <<'EOF'
<!-- solve-feature:begin -->
Implemented by solve-feature (`feat`).

<details><summary>Spec</summary>

<!-- PRD issue #1: PRD: Feat -->
# PRD: Feat

the prd

### 2 — Two
## Acceptance criteria

- [ ] works for `<before>` & co
- [ ] Two done

</details>

Closes #2
<!-- solve-feature:slug feat -->
<!-- solve-feature:end -->
EOF
)" ]
  run bash "$SCRIPT" next feat
  coder 3
  run bash "$SCRIPT" land feat 3 feature/feat
  [ "$status" -eq 0 ]
  [ "$output" = pr=10 ]
  [ ! -f "$STATE/pr-create.2" ] && [ -f "$STATE/pr-edit.1" ]
  [ "$(sed -n 3p "$STATE/pr-edit.1")" = 10 ]
  [ "$(body_of pr-edit.1)" = "$(cat <<'EOF'
<!-- solve-feature:begin -->
Implemented by solve-feature (`feat`).

<details><summary>Spec</summary>

<!-- PRD issue #1: PRD: Feat -->
# PRD: Feat

the prd

### 2 — Two
## Acceptance criteria

- [ ] works for `<before>` & co
- [ ] Two done

### 3 — Three
## Acceptance criteria

- [ ] works for `<before>` & co
- [ ] Three done

</details>

Closes #2
Closes #3
<!-- solve-feature:slug feat -->
<!-- solve-feature:end -->
EOF
)" ]
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "an existing open PR is reused: its block replaced, text outside kept, a present issue not duplicated, draft state untouched" {
  export PR_EXISTS=1 PR_DRAFT=false
  printf 'hand intro\n<!-- solve-feature:begin -->\nold\n<details><summary>Spec</summary>\n\n### 2 — Two\nold criteria\n</details>\n<!-- solve-feature:end -->\nhand outro\n' > "$STATE/pr-body"
  loop
  [ "$LAST_PR" = 9 ]
  [ ! -f "$STATE/pr-created" ]
  ! grep -q '^pr create' "$STATE/gh.log"
  ! grep -q '^pr ready' "$STATE/gh.log"
  [ -f "$STATE/pr-edit.2" ]
  local body; body=$(cat "$STATE/pr-body")
  [ "$(head -1 <<<"$body")" = "hand intro" ]
  [ "$(tail -1 <<<"$body")" = "hand outro" ]
  [ "$(grep -c '^### 2 — Two$' <<<"$body")" -eq 1 ]
  [ "$(grep -c '^### 3 — Three$' <<<"$body")" -eq 1 ]
  grep -q '^old criteria$' <<<"$body"
  ! grep -qx old <<<"$body"
  [ "$(grep -c 'solve-feature:begin' <<<"$body")" -eq 1 ]
  [ "$(grep -c '^Closes #' <<<"$body")" -eq 2 ]
}

@test "a one-slice feature's root is its work issue: it runs, and the PR is titled after the PRD" {
  issues '[{"number":1,"title":"Feat alone","state":"OPEN","labels":[{"name":"ready-for-agent"}],"root":true}]'
  issue_body 1 "Feat alone" "None"
  loop
  [ "$CODED" = 1 ]
  [ "$(cat "$STATE/pr-title")" = Feat ]
  grep -qx '1  solve ✓  checks ✓' <<<"$(progress_body)"
}

@test "a feature whose prd exits 3 titles the PR after the first landed issue, with no PRD in the body" {
  rm "$STATE/prd.md"
  loop
  [ "$(cat "$STATE/pr-title")" = Two ]
  ! grep -q 'PRD' "$STATE/pr-body"
}

@test "a local tracker: path refs, saved by next before the close moves the file, land from the saved copy, no Closes line" {
  export TRACKER_KIND=local
  issues '[{"number":1,"ref":".scratch/feat/issues/open/01-a.md","title":"A","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":2,"ref":".scratch/feat/issues/open/02-b.md","title":"B","state":"OPEN","labels":[{"name":"ready-for-agent"}]}]'
  issue_body .scratch/feat/issues/open/01-a.md "Local A" None
  issue_body .scratch/feat/issues/open/02-b.md "Local B" None
  printf '# PRD\n\nlocal prd without a title note\n' > "$STATE/prd.md"
  run bash "$SCRIPT" start feat
  run bash "$SCRIPT" next feat
  [ "$output" = .scratch/feat/issues/open/01-a.md ]
  coder .scratch/feat/issues/open/01-a.md
  rm "$STATE/.scratch_feat_issues_open_01-a.md.md" # the close moved it: fetch now exits 3
  run bash "$SCRIPT" land feat .scratch/feat/issues/open/01-a.md feature/feat
  [ "$status" -eq 0 ]
  [ -f "$WORK/.solve-feature/.scratch_feat_issues_open_01-a.md.checks.log" ]
  [ "$(cat "$STATE/pr-title")" = "Local A" ]
  grep -q '^### .scratch/feat/issues/open/01-a.md — Local A$' "$STATE/pr-body"
  ! grep -q '^Closes' "$STATE/pr-body"
  grep -qx 'closing-refs --feature-slug feat' "$STATE/node.log"
  ! grep -q '^config' "$STATE/node.log"
}

@test "start, next and land reach the tracker through prd, next, fetch and closing-refs only, and name no tracker kind" {
  loop
  [ "$(cut -d' ' -f1 "$STATE/node.log" | sort -u | paste -sd' ' -)" = "closing-refs fetch next prd" ]
  ! grep -nE 'KIND|github|\.scratch|"\$CLI" config|\$REF" =~' "$SCRIPT"
}

@test "a failing closing-refs stops land with a solve-feature message naming it, before anything is pushed" {
  land_ready
  CLOSING_REFS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"solve-feature: closing-refs failed for 'feat'"* ]]
  [ ! -f "$STATE/pr-created" ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" != "$(git rev-parse HEAD)" ]
  grep -q 'closing-refs failed' .solve-feature/stopped
}

@test "a rejected push, or any other unexpected failure, exits 1 with its reason in .solve-feature/stopped" {
  land_ready
  printf '#!/bin/sh\nexit 1\n' > "$TEMP_DIR/origin.git/hooks/pre-receive" && chmod +x "$TEMP_DIR/origin.git/hooks/pre-receive"
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [ ! -f "$STATE/pr-created" ]
  grep -q 'land failed' .solve-feature/stopped
}

@test "land with solve-issue's scripts missing exits 1 naming them, before the checks" {
  land_ready
  rm -rf "$INSTALL/solve-issue/scripts"
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-issue scripts not found"* ]]
  [ ! -f "$STATE/checks.log" ]
  grep -q 'solve-issue scripts not found' .solve-feature/stopped
}

# --- fix: after the review -------------------------------------------------------------

# fix_ready [<report json>] — both issues landed in PR #10, the reviewer's report written (default: met,
# two findings, no gaps) and the fixer's edit left uncommitted: fix's input as SKILL.md leaves it.
fix_ready() {
  loop
  [ "$LAST_PR" = 10 ]
  local two='{"prd":"met","gaps":[],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"},{"severity":"LOW","location":"b:2","issue":"j","fix":"g"}]}'
  report "${1:-$two}"
  echo fixed > fixed.txt
}
report() { printf '%s\n' "$1" > .solve-feature/pr-10.review.json; }
pushed() { [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]; }
# fix_stops <reason> — exit 1, nothing pushed, a Stopped-at-fix note and .solve-feature/stopped naming it.
fix_stops() {
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: review fix failed: $1"* ]] || { echo "$output"; return 1; }
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$TIP" ] || { echo pushed; return 1; }
  grep -qF "Stopped at fix: $1" <<<"$(progress_body)"
  grep -qF "$1" .solve-feature/stopped
  [ ! -e .solve-feature/reviewed ]
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "fix on another branch, on a HEAD without the PR's head, for a PR not open or not on the branch, or with a missing, unreadable or prd-less report stops before the checks" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  local checks; checks=$(wc -l < "$STATE/checks.log")
  git checkout -q -b elsewhere
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "branch changed to 'elsewhere'"
  git checkout -q feature/feat

  git commit -q --allow-empty -m other && local other; other=$(git rev-parse HEAD) && git reset -q --hard HEAD~1 && echo fixed > fixed.txt
  PR_HEAD_OID=$other run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "HEAD does not contain PR #10's head ${other:0:7}"
  PR_STATE=CLOSED run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "PR #10 is CLOSED, not OPEN"
  PR_HEAD_REF=other run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "PR #10's head branch is 'other', not 'feature/feat'"

  rm .solve-feature/pr-10.review.json
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "no review report at $WORK/.solve-feature/pr-10.review.json"
  report 'not json'
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "unreadable review report $WORK/.solve-feature/pr-10.review.json"
  local r
  for r in '{"findings":[]}' '{"prd":"maybe"}' '{"prd":"met","findings":{}}' '{"prd":"met","findings":[1]}' '{"prd":"met","gaps":"g"}'; do
    report "$r"
    run bash "$SCRIPT" fix feat 10 feature/feat
    fix_stops "review report $WORK/.solve-feature/pr-10.review.json"
  done
  [ "$(wc -l < "$STATE/checks.log")" -eq "$checks" ]
  [ "$(cat fixed.txt)" = fixed ]
}

@test "fix with failing checks stops with the log tail, leaving the tree and commits; a second fix once committed completes" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  : > "$STATE/checks.log"
  CHECKS_RC=1 run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "run-checks.sh exit 1; once fixed and committed, run fix feat 10 feature/feat"
  [ "$(cat "$STATE/checks.log")" = "--project-root $WORK --main-root $WORK --dep-scripts $HOME/.coding-crew/dep-install/scripts" ]
  local body; body=$(progress_body)
  grep -qx 'review ✓  checks ✗' <<<"$body"
  grep -qx 'check line 13' <<<"$body" && ! grep -qx 'check line 12' <<<"$body"
  [ "$(git rev-parse HEAD)" = "$TIP" ]
  [ "$(git status --porcelain)" = 'A  fixed.txt' ]

  git add fixed.txt && git commit -q -m "fix by hand"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pushed
  [ "$(git rev-parse HEAD~1)" = "$TIP" ]
  grep -qx "review ✓  fixed 2 ($(git rev-parse --short HEAD))  checks ✓" <<<"$(progress_body)"
  [ ! -e .solve-feature/stopped ] && ! grep -q 'Stopped' <<<"$(progress_body)"
}

@test "a check that rewrites or adds a file stops fix with nothing committed or pushed" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  CHECK_WRITES=fixed.txt run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "the checks changed files: fixed.txt; commit or revert them, then run fix feat 10 feature/feat"
  [ "$(git rev-parse HEAD)" = "$TIP" ]
  git checkout -q -- fixed.txt
  CHECK_WRITES=new.txt run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "the checks changed files: new.txt; commit or revert them, then run fix feat 10 feature/feat"
  [ "$(git rev-parse HEAD)" = "$TIP" ]
}

@test "a fixer that changed nothing fixed nothing: the findings need attention and the PR stays a draft" {
  fix_ready
  rm fixed.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^pr ready' "$STATE/gh.log"
  local body; body=$(progress_body)
  grep -qx 'review ✓  fixed 0  checks ✓' <<<"$body"
  grep -qx -- '- the fixer changed nothing for 2 finding(s)' <<<"$body"
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 fixed=0 needs-attention=1 ready=no" ]
  # Listed ones are not counted twice.
  echo 'a:1 left as is' > .solve-feature/pr-10.unfixed.md
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$(awk '/^Needs attention:$/ {f = 1} f' <<<"$(progress_body)")" = "$(printf 'Needs attention:\n- a:1 left as is\n- the fixer changed nothing for 1 finding(s)')" ]
}

@test "fix commits a dirty tree as one commit, pushes it, appends one review row and writes reviewed" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  echo more > more.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD~1)" = "$TIP" ]
  [ "$(git diff --name-only HEAD~1 HEAD | sort | tr '\n' ' ')" = "fixed.txt more.txt " ]
  [ -z "$(git status --porcelain)" ]
  pushed
  local sha; sha=$(git rev-parse --short HEAD)
  [ "$(sed -n '3,$p' <<<"$(progress_body)" | awk '/^$/ {exit} 1')" = "$(printf '2  solve ✓  checks ✓\n3  solve ✓  checks ✓\nreview ✓  fixed 2 (%s)  checks ✓' "$sha")" ]
  [ "$(cat .solve-feature/reviewed)" = "pr=10 head=$(git rev-parse HEAD)" ]
}

@test "fix with no findings on a clean tree commits nothing and records no findings" {
  loop
  report '{"prd":"met","gaps":[],"findings":[]}'
  TIP=$(git rev-parse HEAD)
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD)" = "$TIP" ]
  grep -qx 'review ✓  no findings  checks ✓' <<<"$(progress_body)"
  [ -e .solve-feature/reviewed ]
}

@test "fix pushes the fixer's own commits as they are and names the tip" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  git add fixed.txt && git commit -q -m "fixer's commit"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git rev-parse HEAD~1)" = "$TIP" ] && [ "$(git log -1 --format=%s)" = "fixer's commit" ]
  pushed
  grep -qx "review ✓  fixed 2 ($(git rev-parse --short HEAD))  checks ✓" <<<"$(progress_body)"
}

@test "fix marks a draft ready when the spec is met with no gaps and nothing unfixed, and leaves a ready PR alone" {
  fix_ready
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pr ready' "$STATE/gh.log")" -eq 1 ] && grep -qx 'pr ready 10' "$STATE/gh.log"
  grep -qx 'Marked ready for review: nothing needs attention.' <<<"$(progress_body)"
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 fixed=2 needs-attention=0 ready=yes" ]

  echo again > again.txt
  PR_DRAFT=false run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  [ "$(grep -c '^pr ready' "$STATE/gh.log")" -eq 1 ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 fixed=2 needs-attention=0 ready=already" ]
}

@test "a gap, an unmet spec or an unfixed finding keeps the PR a draft and is listed under Needs attention" {
  fix_ready '{"prd":"unmet","gaps":["no logout endpoint"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"},{"severity":"LOW","location":"b:2","issue":"j","fix":"g"}]}'
  printf -- '# Unfixed\n- a:1 race on the lock: needs a design call\n\n' > .solve-feature/pr-10.unfixed.md
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^pr ready' "$STATE/gh.log"
  local body; body=$(progress_body)
  grep -qx "review ✓  fixed 1 ($(git rev-parse --short HEAD))  checks ✓" <<<"$body"
  [ "$(awk '/^Needs attention:$/ {f = 1} f' <<<"$body")" = "$(printf 'Needs attention:\n- no logout endpoint\n- a:1 race on the lock: needs a design call')" ]
  [ ! -e .solve-feature/pr-10.unfixed.md ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 fixed=1 needs-attention=2 ready=no" ]

  # The spec unmet with no gap named still needs a person.
  report '{"prd":"unmet","gaps":[],"findings":[]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  ! grep -q '^pr ready' "$STATE/gh.log"
  grep -qx -- '- the reviewer found the spec unmet' <<<"$(progress_body)"
}

@test "fix posts no PR review and no review comment" {
  fix_ready '{"prd":"unmet","gaps":["g"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}]}'
  echo 'x' > .solve-feature/pr-10.unfixed.md
  : > "$STATE/gh.log"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  ! grep -qE 'pulls/|^pr review|^pr comment' "$STATE/gh.log"
  # Every gh call is the PR view or the progress comment (multi-line bodies make the other log lines).
  [ -z "$(grep -E '^(pr|api|issue|repo) ' "$STATE/gh.log" | grep -v -E '^pr view 10 |^api (-X PATCH )?repos/\{owner\}/\{repo\}/issues/(10/)?comments')" ]
}

# --- progress comment ------------------------------------------------------------------

@test "one progress comment, created by the first land then edited in place, each land's row appended after the earlier ones" {
  loop
  local body; body=$(progress_body)
  grep -qE '^solve-feature — feat — host test-host — [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' <<<"$body"
  [ "$(sed -n '3,$p' <<<"$body")" = "$(printf '2  solve ✓  checks ✓\n3  solve ✓  checks ✓')" ]
  [ "$(grep -c '^api repos/{owner}/{repo}/issues/10/comments -f body=' "$STATE/gh.log")" -eq 1 ]
  [ "$(grep -c '^api -X PATCH repos/{owner}/{repo}/issues/comments/100 -f body=' "$STATE/gh.log")" -eq 1 ]
  [ "$(grep -n -m1 'comments' "$STATE/gh.log" | cut -d: -f1)" -gt "$(grep -n -m1 '^pr create' "$STATE/gh.log" | cut -d: -f1)" ]
}

@test "a stop then a re-land: the ref gets a second row and the Stopped note is dropped" {
  export PR_EXISTS=1
  land_ready
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ]
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ]
  local body; body=$(progress_body)
  [ "$(sed -n '3,$p' <<<"$body")" = "$(printf '2  solve ✓  checks ✗\n2  solve ✓  checks ✓')" ]
  ! grep -q 'Stopped' <<<"$body"
}

@test "a failing gh api call on the comment warns and leaves land's exit code alone" {
  land_ready
  GH_API_FAIL=1 run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"* ]]
  [ "${lines[${#lines[@]}-1]}" = pr=10 ]
  run bash "$SCRIPT" next feat
  coder 3
  GH_API_FAIL=1 CHECKS_RC=1 run bash "$SCRIPT" land feat 3 feature/feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"solve-feature: 3 checks failed"* ]]
}

# --- packaging and the skill -------------------------------------------------------------

@test ".solve-feature/ is gitignored here" {
  git -C "$REPO_ROOT" check-ignore -q .solve-feature/x.log
}

@test "no agent CLI is launched: agent.sh is gone and neither skill mentions --agent, SOLVE_FEATURE_AGENT, --budget or afk.models" {
  [ ! -e "$REPO_ROOT/skills/review-pr/scripts/agent.sh" ]
  ! grep -rnE -- '--agent|SOLVE_FEATURE_AGENT|--budget|afk\.models' "$REPO_ROOT/skills/solve-feature" "$REPO_ROOT/skills/review-pr"
}

@test "install.sh claude --skill solve-feature ships the script and review-pr's script, no agent.sh, the Actions host" {
  local target="$TEMP_DIR/target"
  mkdir -p "$target" && git -C "$target" init -q -b main
  TARGET_REPO="$target" run bash "$REPO_ROOT/install.sh" claude --skill solve-feature
  [ "$status" -eq 0 ]
  [ -x "$target/.coding-crew/solve-feature/scripts/solve-feature.sh" ]
  [ -x "$target/.coding-crew/review-pr/scripts/review-pr.sh" ]
  [ ! -e "$target/.coding-crew/review-pr/scripts/agent.sh" ]
  [ -f "$target/.coding-crew/solve-feature/hosts/github-actions.yml" ]
  [ ! -x "$target/.coding-crew/solve-feature/hosts/github-actions.yml" ]
  [ -f "$target/.claude/skills/solve-feature/SKILL.md" ]
  [ -f "$target/.claude/skills/review-pr/SKILL.md" ]
  [ -f "$target/.coding-crew/solve-issue/scripts/run-checks.sh" ]
  [ -f "$target/.coding-crew/dep-install/scripts/run.sh" ]
  [ "$(jq -c '.skills["solve-feature"].deps' "$REPO_ROOT/registry.json")" = '["solve-issue","dep-install","review-pr","tdd"]' ]
}

# --- hosts -------------------------------------------------------------------------------

# YAML → JSON with whatever parser the machine has: js-yaml for node, else PyYAML. Exit 3 when
# neither exists, the parser's own non-zero exit when the file does not parse.
yaml_to_json() {
  if node -e 'require.resolve("js-yaml")' >/dev/null 2>&1; then
    node -e 'const y=require("js-yaml"),fs=require("fs");fs.writeFileSync(process.argv[2],JSON.stringify(y.load(fs.readFileSync(process.argv[1],"utf8"))))' "$1" "$2"
  elif python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import sys,json,yaml;json.dump(yaml.safe_load(open(sys.argv[1])),open(sys.argv[2],"w"))' "$1" "$2"
  else
    return 3
  fi
}

@test "hosts/github-actions.yml parses: labeled-issue and workflow_dispatch triggers, a label gate, four write permissions, a slug concurrency group, the skill launched by copilot -p, then a step failing on a stop or a missing review" {
  local wf="$REPO_ROOT/skills/solve-feature/hosts/github-actions.yml" json="$TEMP_DIR/wf.json"
  run yaml_to_json "$wf" "$json"
  [ "$status" -ne 3 ] || skip "no YAML parser on this machine (node js-yaml or python3 PyYAML)"
  [ "$status" -eq 0 ]
  # A YAML 1.1 parser (PyYAML) reads the `on` key as the boolean true.
  local on='(.on // .["true"])'
  [ "$(jq -c "$on.issues.types" "$json")" = '["labeled"]' ]
  [ "$(jq -r "$on.workflow_dispatch.inputs.slug.required" "$json")" = true ]
  grep -q '^ *# *schedule:' "$wf"
  [ "$(jq -r '.permissions | "\(.contents) \(.issues) \(.["pull-requests"]) \(.["copilot-requests"])"' "$json")" = "write write write write" ]
  jq -e '[.jobs[].if // empty] | any(test("github.event.label.name == .solve-feature."))' "$json" >/dev/null
  # The group holds the slug, so it is on the job that has it: a workflow-level group would only see the issue number.
  local conc; conc="$(jq -c '[.concurrency // empty, (.jobs[] | .concurrency // empty)]' "$json")"
  [ "$(jq 'length' <<<"$conc")" -eq 1 ]
  jq -e '.[0] | (.group | test("solve-feature-.*slug")) and .["cancel-in-progress"] == false' <<<"$conc" >/dev/null
  local runs; runs="$(jq -c '[.jobs.solve.steps[].run // empty]' "$json")"
  jq -e '.[-2] | contains("copilot -p \"Use the solve-feature skill on $SLUG\" --allow-all-tools --no-color")' <<<"$runs" >/dev/null
  jq -e '.[-1] | contains("-e .solve-feature/stopped") and contains("! -e .solve-feature/reviewed")' <<<"$runs" >/dev/null
  ! grep -q 'solve-feature\.sh' "$wf"
}
