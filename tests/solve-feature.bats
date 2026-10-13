#!/usr/bin/env bats

# solve-feature.sh — one feature's ready issues, in order, on one branch: per issue the coder, the
# checks and the tracker's own close; a draft PR carrying the spec after the first landed issue;
# review-pr on it at the end.
#
# A temp clone with a bare `origin`, and the skill installed user-level under a temp $HOME as
# install.sh lays it out. `claude`, `copilot`, `gh`, `node` (only for the tracker CLI's path;
# everything else reaches the real node), `timeout`, solve-issue's run-checks.sh, dep-install's
# install scripts and review-pr.sh are stubs that log their argv: the coder stub commits a file and
# swaps the issue's ready-for-agent label for awaiting-merge, as solve-issue's mark-done does; the
# node stub answers `next` from $STATE/issues.json by the tracker's dispatch rule.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
  # Physical path: the script's paths come from `git rev-parse --show-toplevel`, which resolves
  # macOS's /var → /private/var symlink on the temp dir.
  TEMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
  export STATE="$TEMP_DIR/state" HOME="$TEMP_DIR/home" SOLVE_FEATURE_HOST=test-host
  mkdir -p "$STATE" "$HOME"
  unset CREW_ORCHESTRATED SOLVE_FEATURE_AGENT PR_EXISTS PR_DRAFT TRACKER_KIND

  INSTALL="$HOME/.coding-crew"
  mkdir -p "$INSTALL/solve-feature" "$INSTALL/solve-issue/scripts" "$INSTALL/dep-install/scripts" "$INSTALL/review-pr" "$INSTALL/tracker"
  cp -R "$REPO_ROOT/skills/solve-feature/scripts" "$INSTALL/solve-feature/scripts"
  cp -R "$REPO_ROOT/skills/review-pr/scripts" "$INSTALL/review-pr/scripts"
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
  fetch) cat "\$STATE/\${3//\//_}.md" ;;
  prd) [ -f "\$STATE/prd.md" ] || exit 3; cat "\$STATE/prd.md" ;;
  closing-refs) jq -r 'sort_by(.number) | .[] | select(.state == "OPEN" and any(.labels[]; .name == "awaiting-merge")) | "Closes #\(.number)"' "\$STATE/issues.json" ;;
  *) exit 2 ;;
esac
EOF

  cat > "$STUB/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$STATE/timeout.log"
shift
exec "$@"
EOF

  # The coder, as claude or copilot: each call's argv, one arg per line, in <agent>.<k>.
  cat > "$STUB/claude" <<'EOF'
#!/usr/bin/env bash
me=$(basename "$0")
k=$(( $(ls "$STATE" | grep -c "^$me\.[0-9]*$") + 1 ))
printf '%s\n' "$@" > "$STATE/$me.$k"
env | grep -c '^CREW_ORCHESTRATED=' > "$STATE/$me.$k.env" || true
git branch --show-current > "$STATE/$me.$k.branch"
git ls-remote --heads origin "$(git branch --show-current)" | grep -c . > "$STATE/$me.$k.pushed" || true
git rev-parse --abbrev-ref '@{upstream}' > "$STATE/$me.$k.upstream" 2>/dev/null || true
[ ! -f "$STATE/pr-body" ] || cp "$STATE/pr-body" "$STATE/pr-body.before-$me.$k"
ref=$(sed -e 's|^/solve-issue ||' -e 's|^Use the solve-issue skill on \(.*\)\.$|\1|' <<<"$2")
echo "coder log for $ref"
[ -z "${CODER_EXIT:-}" ] || { for i in $(seq 1 30); do echo "coder line $i"; done; exit "$CODER_EXIT"; }
[ -z "${CODER_SWITCH:-}" ] || git checkout -q -b elsewhere
echo "$ref" > "work-${ref//\//_}.txt"
[ -n "${CODER_DIRTY:-}" ] || { git add "work-${ref//\//_}.txt"; git commit -q -m "[$ref] work"; }
if [ -n "${CODER_NO_CLOSE:-}" ]; then
  [ "$me" = copilot ] && echo '{"type":"assistant.message","data":{"content":"BLOCKED: Bash denied\nnothing was started"}}' \
    || echo '{"type":"result","result":"BLOCKED: Bash denied\nnothing was started"}'
  exit 0
