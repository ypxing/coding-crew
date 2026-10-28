# Shared bats helper for the solve-feature.sh tests (solve-feature*.bats): setup, the stubs and the
# helpers more than one of those files uses.
#
# solve-feature.sh start|next|land|sync|reviewed|fix|describe — the guards of solve-feature's loop, which SKILL.md drives
# with host subagents: start checks the slug, picks the branch and writes the spec, next saves the next ready issue,
# land asserts what the coder left (branch, clean tree, issue closed, checks) and pushes it into a draft PR, sync
# merges the default branch in before the review, reviewed
# discards what the reviewer changed in the tree, fix
# gates, commits and pushes what the review's fixer left, and describe writes the PR body, marks it ready when
# nothing needs a person and writes .coding-crew/solve-feature/outcome.
#
# A temp clone with a bare `origin`, and the skill's scripts/ as install.sh lays it out: its own
# script, with the tracker and checks library copies in the coding-crew-lib skill beside it. `gh`, `node` (only for the tracker CLI's path; everything else reaches the
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
  unset PR_EXISTS PR_DRAFT PR_HEAD_OID PR_STATE PR_HEAD_REF GH_READY_FAIL GH_UNDO_FAIL GH_THREADS_FAIL TRACKER_KIND SOLVE_FEATURE_HOST CREW_CODER_MODEL CREW_REVIEWER_MODEL

  INSTALL="$HOME/skills/solve-feature/scripts" LIB="$HOME/skills/coding-crew-lib/scripts"
  mkdir -p "$HOME/skills/solve-feature"
  cp -RL "$REPO_ROOT/skills/solve-feature/scripts" "$INSTALL"
  mkdir -p "$LIB/tracker" "$LIB/checks"
  cp "$REPO_ROOT/lib/checks/commands-file.sh" "$LIB/checks/"
  : > "$LIB/tracker/cli.mjs"
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
  reopen) [ -z "\${REOPEN_RC:-}" ] || { echo "gh: boom" >&2; exit "\$REOPEN_RC"; }
    [ -z "\${REOPEN_TOUCHES:-}" ] || echo reopened > "\$REOPEN_TOUCHES"
    jq --arg r "\$3" 'map(if (.ref // (.number | tostring)) == \$r then .labels = [{"name":"ready-for-agent"}] else . end)' "\$STATE/issues.json" > "\$STATE/i.tmp"
    mv "\$STATE/i.tmp" "\$STATE/issues.json"; echo "REOPENED: \$3" ;;
  features) printf 'feat\topen\t2\nother\tclosed\t0\n' ;;
  # \`spec\`: prd.md and a blank line, then each issue but a PRD: one, named <number>-<title>.md or by its ref's basename, as a ### section; SPEC_RC fails it.
  spec) [ -z "\${SPEC_RC:-}" ] || { echo "spec: boom" >&2; exit "\$SPEC_RC"; }
    [ ! -f "\$STATE/prd.md" ] || { cat "\$STATE/prd.md"; echo; }
    jq -r '.[] | select(.title | test("^PRD:") | not) | "\\(.ref // (.number | tostring))\\t\\(.ref // "\\(.number)-\\(.title | ascii_downcase).md")"' "\$STATE/issues.json" |
      while IFS=\$'\\t' read -r r n; do n=\${n##*/}; f="\$STATE/\${r//\\//_}.md"
        printf '### %s — %s\\n' "\${n%.md}" "\$(sed -n '1s/^# //p' "\$f")"; sed 1d "\$f"; done ;;
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
  # GH_CREATE_FAIL refuses it, printing its value as gh's last stderr line (none when it is "silent"); GH_CREATE_HOOK
  # names a pre-receive hook it installs first, so the pushes after it are refused.
  "pr create") k=$(( $(ls "$STATE" | grep -c '^pr-create\.[0-9]*$') + 1 )); printf '%s\n' "$@" > "$STATE/pr-create.$k"
    if [ -n "${GH_CREATE_FAIL:-}" ]; then
      [ -z "${GH_CREATE_HOOK:-}" ] || { printf '#!/bin/sh\nexit 1\n' > "$GH_CREATE_HOOK"; chmod +x "$GH_CREATE_HOOK"; }
      [ "$GH_CREATE_FAIL" = silent ] || printf 'pull request create failed\n%s\n\n' "$GH_CREATE_FAIL" >&2
      exit 1
    fi
    cp "$file" "$STATE/pr-body"; touch "$STATE/pr-created"; echo "https://github.com/o/r/pull/10" ;;
  "pr edit") k=$(( $(ls "$STATE" | grep -c '^pr-edit\.[0-9]*$') + 1 )); printf '%s\n' "$@" > "$STATE/pr-edit.$k"; cp "$file" "$STATE/pr-body" ;;
  # Each comment's arguments in $STATE/pr-comment.<k> and its body in pr-comment.<k>.body; GH_COMMENT_FAIL refuses it.
  "pr comment") k=$(( $(ls "$STATE" | grep -c '^pr-comment\.[0-9]*$') + 1 )); printf '%s\n' "$@" > "$STATE/pr-comment.$k"
    [ -z "${GH_COMMENT_FAIL:-}" ] || exit 1; cp "$file" "$STATE/pr-comment.$k.body"; echo "https://github.com/o/r/pull/$3#issuecomment-1" ;;
  "pr ready") if [ "${4:-}" = --undo ]; then [ -z "${GH_UNDO_FAIL:-}" ] || exit 1; else [ -z "${GH_READY_FAIL:-}" ] || exit 1; fi ;;
  # The review threads, one JSON document per page as `--paginate` prints them: $STATE/threads.<k>, else one empty
  # page. Without --paginate only the first page.
  "api graphql")
    [ -z "${GH_THREADS_FAIL:-}" ] || { echo "gh: GraphQL: boom" >&2; exit 1; }
    pages=$(ls "$STATE" | grep '^threads\.[0-9]*$' | sort -t. -k2 -n || true)
    [ -n "$pages" ] || { echo '{"data":{"repository":{"pullRequest":{"url":"https://github.com/o/r/pull/10","reviewThreads":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'; exit 0; }
    [[ " $* " == *" --paginate "* ]] || pages=$(head -n1 <<<"$pages")
    for f in $pages; do cat "$STATE/$f"; done ;;
  *) exit 1 ;;
