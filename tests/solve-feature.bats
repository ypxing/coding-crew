#!/usr/bin/env bats

# solve-feature.sh start|next|land|fix|describe — the guards of solve-feature's loop, which SKILL.md drives with
# host subagents: start checks the slug, picks the branch and writes the spec, next saves the next ready issue,
# land asserts what the coder left (branch, clean tree, issue closed, checks) and pushes it into a draft PR, fix
# gates, commits and pushes what the review's fixer left, and describe writes the PR body, marks it ready when
# nothing needs a person and writes .solve-feature/outcome.
#
# A temp clone with a bare `origin`, and the skill's scripts/ as install.sh lays it out: its own
# script beside the tracker and checks library links. `gh`, `node` (only for the tracker CLI's path; everything else reaches the
# real node) and solve-issue's run-checks.sh are stubs that log their argv; the node stub answers
# `next` from $STATE/issues.json by the tracker's dispatch rule. `coder <ref>` stands in for the
# subagent: it commits a file and swaps the issue's ready-for-agent label for awaiting-merge, as
# solve-issue's mark-done does.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
  # Physical path: the script's paths come from `git rev-parse --show-toplevel`, which resolves
  # macOS's /var → /private/var symlink on the temp dir.
  TEMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
  export STATE="$TEMP_DIR/state" HOME="$TEMP_DIR/home"
  mkdir -p "$STATE" "$HOME"
  unset PR_EXISTS PR_DRAFT PR_HEAD_OID PR_STATE PR_HEAD_REF GH_READY_FAIL TRACKER_KIND SOLVE_FEATURE_HOST

  INSTALL="$HOME/skill/scripts"
  mkdir -p "$HOME/skill"
  cp -R "$REPO_ROOT/skills/solve-feature/scripts" "$INSTALL"
  mkdir -p "$INSTALL/tracker" "$INSTALL/checks"
  cp "$REPO_ROOT/lib/checks/commands-file.sh" "$INSTALL/checks/"
  : > "$INSTALL/tracker/cli.mjs"
  SCRIPT="$INSTALL/solve-feature.sh"

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
case "\$1" in */scripts/tracker/cli.mjs) ;; *) exec "$REAL_NODE" "\$@" ;; esac
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
  features) printf 'feat\topen\t2\nother\tclosed\t0\n' ;;
  # \`known\`: every issue but a PRD: one, named <number>-<title>.md, or by its ref's basename.
  known) mkdir -p "\$6"
    jq -r '.[] | select(.title | test("^PRD:") | not) | "\\(.ref // (.number | tostring))\\t\\(.ref // "\\(.number)-\\(.title | ascii_downcase).md")"' "\$STATE/issues.json" |
      while IFS=\$'\\t' read -r r n; do cp "\$STATE/\${r//\\//_}.md" "\$6/\${n##*/}"; done ;;
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
file=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --body-file) file="${args[$((i + 1))]}" ;;
    --title) printf '%s' "${args[$((i + 1))]}" > "$STATE/pr-title" ;;
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
  "pr ready") [ -z "${GH_READY_FAIL:-}" ] || exit 1 ;;
  *) exit 1 ;;
esac
EOF

  cat > "$INSTALL/checks/run-checks.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATE/checks.log"