fi
jq --arg r "$ref" 'map(if (.ref // (.number | tostring)) == $r then .labels = [{"name":"awaiting-merge"}] else . end)' "$STATE/issues.json" > "$STATE/i.tmp"
mv "$STATE/i.tmp" "$STATE/issues.json"
EOF
  cp "$STUB/claude" "$STUB/copilot"

  # `pr view` answers from the PR this run created ($STATE/pr-body) or PR_EXISTS (#9, body from
  # $STATE/pr-body when present, else a hand-written one); `pr create`/`pr edit` keep the body there.
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
    jq -n --argjson n "$n" --argjson d "${PR_DRAFT:-true}" --rawfile b "$STATE/pr-body" \
      '{number: $n, state: "OPEN", url: "https://github.com/o/r/pull/\($n)", isDraft: $d, body: $b}' ;;
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
echo "=== test: make test"
echo "test: ${CHECK_RESULT:-pass}"
echo "lint: NOT RUN: no command found"
[ "${CHECKS_RC:-0}" != 3 ] || { echo DISCOVER; exit 3; }
[ "${CHECKS_RC:-0}" = 0 ] && echo "CHECKS: pass" || echo "CHECKS: fail"
exit "${CHECKS_RC:-0}"
EOF

  cat > "$HOME/.coding-crew/dep-install/scripts/resolve-mode.sh" <<'EOF'
#!/usr/bin/env bash
printf 'resolve-mode.sh %s\n' "$*" >> "$STATE/prepare.log"
echo "INSTALL_MODE=${STUB_INSTALL_MODE:-host}"; echo "DOCKER_SERVICE=${STUB_DOCKER_SERVICE:-}"; echo "ACTION=on-failure"
EOF
  local s
  for s in host-install docker-install; do
    cat > "$HOME/.coding-crew/dep-install/scripts/$s.sh" <<EOF
#!/usr/bin/env bash
printf '$s.sh %s\n' "\$*" >> "\$STATE/prepare.log"
echo "install output"; exit "\${INSTALL_RC:-0}"
EOF
  done

  cat > "$HOME/.coding-crew/review-pr/scripts/review-pr.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATE/review.log"