esac
EOF

  cat > "$LIB/checks/run-checks.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATE/checks.log"
git status --porcelain > "$STATE/checks.status"
git rev-parse HEAD > "$STATE/checks.head"
[ -z "${CHECK_LEAVES:-}" ] || echo build > "$CHECK_LEAVES"
for i in $(seq 1 30); do echo "check line $i"; done
echo "test: ${CHECK_RESULT:-pass}"
[ "${CHECKS_RC:-0}" != 3 ] || { echo DISCOVER; exit 3; }
[ "${CHECKS_RC:-0}" = 0 ] && echo "CHECKS: pass" || echo "CHECKS: fail"
exit "${CHECKS_RC:-0}"
EOF
  chmod +x "$STUB"/* "$LIB"/checks/*.sh
}

# coder <ref> — what the subagent's solve-issue leaves: a commit, and the issue out of `next`.
coder() {
  echo "$1" >> "work-${1//\//_}.txt"
  git add "work-${1//\//_}.txt" && git commit -q -m "[$1] work"
  jq --arg r "$1" 'map(if (.ref // (.number | tostring)) == $r then .labels = [{"name":"awaiting-merge"}] else . end)' "$STATE/issues.json" > "$STATE/i.tmp"
  mv "$STATE/i.tmp" "$STATE/issues.json"
}
# out <key> — the value of start's or land's `<key>=` line in $output.
out() { sed -n "s/^$1=//p" <<<"$output" | tail -1; }
# loop — SKILL.md's loop: start, then next → coder → land until next exits 3, then sync when a PR was opened. CODED
# collects the refs, LAST_PR is the last `pr=` printed.
loop() {
  run bash "$SCRIPT" start feat "$@"
  [ "$status" -eq 0 ] || { echo "start: $output"; return 1; }
  local branch ref; branch=$(out branch); CODED="" LAST_PR=$(out pr)
  while :; do
    run bash "$SCRIPT" next feat
    if [ "$status" -eq 3 ]; then
      [ -n "$LAST_PR" ] || return 0
      run bash "$SCRIPT" sync feat "$branch"
      [ "$status" -eq 0 ] || { echo "sync: $output"; return 1; }
      return 0
    fi
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

# refuse_pushes — origin's pre-receive hook declines every push, so git prints ` ! [remote rejected] … (pre-receive hook declined)`.
refuse_pushes() { printf '#!/bin/sh\nexit 1\n' > "$TEMP_DIR/origin.git/hooks/pre-receive" && chmod +x "$TEMP_DIR/origin.git/hooks/pre-receive"; }

# branch_moves <file> <text> — another clone (a bot, a teammate) pushes a commit to origin's feature/feat; prints it.
branch_moves() {
  local other="$TEMP_DIR/other"
  [ -d "$other" ] || { git clone -q "$TEMP_DIR/origin.git" "$other" && git -C "$other" config user.email b@example.com && git -C "$other" config user.name bot; }
  git -C "$other" fetch -q origin && git -C "$other" checkout -q -B feature/feat origin/feature/feat
  echo "$2" > "$other/$1" && git -C "$other" add "$1" && git -C "$other" commit -q -m "bot: $1" && git -C "$other" push -q origin feature/feat
  git -C "$other" rev-parse HEAD
}

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
report() { printf '%s\n' "$1" > .coding-crew/solve-feature/pr-10.review.json; }
pushed() { [ "$(git ls-remote origin feature/feat | cut -f1)" = "$(git rev-parse HEAD)" ]; }

# attention — what fix handed describe.
attention() { cat .coding-crew/solve-feature/pr-10.attention.md; }

# fixed [<report json>] — fix_ready, then fix: describe's input as SKILL.md leaves it.
fixed() {
  fix_ready "$@"
  run bash "$SCRIPT" fix feat 10 feature/feat
  [ "$status" -eq 0 ] || { echo "fix: $output"; return 1; }
}

# threads <resolved…> … — the PR's review threads, one argument per page, each a space-separated list of
# true/false isResolved values: `threads "false true" "false"` is two pages holding two unresolved threads.
threads() {
  local k=0 page
  for page in "$@"; do
    k=$((k + 1))
    jq -n --arg r "$page" --argjson more "$([ "$k" -lt $# ] && echo true || echo false)" --arg c "c$k" \
      '{data: {repository: {pullRequest: {url: "https://github.com/o/r/pull/10",
        reviewThreads: {nodes: [$r | split(" ")[] | select(. != "") | {isResolved: (. == "true")}],
          pageInfo: {hasNextPage: $more, endCursor: $c}}}}}}' >"$STATE/threads.$k"
  done
}