git status --porcelain > "$STATE/checks.status"
for i in $(seq 1 30); do echo "check line $i"; done
echo "test: ${CHECK_RESULT:-pass}"
[ "${CHECKS_RC:-0}" != 3 ] || { echo DISCOVER; exit 3; }
[ "${CHECKS_RC:-0}" = 0 ] && echo "CHECKS: pass" || echo "CHECKS: fail"
exit "${CHECKS_RC:-0}"
EOF
  chmod +x "$STUB"/* "$INSTALL"/checks/*.sh
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
  for args in "" "feat" "run feat" "next" "land feat 2" "fix feat 10" "fix feat 10 feature/feat x" "fix feat ten feature/feat" "describe feat" "describe feat ten" "start feat --agent copilot" "start feat --budget 5" "start feat --open-pr" "start feat other"; do
    run bash "$SCRIPT" $args
    [ "$status" -eq 2 ] || { echo "'$args': status $status"; return 1; }
    [[ "$output" == *"usage: solve-feature.sh start <slug> [--branch <name>] | next <slug> | land <slug> <ref> <branch> | fix <slug> <pr> <branch> | describe <slug> <pr>"* ]]
  done
  [ ! -f "$STATE/gh.log" ]
  [ ! -e "$WORK/.solve-feature/outcome" ]
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

  mv "$INSTALL/tracker/cli.mjs" "$TEMP_DIR/cli.mjs"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"tracker CLI not found"* ]]
  mv "$TEMP_DIR/cli.mjs" "$INSTALL/tracker/cli.mjs"

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
  [ "$(cat .solve-feature/outcome)" = "stopped: start failed: no feature 'feta'; features: feat other" ]
}

# --- start: the dev commands file -----------------------------------------------------

@test "start with no dev commands file, even beside a compose file, starts: the first coder discovers checks and mode" {
  printf 'services:\n  app:\n    image: node\n' > compose.yml
  git rm -q .coding-crew/dev-commands.json && git add compose.yml && git commit -q -m "no commands"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out branch)" = feature/feat ]
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
  [[ "$(cat .solve-feature/outcome)" == "stopped: start failed: git fetch origin failed"* ]]
  git remote set-url origin "$TEMP_DIR/origin.git"
  chmod -w "$TEMP_DIR/origin.git/refs/heads"
  run bash "$SCRIPT" start feat
  chmod +w "$TEMP_DIR/origin.git/refs/heads"
  [ "$status" -eq 1 ]
  [[ "$(cat .solve-feature/outcome)" == "stopped: start failed: cannot push feature/feat"* ]]
  # The refused push left the local branch behind; a re-run pushes it rather than reuse it unpushed.
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
  [ "$(git rev-parse --abbrev-ref '@{u}')" = origin/feature/feat ]
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

@test "start writes .solve-feature/spec.md: the PRD, then each issue known writes with its criteria as plain bullets" {
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat .solve-feature/spec.md)" = "$(cat <<'EOF'
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
  mkdir -p .solve-feature && echo '*' > .solve-feature/.gitignore && echo 'ready pr=7' > .solve-feature/outcome
  echo old > .solve-feature/pr-7.unfixed.md && echo old > .solve-feature/pr-7.review.json
  echo old > .solve-feature/pr-7.summary.md && echo old > .solve-feature/pr-7.attention.md
  rm "$STATE/prd.md"
  jq 'map(if .number == 2 then .state = "CLOSED" else . end)' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(head -1 .solve-feature/spec.md)" = "### 2-two — Two" ]
  grep -qx '### 3-three — Three' .solve-feature/spec.md
  ! grep -q PRD .solve-feature/spec.md || false
  [ ! -e .solve-feature/outcome ]
  [ ! -e .solve-feature/pr-7.unfixed.md ]
  [ ! -e .solve-feature/pr-7.review.json ]
  [ ! -e .solve-feature/pr-7.summary.md ]
  [ ! -e .solve-feature/pr-7.attention.md ]
}

# --- next ------------------------------------------------------------------------------

@test "next prints the ready ref and saves its issue; exit 3 when none is left; a ref fetch rejects exits 1" {
  run bash "$SCRIPT" next feat
  [ "$status" -eq 0 ]
  [ "$output" = 2 ]
  [ "$(cat .solve-feature/2.issue.md)" = "$(cat "$STATE/2.md")" ]
  jq 'map(.state = "CLOSED")' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  PR_EXISTS=1 run bash "$SCRIPT" next feat
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ ! -e .solve-feature/outcome ]
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
  [ "$(cat .solve-feature/outcome)" = "stopped: next failed: nothing landed: no ready issue for feat and no open PR" ]
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

# --- land: guards ----------------------------------------------------------------------

# stops_at <step> <reason> — land just exited 1: nothing pushed, the stop in .solve-feature/outcome.
stops_at() {
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: 2 $1 failed: $2"* ]] || { echo "$output"; return 1; }
  [ "$(git ls-remote origin feature/feat | cut -f1)" != "$(git rev-parse HEAD)" ] || { echo pushed; return 1; }
  [ ! -f "$STATE/pr-created" ]
  [[ "$(cat .solve-feature/outcome)" == "stopped: 2 $1 failed: $2"* ]]
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

@test "land after a coder committed [WIP] and left its issue open exits 1 'did not close' naming the coder's report, before the checks" {
  run bash "$SCRIPT" start feat
  echo "stale" > .solve-feature/coder.report.md
  run bash "$SCRIPT" next feat
  # solve-issue's partial: the work committed with a [WIP] marker, the tree clean, the issue not closed.
  echo half > half.txt && git add half.txt && git commit -q -m "[2][WIP] half the work"
  run bash "$SCRIPT" land feat 2 feature/feat
  stops_at solve "coder ran but did not close 2 and left no report at $WORK/.solve-feature/coder.report.md"
  [ ! -f "$STATE/checks.log" ]
  echo "partial: the schema test needs a fixture" > .solve-feature/coder.report.md
  run bash "$SCRIPT" land feat 2 feature/feat
  stops_at solve "coder ran but did not close 2; why: $WORK/.solve-feature/coder.report.md"
}

@test "land runs run-checks.sh once; exit 1 or 3 stops at checks naming the log, 3 sending the user to /setup-coding-crew" {
  land_ready
  CHECKS_RC=1 run bash "$SCRIPT" land feat 2 feature/feat
  stops_at checks "run-checks.sh exit 1; once fixed and committed, run land feat 2 feature/feat before a re-run"
  [[ "$output" == *"$WORK/.solve-feature/2.checks.log"* ]]
  [ "$(cat "$STATE/checks.log")" = "--project-root $WORK" ]
  CHECKS_RC=3 run bash "$SCRIPT" land feat 2 feature/feat
  stops_at checks "no check commands known (DISCOVER): the coder discovered none; run /setup-coding-crew and commit .coding-crew/dev-commands.json, then run land feat 2 feature/feat before a re-run"
  # The recovery the stop names: land again once the checks pass, and the issue's commits are pushed.
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ]
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]
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

@test "the first land pushes and creates the draft PR with a one-line body; a later land edits nothing and no land comments" {
  land_ready
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 0 ]
  [ "$output" = pr=10 ]
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
  [ "$output" = pr=10 ]
  [ ! -f "$STATE/pr-create.2" ]
  ! grep -qE '^pr (edit|ready|comment)|^api' "$STATE/gh.log" || false
  [ "$(git rev-parse origin/feature/feat)" = "$(git rev-parse feature/feat)" ]
}

@test "an existing open PR is reused as it is: no create, no edit, its draft state untouched" {
  export PR_EXISTS=1 PR_DRAFT=false
  loop
  [ "$LAST_PR" = 9 ]
  [ ! -f "$STATE/pr-created" ]
  ! grep -qE '^pr (create|edit|ready)' "$STATE/gh.log" || false
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
  issues '[{"number":1,"ref":".scratch/feat/issues/open/01-a.md","title":"A","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":2,"ref":".scratch/feat/issues/open/02-b.md","title":"B","state":"OPEN","labels":[{"name":"ready-for-agent"}]}]'
  issue_body .scratch/feat/issues/open/01-a.md "Local A" None
  issue_body .scratch/feat/issues/open/02-b.md "Local B" None
  printf '# PRD\n\nlocal prd without a title note\n' > "$STATE/prd.md"
  run bash "$SCRIPT" start feat
  grep -qx '### 01-a — Local A' .solve-feature/spec.md
  run bash "$SCRIPT" next feat
  [ "$output" = .scratch/feat/issues/open/01-a.md ]
  coder .scratch/feat/issues/open/01-a.md
  rm "$STATE/.scratch_feat_issues_open_01-a.md.md" # the close moved it: fetch now exits 3
  run bash "$SCRIPT" land feat .scratch/feat/issues/open/01-a.md feature/feat
  [ "$status" -eq 0 ]
  [ -f "$WORK/.solve-feature/.scratch_feat_issues_open_01-a.md.checks.log" ]
  [ "$(cat "$STATE/pr-title")" = "Local A" ]
  ! grep -q '^config' "$STATE/node.log" || false
}

@test "start, next and land reach the tracker through features, prd, known, next and fetch only, and name no tracker kind" {
  loop
  [ "$(cut -d' ' -f1 "$STATE/node.log" | sort -u | paste -sd' ' -)" = "features fetch known next prd" ]
  ! grep -nE 'KIND|github|\.scratch|"\$CLI" config|\$REF" =~' "$SCRIPT" || false
}

@test "a rejected push stops land naming the land to re-run, since a plain re-run would skip the closed issue" {
  land_ready
  printf '#!/bin/sh\nexit 1\n' > "$TEMP_DIR/origin.git/hooks/pre-receive" && chmod +x "$TEMP_DIR/origin.git/hooks/pre-receive"
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: 2 push failed: git push failed; once it can push, run land feat 2 feature/feat before a re-run"* ]]
  [ ! -f "$STATE/pr-created" ]
  grep -q 'run land feat 2 feature/feat' .solve-feature/outcome
}

@test "land with the checks library missing exits 1 naming it, before the checks" {
  land_ready
  rm -rf "$INSTALL/checks"
  run bash "$SCRIPT" land feat 2 feature/feat
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"checks library not found"* ]]
  [ ! -f "$STATE/checks.log" ]
  grep -q 'checks library not found' .solve-feature/outcome
}

# --- fix: after the review -------------------------------------------------------------

# fix_ready [<report json>] — both issues landed in PR #10, reviewed at HEAD (default report: met, two
# findings, no gaps) and the fixer's edit left uncommitted: fix's input as SKILL.md leaves it.
fix_ready() {
  loop
  [ "$LAST_PR" = 10 ]
  local two='{"spec":"met","gaps":[],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"},{"severity":"LOW","location":"b:2","issue":"j","fix":"g"}]}'
  report "${1:-$two}"
  echo fixed > fixed.txt
}
# report <json> — the reviewer's report.
report() { printf '%s\n' "$1" > .solve-feature/pr-10.review.json; }
pushed() { [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]; }
# fix_stops <reason> — exit 1, nothing pushed, the stop in .solve-feature/outcome, the PR left as it was.
fix_stops() {
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"solve-feature: review fix failed: $1"* ]] || { echo "$output"; return 1; }
  [ "$(git ls-remote origin feature/feat | cut -f1)" = "$TIP" ] || { echo pushed; return 1; }
  [[ "$(cat .solve-feature/outcome)" == "stopped: review fix failed: $1"* ]]
  ! grep -qE '^pr (ready|edit)' "$STATE/gh.log" || false
}
# attention — what fix handed describe.
attention() { cat .solve-feature/pr-10.attention.md; }

@test "fix on another branch, or with a missing or unreadable report, stops before the checks" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  local checks; checks=$(wc -l < "$STATE/checks.log")
  git checkout -q -b elsewhere
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "branch changed to 'elsewhere'"
  git checkout -q feature/feat
  rm .solve-feature/pr-10.review.json
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "no review report at $WORK/.solve-feature/pr-10.review.json"
  report 'not json'
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "unreadable review report $WORK/.solve-feature/pr-10.review.json"
  [ "$(wc -l < "$STATE/checks.log")" -eq "$checks" ]
  [ "$(cat fixed.txt)" = fixed ]
}

@test "a report whose gaps is not a list stops fix before the checks" {
  fix_ready '{"spec":"met","gaps":"no logout endpoint","findings":[]}'
  TIP=$(git rev-parse HEAD)
  local checks; checks=$(wc -l < "$STATE/checks.log")
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "the review report's gaps is not a list: $WORK/.solve-feature/pr-10.review.json"
  [ "$(wc -l < "$STATE/checks.log")" -eq "$checks" ]
}

@test "fix with failing checks stops naming the log, leaving the tree and commits, or with none known sends the user to /setup-coding-crew; a second fix once committed completes" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  : > "$STATE/checks.log"
  CHECKS_RC=1 run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "run-checks.sh exit 1; once fixed and committed (not pushed), run fix feat 10 feature/feat, then describe feat 10"
  [[ "$output" == *"log: $WORK/.solve-feature/pr-10.checks.log"* ]]
  [ "$(cat "$STATE/checks.log")" = "--project-root $WORK" ]
  [ "$(git rev-parse HEAD)" = "$TIP" ]
  [ "$(git status --porcelain)" = 'A  fixed.txt' ]
  CHECKS_RC=3 run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "no check commands known (DISCOVER): run /setup-coding-crew and commit .coding-crew/dev-commands.json"

  git add fixed.txt && git commit -q -m "fix by hand"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  pushed
  [ "$(git rev-parse HEAD~1)" = "$TIP" ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=0 review-again=yes" ]
}

@test "the checks see the fixer's edits staged, so run-checks.sh's own modified-files test catches a check that rewrites one" {
  fix_ready
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/checks.status")" = 'A  fixed.txt' ]
}

@test "a rejected push stops fix naming the recovery" {
  fix_ready
  TIP=$(git rev-parse HEAD)
  printf '#!/bin/sh\nexit 1\n' > "$TEMP_DIR/origin.git/hooks/pre-receive" && chmod +x "$TEMP_DIR/origin.git/hooks/pre-receive"
  run bash "$SCRIPT" fix feat 10 feature/feat
  fix_stops "git push failed; once it can push, run fix feat 10 feature/feat, then describe feat 10"
}

@test "a fixer that changed nothing fixed nothing: the findings need attention" {
  fix_ready
  rm fixed.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = "the fixer changed nothing" ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=1 review-again=no" ]
  # A fixer that said why it changed nothing is listed for what it said, as it wrote it, not twice.
  printf -- '- a:1 needs a design call\n\nb:2 too\n' > .solve-feature/pr-10.unfixed.md
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$(attention)" = "$(printf -- '- a:1 needs a design call\nb:2 too')" ]
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
  [ -f .solve-feature/pr-10.attention.md ]
  [ -z "$(attention)" ]
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ ! -e .solve-feature/stopped ]
  [ ! -e .solve-feature/reviewed ]
  [ ! -e .solve-feature/outcome ]
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

@test "a gap, an unmet spec and each unfixed line are handed to describe as needing attention" {
  fix_ready '{"spec":"unmet","gaps":["no logout endpoint"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"},{"severity":"LOW","location":"b:2","issue":"j","fix":"g"}]}'
  printf -- '#2: race on the lock: needs a design call\n\n' > .solve-feature/pr-10.unfixed.md
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = "$(printf 'no logout endpoint\nthe reviewer found the spec unmet\n#2: race on the lock: needs a design call')" ]
  [ ! -e .solve-feature/pr-10.unfixed.md ]
  [ "${lines[${#lines[@]}-1]}" = "FIX: findings=2 needs-attention=3 review-again=yes" ]

  # The spec unmet with no gap named still needs a person.
  report '{"spec":"unmet","gaps":[],"findings":[]}'
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  [ "$(attention)" = "the reviewer found the spec unmet" ]
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

@test "a second fix after a re-review leaves only its own gaps and unfixed lines needing attention" {
  fix_ready '{"spec":"met","gaps":["first gap"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}]}'
  echo 'first unfixed' > .solve-feature/pr-10.unfixed.md
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$(attention)" = "$(printf 'first gap\nfirst unfixed')" ]
  report '{"spec":"met","gaps":["second gap"],"findings":[{"severity":"LOW","location":"b:2","issue":"j","fix":"g"}]}'
  echo 'second unfixed' > .solve-feature/pr-10.unfixed.md
  echo second > fixed.txt
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(attention)" = "$(printf 'second gap\nsecond unfixed')" ]
}

@test "fix posts nothing on the PR" {
  fix_ready '{"spec":"unmet","gaps":["g"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}]}'
  echo 'x' > .solve-feature/pr-10.unfixed.md
  : > "$STATE/gh.log"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ]
  [ "$(grep -E '^(pr|api|issue|repo) ' "$STATE/gh.log" | cut -d' ' -f1-3 | sort -u)" = "pr view 10" ]
}

# --- describe: the PR body, readiness and the outcome ----------------------------------

# summary — what the writer subagent leaves: write-pr's title line and body.
summary() { printf '# Let users log in\n\n## Why\n\nUsers need accounts.\n\n**Tested:** checks pass\n' > .solve-feature/pr-10.summary.md; }
# fixed [<report json>] — fix_ready, then fix: describe's input as SKILL.md leaves it.
fixed() {
  fix_ready "$@"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "fix: $output"; return 1; }
}

@test "describe writes the whole body once in order, titles the PR from the summary, then marks the draft ready and writes ready" {
  fixed
  printf 'hand text\n' > "$STATE/pr-body"
  summary
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$STATE/pr-title")" = "Let users log in" ]
  [ "$(cat "$STATE/pr-body")" = "$(cat <<EOF
<!-- solve-feature:begin -->
## Why

Users need accounts.

**Tested:** checks pass

<details><summary>Spec</summary>

$(cat .solve-feature/spec.md)

</details>

Closes #2
Closes #3
<!-- solve-feature:slug feat -->
<!-- solve-feature:end -->
EOF
)" ]
  [ "$(grep -E '^pr (edit|ready)' "$STATE/gh.log" | cut -d' ' -f1-3)" = "$(printf 'pr edit 10\npr ready 10')" ]
  [ "$(cat .solve-feature/outcome)" = "ready pr=10" ]
  [ "${lines[${#lines[@]}-1]}" = "ready pr=10" ]

  # A second describe rewrites the body rather than stacking the summary.
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ]
  [ "$(grep -c '^## Why$' "$STATE/pr-body")" -eq 1 ]
  [ "$(grep -c '^### 2-two — Two$' "$STATE/pr-body")" -eq 1 ]
}

@test "with anything needing a person describe lists it under Needs attention, leaves the PR a draft and writes needs-attention" {
  fixed '{"spec":"met","gaps":["no logout endpoint"],"findings":[{"severity":"HIGH","location":"a:1","issue":"i","fix":"f"}]}'
  summary
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(sed -n '/^## Needs attention$/,/^<details>/p' "$STATE/pr-body")" = "$(printf '## Needs attention\n\n- no logout endpoint\n\n<details><summary>Spec</summary>')" ]
  [ "$(grep -n -m1 '^## Why$' "$STATE/pr-body" | cut -d: -f1)" -lt "$(grep -n -m1 '^## Needs attention$' "$STATE/pr-body" | cut -d: -f1)" ]
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ "$(cat .solve-feature/outcome)" = "needs-attention pr=10" ]
}

@test "a report whose spec is unmet, with no gap or finding, leaves the PR a draft and writes needs-attention" {
  fixed '{"spec":"unmet","gaps":[],"findings":[]}'
  [ "$(attention)" = "the reviewer found the spec unmet" ]
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ "$(cat .solve-feature/outcome)" = "needs-attention pr=10" ]
}

@test "a PR already ready is not marked again; with no summary describe keeps land's title and still decides readiness" {
  fixed
  PR_DRAFT=false run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -q '^pr ready' "$STATE/gh.log" || false
  [ "$(cat "$STATE/pr-title")" = Feat ]
  [ "$(head -2 "$STATE/pr-body")" = "$(printf '<!-- solve-feature:begin -->\n<details><summary>Spec</summary>')" ]
  [ "$(cat .solve-feature/outcome)" = "ready pr=10" ]
}

@test "describe with no fix result, a failing closing-refs or a failing gh pr ready stops, never writing ready" {
  fix_ready
  run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 1 ]
  [[ "$output" == *"run fix feat 10 <branch> first"* ]]
  [[ "$(cat .solve-feature/outcome)" == "stopped: describe failed: "* ]]
  ! grep -q '^pr edit' "$STATE/gh.log" || false

  run bash "$SCRIPT" fix feat 10 feature/feat
  CLOSING_REFS_RC=1 run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 1 ]
  [[ "$output" == *"closing-refs failed for 'feat'"* ]]
  [[ "$(cat .solve-feature/outcome)" == "stopped: describe failed: closing-refs failed"* ]]
  ! grep -q '^pr edit' "$STATE/gh.log" || false

  GH_READY_FAIL=1 run bash "$SCRIPT" describe feat 10
  [ "$status" -eq 1 ]
  [[ "$(cat .solve-feature/outcome)" == "stopped: describe failed: gh pr ready 10 failed"* ]]
}

# --- packaging and the skill -------------------------------------------------------------

@test ".solve-feature/ is gitignored here" {
  git -C "$REPO_ROOT" check-ignore -q .solve-feature/x.log
}

@test "no agent CLI is launched: agent.sh is gone and neither skill mentions --agent, SOLVE_FEATURE_AGENT, --budget or afk.models" {
  ! grep -rnE -- '--agent|SOLVE_FEATURE_AGENT|--budget|afk\.models' "$REPO_ROOT/skills/solve-feature" "$REPO_ROOT/skills/crew-review" || false
}

@test "SKILL.md runs its reviewer through the crew-review skill on the spec start wrote, names no other skill's files, and no SOLVE_FEATURE_HOST" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'Use the crew-review skill on branch <branch> against the spec in <repo>/.solve-feature/spec.md; write the report to <repo>/.solve-feature/pr-<n>.review.json' "$skill"
  ! grep -qF '<skill-dir>/..' "$skill" || false
  ! grep -qF 'SOLVE_FEATURE_HOST' "$skill" || false
  ! grep -qF 'review-pr' "$skill" || false
}

@test "SKILL.md reviews once more only on review-again=yes after the first review, then goes on to the PR body" {
  local skill="$REPO_ROOT/skills/solve-feature/SKILL.md"
  grep -qF 'FIX: findings=<k> needs-attention=<a> review-again=yes|no' "$skill"
  grep -qF '`review-again=yes` means run 3.1–3.3 once more; after the second review, go on to 3.4 whatever it prints' "$skill"
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
  [ -f "$target/.claude/skills/solve-feature/scripts/checks/run-checks.sh" ]
  [ -f "$target/.claude/skills/solve-feature/scripts/checks/run.sh" ]
  [ -f "$target/.claude/skills/solve-feature/scripts/tracker/cli.mjs" ]
  [ "$(jq -c '.skills["solve-feature"].deps' "$REPO_ROOT/registry.json")" = '["solve-issue","crew-review","tdd","write-pr","setup-coding-crew"]' ]
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

@test "setup-coding-crew's hosts/github-actions.yml parses: labeled-issue and workflow_dispatch triggers, a label gate, four write permissions, a slug concurrency group, the skill launched by copilot -p, then a step reading the outcome" {
  local wf="$REPO_ROOT/skills/setup-coding-crew/hosts/github-actions.yml" json="$TEMP_DIR/wf.json"
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
  ! grep -q 'solve-feature\.sh' "$wf" || false
  ! grep -q 'SOLVE_FEATURE_HOST' "$wf" || false
  ! grep -q 'review-pr' "$wf" || false

  # The last step, run as Actions would in the checkout: red unless the outcome line starts with `ready`.
  jq -r '.jobs.solve.steps[-1].run' "$json" > "$TEMP_DIR/last-step.sh"
  run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"never finished"* ]]
  mkdir -p .solve-feature
  echo 'needs-attention pr=10' > .solve-feature/outcome
  run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs-attention pr=10"* ]]
  echo 'stopped: 2 checks failed: run-checks.sh exit 1' > .solve-feature/outcome
  run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"stopped: 2 checks failed: run-checks.sh exit 1"* ]]
  echo 'ready pr=10' > .solve-feature/outcome
  run bash -e "$TEMP_DIR/last-step.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ready pr=10"* ]]
}