echo "REVIEW: ${REVIEW_LINE:-prd=met findings=0 (0 inline) ready=yes}"
exit "${REVIEW_RC:-0}"
EOF
  chmod +x "$STUB"/* "$HOME"/.coding-crew/*/scripts/*.sh
}

# agent_call <agent> <k> — the k-th argv of that agent, one arg per line.
agent_call() { cat "$STATE/$1.$2"; }
agent_calls() { ls "$STATE" | grep -c "^$1\.[0-9]*$" || true; }
# The value after flag $3 in call $2 of agent $1.
agent_flag() { agent_call "$1" "$2" | grep -A1 -x -- "$3" | tail -1; }
# coder_issues [agent] — the refs the coder was run on, in order.
coder_issues() {
  local a="${1:-claude}" k
  for k in $(seq 1 "$(agent_calls "$a")"); do agent_flag "$a" "$k" -p | sed -e 's|^/solve-issue ||' -e 's|^Use the solve-issue skill on \(.*\)\.$|\1|'; done | paste -sd' ' -
}
# progress_body — the one solve-feature-progress comment's body; fails unless exactly one exists.
progress_body() {
  [ "$(jq '[.[] | select(.body | contains("<!-- solve-feature-progress -->"))] | length' "$STATE/comments.json")" = 1 ] || return 1
  jq -r '.[] | select(.body | contains("<!-- solve-feature-progress -->")) | .body' "$STATE/comments.json"
}
# body_of <pr-create.k|pr-edit.k> — the body file that call was given.
body_of() { cat "$(grep -A1 -x -- --body-file "$STATE/$1" | tail -1)"; }

# --- preconditions -------------------------------------------------------------------

@test "a missing tool, an unknown agent, --open-pr, an invalid slug, a dirty tree or no dev-commands.json exits 1 before any checkout, agent, install or gh call" {
  local tool
  for tool in claude gh jq timeout; do
    local bin="$TEMP_DIR/bin-$tool"
    mkdir -p "$bin"
    for t in bash env git node jq gh claude copilot timeout dirname cat grep sed awk mkdir hostname date head tail tr printf rm; do
      [ "$t" = "$tool" ] && continue
      p=$(PATH="$STUB:$PATH" command -v "$t") && ln -sf "$p" "$bin/$t"
    done
    PATH="$bin" run "$bin/bash" "$SCRIPT" feat
    [ "$status" -eq 1 ] || { echo "$tool: status $status"; return 1; }
    [[ "$output" == *"$tool"* ]] || { echo "$tool: $output"; return 1; }
  done

  run bash "$SCRIPT" feat --agent other
  [ "$status" -eq 1 ]
  [[ "$output" == *"other"* ]]
  run bash "$SCRIPT" feat --open-pr
  [ "$status" -eq 1 ]
  [[ "$output" == *"--open-pr"* ]]

  run bash "$SCRIPT" '../x'
  [ "$status" -eq 1 ]
  [[ "$output" == *"slug"* ]]

  git rm -q .coding-crew/dev-commands.json && git commit -q -m "no commands"
  run bash "$SCRIPT" feat
  [ "$status" -eq 1 ]
  [[ "$output" == *".coding-crew/dev-commands.json"* ]]
  git revert --no-edit HEAD >/dev/null

  echo dirt > dirt.txt
  run bash "$SCRIPT" feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"clean"* ]]

  [ "$(git branch --show-current)" = main ]
  [ "$(agent_calls claude)" -eq 0 ]
  [ "$(agent_calls copilot)" -eq 0 ]
  [ ! -f "$STATE/gh.log" ]
  [ ! -f "$STATE/prepare.log" ]
}

# --- branch ------------------------------------------------------------------------

@test "on the default branch it creates feature/<slug> from origin/main and pushes it with upstream before the first coder" {
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

# --- the loop ------------------------------------------------------------------------

@test "two ready issues: one claude coder call each under timeout 60m, run-checks.sh once each, no CREW_ORCHESTRATED" {
  CREW_ORCHESTRATED=1 run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(agent_calls claude)" -eq 2 ]
  [ "$(coder_issues)" = "2 3" ]
  [ "$(agent_call claude 1 | paste -sd' ' -)" = "-p /solve-issue 2 --output-format json --max-budget-usd 10 --model sonnet --permission-mode bypassPermissions" ]
  [ "$(agent_call claude 2 | paste -sd' ' -)" = "-p /solve-issue 3 --output-format json --max-budget-usd 10 --model sonnet --permission-mode bypassPermissions" ]
  [ "$(sort -u "$STATE/timeout.log")" = 60m ]
  [ "$(cat "$STATE/claude.1.env")" = 0 ]
  [ "$(head -1 "$STATE/checks.log")" = "--project-root $WORK --main-root $WORK --dep-scripts $HOME/.coding-crew/dep-install/scripts" ]
  [ "$(wc -l < "$STATE/checks.log")" -eq 2 ]
  [ -z "$(git status --porcelain)" ]
}

@test "--budget and afk.models.claude.coder reach the coder" {
  git checkout -q -b topic
  echo '{"tracker":{"kind":"github"},"afk":{"models":{"claude":{"coder":"haiku"}}}}' > .coding-crew/config.json
  git commit -q -am "models"
  run bash "$SCRIPT" feat --budget 7
  [ "$status" -eq 0 ]
  [ "$(agent_flag claude 1 --model)" = haiku ]
  [ "$(agent_flag claude 1 --max-budget-usd)" = 7 ]
}

@test "--agent copilot, or SOLVE_FEATURE_AGENT=copilot with the flag winning, makes the coder copilot and requires copilot on PATH" {
  run bash "$SCRIPT" feat --agent copilot
  [ "$status" -eq 0 ]
  [ "$(agent_calls claude)" -eq 0 ]
  [ "$(coder_issues copilot)" = "2 3" ]
  [ "$(agent_call copilot 1 | paste -sd' ' -)" = "-p Use the solve-issue skill on 2. --allow-all-tools --no-color --output-format json" ]
  grep -qx -- '9 --agent copilot' "$STATE/review.log" || grep -qx -- '10 --agent copilot' "$STATE/review.log"

  jq 'map(.labels = (if .root then [] else [{"name":"ready-for-agent"}] end))' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  echo '{"tracker":{"kind":"github"},"afk":{"models":{"copilot":{"coder":"gpt-5"}}}}' > .coding-crew/config.json
  git commit -q -am "models"
  SOLVE_FEATURE_AGENT=copilot run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(agent_calls copilot)" -eq 4 ]
  [ "$(agent_flag copilot 3 --model)" = gpt-5 ]

  SOLVE_FEATURE_AGENT=copilot run bash "$SCRIPT" feat --agent claude
  [ "$status" -eq 0 ]
  [ "$(agent_calls copilot)" -eq 4 ]

  rm "$STUB/copilot"
  run bash "$SCRIPT" feat --agent copilot
  [ "$status" -eq 1 ]
  [[ "$output" == *"copilot not found"* ]]
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
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(coder_issues)" = "3 7" ]
}

@test "a one-slice feature's root is its work issue: it runs, and the PR is titled after the PRD" {
  issues '[{"number":1,"title":"Feat alone","state":"OPEN","labels":[{"name":"ready-for-agent"}],"root":true}]'
  issue_body 1 "Feat alone" "None"
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(coder_issues)" = "1" ]
  [ "$(cat "$STATE/pr-title")" = Feat ]
  grep -qx '#1  solve ✓  checks ✓' <<<"$(progress_body)"
}

@test "a local tracker: path refs reach the coder and the logs, no Closes line, the title is the first landed issue's" {
  export TRACKER_KIND=local
  issues '[{"number":1,"ref":".scratch/feat/issues/open/01-a.md","title":"A","state":"OPEN","labels":[{"name":"ready-for-agent"}]},
           {"number":2,"ref":".scratch/feat/issues/open/02-b.md","title":"B","state":"OPEN","labels":[{"name":"ready-for-agent"}]}]'
  issue_body .scratch/feat/issues/open/01-a.md "Local A" None
  issue_body .scratch/feat/issues/open/02-b.md "Local B" None
  printf '# PRD\n\nlocal prd without a title note\n' > "$STATE/prd.md"
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(coder_issues)" = ".scratch/feat/issues/open/01-a.md .scratch/feat/issues/open/02-b.md" ]
  [ -f "$WORK/.solve-feature/.scratch_feat_issues_open_01-a.md.log" ]
  [ -f "$WORK/.solve-feature/.scratch_feat_issues_open_01-a.md.checks.log" ]
  [ "$(cat "$STATE/pr-title")" = "Local A" ]
  ! grep -q '^Closes' "$STATE/pr-body"
  ! grep -q 'closing-refs' "$STATE/node.log"
  grep -q '^### .scratch/feat/issues/open/02-b.md — Local B$' "$STATE/pr-body"
}

@test "a github feature whose prd exits 3 titles the PR after the first landed issue; an unusable ref stops before the coder" {
  rm "$STATE/prd.md"
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(cat "$STATE/pr-title")" = Two ]
  ! grep -q 'PRD' "$STATE/pr-body"

  rm -f "$STATE"/claude.*
  NEXT_PRINTS='2; rm -rf /' run bash "$SCRIPT" feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"ref"* ]]
  [ "$(agent_calls claude)" -eq 0 ]
}

# --- prepare -------------------------------------------------------------------------

@test "before the first coder resolve-mode.sh runs, then host-install.sh or docker-install.sh --service; exit 3 warns and the coders still run, exit 2 says nothing" {
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$STATE/prepare.log")" = "resolve-mode.sh --project-root $WORK --main-root $WORK" ]
  [ "$(sed -n 2p "$STATE/prepare.log")" = "host-install.sh --project-root $WORK --main-root $WORK" ]
  [ "$(wc -l < "$STATE/prepare.log")" -eq 2 ]
  [[ "$output" != *"warning"* ]]
  grep -q 'install output' "$WORK/.solve-feature/prepare.log"

  jq 'map(.labels = (if .root then [] else [{"name":"ready-for-agent"}] end))' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  rm -f "$STATE/prepare.log" "$STATE"/claude.*
  STUB_INSTALL_MODE=docker STUB_DOCKER_SERVICE=web INSTALL_RC=3 run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(sed -n 2p "$STATE/prepare.log")" = "docker-install.sh --project-root $WORK --main-root $WORK --service web" ]
  [[ "$output" == *"warning: prepare failed (exit 3)"*"prepare.log"* ]]
  [ "$(coder_issues)" = "2 3" ]

  jq 'map(.labels = (if .root then [] else [{"name":"ready-for-agent"}] end))' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  INSTALL_RC=2 run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [[ "$output" != *"warning"* ]]
}

# --- stops ---------------------------------------------------------------------------

# fails_with <log> <env…> — the run stops non-zero after issue #2's coder, naming <log> on stdout.
fails_with() {
  local log="$1"; shift
  # Each scenario starts as setup left it: #2 ready, no coder calls, a clean tree.
  [ -f "$STATE/issues.orig" ] || cp "$STATE/issues.json" "$STATE/issues.orig"
  cp "$STATE/issues.orig" "$STATE/issues.json"
  rm -f "$STATE"/claude.* "$STATE"/review.log
  git checkout -q -f "$(git show-ref --verify -q refs/heads/feature/feat && echo feature/feat || echo main)"
  git clean -qfd
  run env "$@" bash "$SCRIPT" feat
  [ "$status" -eq 1 ] || { echo "$*: exit $status"; return 1; }
  [[ "$output" == *"$WORK/.solve-feature/$log"* ]] || { echo "$*: $output"; return 1; }
  [ "$(coder_issues)" = 2 ] || { echo "$*: coder ran on $(coder_issues)"; return 1; }
  [ -f "$WORK/.solve-feature/$log" ] || { echo "$*: no $log"; return 1; }
  [ ! -f "$STATE/review.log" ] || { echo "$*: review-pr ran"; return 1; }
}

@test "a coder non-zero exit, a branch change or a dirty tree after the coder stops with the coder log's path" {
  fails_with 2.log CODER_EXIT=3
  fails_with 2.log CODER_SWITCH=1
  fails_with 2.log CODER_DIRTY=1
}

@test "a coder that exits 0 but leaves its issue first in next stops at solve, before the checks" {
  fails_with 2.log CODER_NO_CLOSE=1
  [[ "$output" == *"#2 solve failed: coder ran but did not close #2"* ]]
  [ ! -f "$STATE/checks.log" ]
  [ ! -f "$STATE/pr-created" ]
}

@test "run-checks.sh exit 1 or 3 stops with the checks log's path; 3 says to discover the checks by hand" {
  fails_with 2.checks.log CHECKS_RC=1
  [ "$(agent_calls claude)" -eq 1 ]
  [ ! -f "$STATE/pr-created" ]
  fails_with 2.checks.log CHECKS_RC=3
  [[ "$output" == *"DISCOVER"*"run /solve-issue or dep-install once by hand"* ]]
}

@test "a re-run with the failed issue closed proceeds to the next issue on the same branch" {
  CHECKS_RC=1 run bash "$SCRIPT" feat
  [ "$status" -eq 1 ]
  local tip; tip=$(git rev-parse HEAD)
  jq 'map(if .number == 2 then .state = "CLOSED" else . end)' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  rm -f "$STATE"/claude.*
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(coder_issues)" = 3 ]
  git merge-base --is-ancestor "$tip" HEAD
  [ "$(git branch --show-current)" = feature/feat ]
}

# --- push and PR ---------------------------------------------------------------------

@test "after #2 lands the branch is pushed and a draft PR is created with the spec block; #3 appends to it by pr edit" {
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(git rev-parse origin/feature/feat)" = "$(git rev-parse feature/feat)" ]
  [ -f "$STATE/pr-create.1" ] && [ ! -f "$STATE/pr-create.2" ]
  grep -qx -- --draft "$STATE/pr-create.1"
  [ "$(cat "$STATE/pr-title")" = Feat ]
  # Created before #3's coder ran: the body #3's coder saw holds #2 only.
  [ -f "$STATE/pr-body.before-claude.2" ]
  grep -q '^### 2 — Two$' "$STATE/pr-body.before-claude.2"
  ! grep -q '^### 3' "$STATE/pr-body.before-claude.2"
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
  [ -f "$STATE/pr-edit.1" ] && [ ! -f "$STATE/pr-edit.2" ]
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
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
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
  [[ "${lines[${#lines[@]}-1]}" = "https://github.com/o/r/pull/9" ]]
}

@test "a spec over GitHub's body limit is cut inside <details> with a note, markers and Closes lines intact" {
  { echo '<!-- PRD issue #1: PRD: Feat -->'; head -c 70000 /dev/zero | tr '\0' x; echo; } > "$STATE/prd.md"
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ -f "$STATE/pr-create.1" ]
  local body; body=$(cat "$STATE/pr-body")
  [ "${#body}" -le 65536 ]
  [ "${#body}" -gt 65000 ]
  [ "$(head -1 <<<"$body")" = '<!-- solve-feature:begin -->' ]
  [ "$(tail -1 <<<"$body")" = '<!-- solve-feature:end -->' ]
  grep -qx '<!-- solve-feature:slug feat -->' <<<"$body"
  grep -qx 'Closes #2' <<<"$body"
  grep -qx 'Closes #3' <<<"$body"
  [ "$(grep -B1 -x '</details>' <<<"$body" | head -1)" = "(spec truncated at GitHub's 65,536-character body limit)" ]
}

# --- finish --------------------------------------------------------------------------

@test "with no ready issue left review-pr.sh runs once on the PR with --agent, its REVIEW line is echoed, the URL is last and its exit code is the run's" {
  REVIEW_LINE='prd=unmet findings=2 (1 inline) ready=no' REVIEW_RC=4 run bash "$SCRIPT" feat
  [ "$status" -eq 4 ]
  [ "$(cat "$STATE/review.log")" = "10 --agent claude" ]
  [[ "$output" == *"REVIEW: prd=unmet findings=2 (1 inline) ready=no"* ]]
  [ "${lines[${#lines[@]}-1]}" = "https://github.com/o/r/pull/10" ]
  local body; body=$(progress_body)
  grep -q 'REVIEW: prd=unmet' <<<"$body"
  grep -q 'pull/10' <<<"$body"
}

@test "a re-run with nothing to land reviews the branch's open PR it did not create; with no open PR it exits 0 without a review or URL" {
  jq 'map(.state = "CLOSED")' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  PR_EXISTS=1 run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ "$(agent_calls claude)" -eq 0 ]
  [ "$(cat "$STATE/review.log")" = "9 --agent claude" ]
  [ "${lines[${#lines[@]}-1]}" = "https://github.com/o/r/pull/9" ]

  rm -f "$STATE/review.log"
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [ ! -f "$STATE/review.log" ]
  [[ "${lines[${#lines[@]}-1]}" != *"pull/"* ]]
  [[ "$output" == *"no open PR"* ]]
}

# --- progress comment ----------------------------------------------------------------

@test "one progress comment on the PR, created once then edited in place, rows on stdout before it exists" {
  run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  local body; body=$(progress_body)
  grep -qE '^solve-feature — feat — host test-host — [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' <<<"$body"
  grep -qx '#2  solve ✓  checks ✓' <<<"$body"
  grep -qx '#3  solve ✓  checks ✓' <<<"$body"
  ! grep -q verify <<<"$body"
  [ "$(grep -c '^api repos/{owner}/{repo}/issues/10/comments -f body=' "$STATE/gh.log")" -eq 1 ]
  [ "$(grep -c '^api -X PATCH repos/{owner}/{repo}/issues/comments/100 -f body=' "$STATE/gh.log")" -ge 3 ]
  ! grep -q 'issues/1/comments' "$STATE/gh.log"
  # Before the PR existed, #2's rows went to stdout and no comment call was made before `pr create`.
  grep -qx '#2  solve · checks ·' <<<"$output" || grep -qx '#2  solve ·  checks ·' <<<"$output"
  [ "$(grep -n -m1 'comments' "$STATE/gh.log" | cut -d: -f1)" -gt "$(grep -n -m1 '^pr create' "$STATE/gh.log" | cut -d: -f1)" ]

  # A re-run finds the comment by its marker and edits it: still one, never a second create.
  jq 'map(.labels = (if .root then [] else [{"name":"ready-for-agent"}] end))' "$STATE/issues.json" > "$STATE/i.tmp" && mv "$STATE/i.tmp" "$STATE/issues.json"
  run bash "$SCRIPT" feat
  progress_body >/dev/null
  [ "$(grep -c '^api repos/{owner}/{repo}/issues/10/comments -f body=' "$STATE/gh.log")" -eq 1 ]
}

@test "a stop puts the failing step and the last 20 lines of its log in the comment" {
  export PR_EXISTS=1
  CODER_EXIT=1 run bash "$SCRIPT" feat
  [ "$status" -eq 1 ]
  [ ! -f "$STATE/review.log" ]
  local body; body=$(progress_body)
  grep -qx '#2  solve ✗  checks ·' <<<"$body"
  grep -q 'solve' <<<"$(grep -i 'stopped' <<<"$body")"
  grep -qx 'coder line 30' <<<"$body"
  grep -qx 'coder line 11' <<<"$body"
  ! grep -qx 'coder line 10' <<<"$body"
  grep -qx '```' <<<"$body"
}

@test "a stop on a claude or copilot JSON log puts its result text, not the raw JSON, in the comment" {
  export PR_EXISTS=1
  CODER_NO_CLOSE=1 run bash "$SCRIPT" feat
  [ "$status" -eq 1 ]
  local body; body=$(progress_body)
  grep -qx '#2  solve ✗  checks ·' <<<"$body"
  grep -qx 'BLOCKED: Bash denied' <<<"$body"
  grep -qx 'nothing was started' <<<"$body"
  ! grep -q '"type":"result"' <<<"$body"

  echo '[]' > "$STATE/comments.json"
  CODER_NO_CLOSE=1 run bash "$SCRIPT" feat --agent copilot
  [ "$status" -eq 1 ]
  body=$(progress_body)
  grep -qx 'BLOCKED: Bash denied' <<<"$body"
  ! grep -q 'assistant.message' <<<"$body"
}

@test "a failing gh api call on the comment warns and leaves the exit code alone" {
  GH_API_FAIL=1 run bash "$SCRIPT" feat
  [ "$status" -eq 0 ]
  [[ "$output" == *"warning"* ]]
  [ "$(coder_issues)" = "2 3" ]
  jq 'map(.labels = (if .root then [] else [{"name":"ready-for-agent"}] end))' "$STATE/issues.json" > "$STATE/i.tmp"
  mv "$STATE/i.tmp" "$STATE/issues.json"
  GH_API_FAIL=1 CHECKS_RC=1 run bash "$SCRIPT" feat
  [ "$status" -eq 1 ]
  [[ "$output" == *"#2 checks failed"* ]]
}

@test ".solve-feature/ is gitignored here" {
  git -C "$REPO_ROOT" check-ignore -q .solve-feature/x.log
}

# --- packaging -----------------------------------------------------------------------

@test "install.sh claude --skill solve-feature ships the script and review-pr's scripts, no verify prompt and no roles tree" {
  local target="$TEMP_DIR/target"
  mkdir -p "$target" && git -C "$target" init -q -b main
  TARGET_REPO="$target" run bash "$REPO_ROOT/install.sh" claude --skill solve-feature
  [ "$status" -eq 0 ]
  [ -x "$target/.coding-crew/solve-feature/scripts/solve-feature.sh" ]
  [ -x "$target/.coding-crew/review-pr/scripts/review-pr.sh" ]
  [ -f "$target/.coding-crew/review-pr/scripts/agent.sh" ]
  [ ! -e "$target/.coding-crew/solve-feature/scripts/verify-prompt.md" ]
  [ ! -e "$target/.coding-crew/solve-feature/roles" ]
  for f in github-actions.yml Dockerfile; do
    [ -f "$target/.coding-crew/solve-feature/hosts/$f" ]
    [ ! -x "$target/.coding-crew/solve-feature/hosts/$f" ]
    [ -f "$target/.claude/skills/solve-feature/hosts/$f" ]
  done
  [ -f "$target/.claude/skills/solve-feature/SKILL.md" ]
  [ -f "$target/.coding-crew/solve-issue/scripts/run-checks.sh" ]
  [ -f "$target/.coding-crew/dep-install/scripts/run.sh" ]
  [ "$(jq -c '.skills["solve-feature"].deps' "$REPO_ROOT/registry.json")" = '["solve-issue","dep-install","review-pr"]' ]
}

# --- hosts ---------------------------------------------------------------------------

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

@test "hosts/github-actions.yml parses: labeled-issue and workflow_dispatch triggers, a solve-feature label gate, four write permissions, a slug concurrency group, a solve-feature.sh --agent copilot step" {
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
  jq -r '.jobs[].steps[].run // empty' "$json" | grep -Eq 'solve-feature/scripts/solve-feature\.sh"? "\$SLUG" --agent copilot'
}

