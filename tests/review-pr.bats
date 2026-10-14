#!/usr/bin/env bats

# review-pr.sh prepare|post — the guards around review-pr's reviewer, a read-only host subagent that
# SKILL.md runs between them: prepare saves the spec, the diff and the prompt; post checks the tree is
# unchanged, posts one COMMENT review and flips a draft to ready when the spec is met with no
# CRITICAL/HIGH finding.
#
# A temp repo whose HEAD is the stubbed PR's head; `gh` is a stub on PATH logging its argv into $STATE.
# `review <json>` stands in for the subagent: prepare, the report written where the prompt says, post.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
SCRIPTS="$REPO_ROOT/skills/review-pr/scripts"
SCRIPT="$SCRIPTS/review-pr.sh"

setup() {
  TEMP_DIR=$(cd "$(mktemp -d)" && pwd -P)
  export STATE="$TEMP_DIR/state" HOME="$TEMP_DIR/home"
  mkdir -p "$STATE" "$HOME"
  unset GH_POST_FAIL

  WORK="$TEMP_DIR/work"
  git init -q -b main "$WORK"
  git -C "$WORK" config user.email t@example.com
  git -C "$WORK" config user.name test
  mkdir -p "$WORK/.coding-crew"
  echo '{"tracker":{"kind":"github"}}' > "$WORK/.coding-crew/config.json"
  printf 'a\nb\nc\n' > "$WORK/lib.sh"
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m init
  git -C "$WORK" checkout -q -b feature/x
  HEAD_OID=$(git -C "$WORK" rev-parse HEAD)

  STUB="$TEMP_DIR/stub"
  mkdir -p "$STUB"
  write_stubs
  export PATH="$STUB:$PATH"

  pr_view "$HEAD_OID" true "<!-- solve-feature:begin -->\nintro\n<details><summary>Spec</summary>\n\n# Spec body\n\n</details>\nafter"
  printf 'diff --git a/lib.sh b/lib.sh\n--- a/lib.sh\n+++ b/lib.sh\n@@ -1,3 +1,4 @@\n a\n+new\n b\n c\n' > "$STATE/pr.diff"
  echo '[]' > "$STATE/reviews.json"
  echo '[]' > "$STATE/comments.json"
  cd "$WORK"
}

teardown() {
  cd /
  rm -rf "$TEMP_DIR"
}

# pr_view <headRefOid> <isDraft> <body with \n escapes>
pr_view() {
  jq -n --arg oid "$1" --argjson draft "$2" --arg body "$(printf "$3")" \
    '{body: $body, headRefOid: $oid, isDraft: $draft, url: "https://github.com/o/r/pull/9"}' > "$STATE/pr.json"
}

write_stubs() {
  cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STATE/gh.log"
case "$1 $2" in
  "pr view") cat "$STATE/pr.json" ;;
  "pr diff") cat "$STATE/pr.diff" ;;
  "pr ready") ;;
  "api repos/{owner}/{repo}/pulls/9/reviews")
    if [[ "$*" == *"--method POST"* ]]; then
      [ -z "${GH_POST_FAIL:-}" ] || { echo "gh: HTTP 422 Unprocessable" >&2; exit 1; }
      for ((i = 1; i <= $#; i++)); do [ "${!i}" = --input ] && { j=$((i + 1)); cp "${!j}" "$STATE/payload.json"; }; done
      echo '{"id": 1}'
    else cat "$STATE/reviews.json"; fi ;;
  "api repos/{owner}/{repo}/pulls/9/comments") cat "$STATE/comments.json" ;;
  *) echo "gh stub: unexpected: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$STUB"/*
}

marker_of() { printf 'crew-finding:%s' "$(printf '%s' "$1" | { command -v sha1sum >/dev/null 2>&1 && sha1sum || shasum -a 1; } | cut -c1-12)"; }

# review [<report json>] — prepare, then the reviewer's report (none when empty) where the prompt names it, then post.
review() {
  run bash "$SCRIPT" prepare 9
  [ "$status" -eq 0 ] || { echo "prepare: $output"; return 1; }
  local report; report=$(sed -n 's/^Write your report to \(.*\) as your last action.*/\1/p' "$(sed -n 's/^prompt=//p' <<<"$output")")
  [ -z "${1:-}" ] || printf '%s\n' "$1" > "$report"
  run bash "$SCRIPT" post 9
}

# --- prepare -------------------------------------------------------------------------------

@test "prepare writes the spec, the diff, the reviewed head and the prompt naming them, the questions and the report; prints prompt= and reviewer-model=" {
  run bash "$SCRIPT" prepare 9
  [ "$status" -eq 0 ]
  [ "$(cat .solve-feature/pr-9.reviewed-head)" = "$HEAD_OID" ]
  [ "$output" = "$(printf 'prompt=%s\nreviewer-model=' "$WORK/.solve-feature/pr-9.prompt.md")" ]
  prompt=$(cat .solve-feature/pr-9.prompt.md)
  [ "$(head -1 <<<"$prompt")" = "Review PR #9 (https://github.com/o/r/pull/9), checked out at HEAD, against its spec." ]
  grep -qxF "Spec: $WORK/.solve-feature/pr-9.spec.md" <<<"$prompt"
  grep -qxF "Diff: $WORK/.solve-feature/pr-9.diff" <<<"$prompt"
  grep -qF "deliver what the spec asks" <<<"$prompt"
  grep -qF "bug free" <<<"$prompt"
  grep -qF "Never edit, write, commit or change the tree." <<<"$prompt"
  grep -qF "Defects that only appear across issues exist" <<<"$prompt"
  grep -qF "Commit messages, PR text and progress notes are claims, not evidence." <<<"$prompt"
  grep -qF "Write your report to $WORK/.solve-feature/pr-9.review.json as your last action, as JSON: {\"prd\": \"met|unmet\"" <<<"$prompt"
  [ "$(cat .solve-feature/pr-9.spec.md)" = "$(printf '<details><summary>Spec</summary>\n\n# Spec body\n\n</details>')" ]
  [ "$(cat .solve-feature/pr-9.diff)" = "$(cat "$STATE/pr.diff")" ]
  [ "$(cat .solve-feature/.gitignore)" = '*' ]
  [ -z "$(git status --porcelain)" ]
  ! grep -q 'POST' "$STATE/gh.log"
}

@test "a body without a Spec block is the spec whole" {
  pr_view "$HEAD_OID" true "just a description\nline two"
  run bash "$SCRIPT" prepare 9
  [ "$status" -eq 0 ]
  [ "$(cat .solve-feature/pr-9.spec.md)" = "$(printf 'just a description\nline two')" ]
}

@test "prepare's reviewer-model= is solveFeature.models.reviewer, never afk.models" {
  echo '{"afk":{"models":{"claude":{"reviewer":"haiku"}}}}' > .coding-crew/config.json
  git commit -qam models; pr_view "$(git rev-parse HEAD)" true "spec"
  run bash "$SCRIPT" prepare 9
  [ "${lines[1]}" = "reviewer-model=" ]
  echo '{"solveFeature":{"models":{"reviewer":"opus"}}}' > .coding-crew/config.json
  git commit -qam models; pr_view "$(git rev-parse HEAD)" true "spec"
  run bash "$SCRIPT" prepare 9
  [ "${lines[1]}" = "reviewer-model=opus" ]
}

@test "post writes .solve-feature/reviewed; prepare removes it and a stale report, so post never posts an earlier run's" {
  review '{"prd":"met","gaps":[],"findings":[]}'
  [ "$status" -eq 0 ]
  [ "$(cat .solve-feature/reviewed)" = "pr=9 head=$HEAD_OID" ]
  run bash "$SCRIPT" prepare 9
  [ ! -e .solve-feature/reviewed ]
  review ""
  [ "$status" -eq 1 ]
  [[ "$output" == *"no report at $WORK/.solve-feature/pr-9.review.json"* ]]
}

@test "prepare with HEAD not at the PR's head, or a dirty tree: exit 1, the reason in .solve-feature/stopped" {
  pr_view 0123456789abcdef0123456789abcdef01234567 true "spec"
  run bash "$SCRIPT" prepare 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh pr checkout 9"* ]]
  grep -q 'gh pr checkout 9' .solve-feature/stopped
  [ ! -e .solve-feature/pr-9.prompt.md ]
  # Ahead of the PR's head: unpushed commits, not a wrong checkout.
  git commit -q --allow-empty -m "unpushed"
  pr_view "$(git rev-parse HEAD~1)" true "spec"
  run bash "$SCRIPT" prepare 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"HEAD has commits PR #9 lacks: push them first"* ]]
  git reset -q --hard HEAD~1
  pr_view "$HEAD_OID" true "spec"
  echo dirt > dirt.txt
  run bash "$SCRIPT" prepare 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"not clean"* ]]
}

# --- post ----------------------------------------------------------------------------------

@test "post after the reviewer committed or dirtied the tree: exit 1, nothing posted, no gh pr ready, the reason in .solve-feature/stopped" {
  run bash "$SCRIPT" prepare 9
  echo '{"prd":"met","gaps":[],"findings":[]}' > .solve-feature/pr-9.review.json
  echo dirt > reviewer-dirt.txt
  run bash "$SCRIPT" post 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"reviewer changed the tree"* ]]
  grep -q 'reviewer changed the tree' .solve-feature/stopped
  rm reviewer-dirt.txt
  git commit -q --allow-empty -m "reviewer wrote"
  run bash "$SCRIPT" post 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"no longer PR #9's head"* ]]
  ! grep -q 'POST' "$STATE/gh.log"
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "post without prepare exits 1 naming prepare, before any POST" {
  run bash "$SCRIPT" post 9
  [ "$status" -eq 1 ]
  [[ "$output" == *"review-pr.sh prepare 9"* ]]
  ! grep -q 'POST' "$STATE/gh.log"  [ ! -e .solve-feature/reviewed ]
}

@test "findings: inline where path:line is on the diff's right side, the rest in the body by severity, gaps listed, markers hashed, no ready" {
  review '{"prd":"unmet","gaps":["no docs"],"findings":[
    {"severity":"HIGH","location":"lib.sh:2","issue":"breaks","fix":"guard it"},
    {"severity":"low","location":"lib.sh:9","issue":"nit","fix":"rename"}]}'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=unmet findings=2 (1 inline) ready=no" ]
  P="$STATE/payload.json"
  [ "$(jq -r .event "$P")" = COMMENT ]
  [ "$(jq '.comments | length' "$P")" -eq 1 ]
  [ "$(jq -c '.comments[0] | {path, line, side}' "$P")" = '{"path":"lib.sh","line":2,"side":"RIGHT"}' ]
  m1=$(marker_of 'HIGH|lib.sh:2|guard it') m2=$(marker_of 'LOW|lib.sh:9|rename')
  [ "$(jq -r '.comments[0].body' "$P")" = "$(printf '**HIGH** — breaks\n\nFix: guard it\n\n<!-- %s -->' "$m1")" ]
  body=$(jq -r .body "$P")
  [ "$(head -1 <<<"$body")" = "review-pr: prd unmet, 2 finding(s)" ]
  grep -qxF -- '### Gaps' <<<"$body"
  grep -qxF -- '- no docs' <<<"$body"
  grep -qxF -- '### LOW' <<<"$body"
  grep -qxF -- "- \`lib.sh:9\` — nit — Fix: rename <!-- $m2 -->" <<<"$body"
  ! grep -q '### HIGH' <<<"$body"
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "prd met with no CRITICAL/HIGH finding on a draft: review posted and gh pr ready; a non-draft is 'already'" {
  review '{"prd":"met","gaps":[],"findings":[]}'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=met findings=0 (0 inline) ready=yes" ]
  [ "$(jq -r .body "$STATE/payload.json")" = "review-pr: prd met, 0 finding(s)" ]
  [ "$(jq '.comments | length' "$STATE/payload.json")" -eq 0 ]
  grep -qx 'pr ready 9' "$STATE/gh.log"
  pr_view "$HEAD_OID" false "spec"; : > "$STATE/gh.log"
  review '{"prd":"met","gaps":[],"findings":[]}'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=met findings=0 (0 inline) ready=already" ]
  grep -q 'POST' "$STATE/gh.log"
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "a MEDIUM finding still flips ready; CRITICAL or high (any case) does not" {
  review '{"prd":"met","gaps":[],"findings":[{"severity":"MEDIUM","location":"lib.sh:2","issue":"i","fix":"f"}]}'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=met findings=1 (1 inline) ready=yes" ]
  : > "$STATE/gh.log"
  review '{"prd":"met","gaps":[],"findings":[{"severity":"CRITICAL","location":"lib.sh:2","issue":"i","fix":"f"}]}'
  [ "${lines[-1]}" = "REVIEW: prd=met findings=1 (1 inline) ready=no" ]
  review '{"prd":"met","gaps":[],"findings":[{"severity":"high","location":"x","issue":"i","fix":"f"}]}'
  [ "${lines[-1]}" = "REVIEW: prd=met findings=1 (0 inline) ready=no" ]
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "a finding whose marker is already on the PR is skipped; all skipped still posts the one-line body" {
  m1=$(marker_of 'HIGH|lib.sh:2|guard it') m2=$(marker_of 'LOW|lib.sh:9|rename')
  printf '[{"body":"old <!-- %s -->"}]' "$m1" > "$STATE/reviews.json"
  review '{"prd":"unmet","gaps":[],"findings":[
    {"severity":"HIGH","location":"lib.sh:2","issue":"breaks","fix":"guard it"},
    {"severity":"LOW","location":"lib.sh:9","issue":"nit","fix":"rename"}]}'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=unmet findings=1 (0 inline) ready=no" ]
  ! grep -q "$m1" "$STATE/payload.json"
  grep -q "$m2" "$STATE/payload.json"
  printf '[{"body":"x <!-- %s -->"}]' "$m2" > "$STATE/comments.json"
  review '{"prd":"unmet","gaps":[],"findings":[
    {"severity":"HIGH","location":"lib.sh:2","issue":"breaks","fix":"guard it"},
    {"severity":"LOW","location":"lib.sh:9","issue":"nit","fix":"rename"}]}'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "REVIEW: prd=unmet findings=0 (0 inline) ready=no" ]
  [ "$(jq -r .body "$STATE/payload.json")" = "review-pr: prd unmet, 0 finding(s)" ]
}

@test "no report, an unparseable one, or prd not met|unmet: no POST, no ready, exit 1 naming the report" {
  for r in "" '{not json' '{"prd":"maybe"}'; do
    review "$r"
    [ "$status" -eq 1 ] || { echo "'$r': $status"; return 1; }
    [[ "$output" == *"$WORK/.solve-feature/pr-9.review.json"* ]] || { echo "'$r': $output"; return 1; }
  done
  ! grep -q 'POST' "$STATE/gh.log"
  ! grep -q '^pr ready' "$STATE/gh.log"
  grep -q 'is not met|unmet' .solve-feature/stopped
}

@test "findings not an array of objects, or gaps not an array: no POST, no ready, exit 1 naming the report" {
  for r in '{"prd":"met","findings":"none"}' '{"prd":"met","findings":["x"]}' '{"prd":"met","gaps":"none","findings":[]}'; do
    review "$r"
    [ "$status" -eq 1 ] || { echo "'$r': $status $output"; return 1; }
    [[ "$output" == *"$WORK/.solve-feature/pr-9.review.json"* ]] || { echo "'$r': $output"; return 1; }
  done
  ! grep -q 'POST' "$STATE/gh.log"
  ! grep -q '^pr ready' "$STATE/gh.log"
  grep -q 'pr-9.review.json' .solve-feature/stopped
}

@test "an unexpected command failure in post exits 1 with its reason in .solve-feature/stopped" {
  printf '#!/bin/sh\nexit 7\n' > "$STUB/sha1sum" && chmod +x "$STUB/sha1sum"
  review '{"prd":"met","gaps":[],"findings":[{"severity":"LOW","location":"lib.sh:1","issue":"i","fix":"f"}]}'
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  ! grep -q 'POST' "$STATE/gh.log"
  grep -q 'post failed' .solve-feature/stopped
}

@test "a failing /reviews POST exits 1 with gh's stderr and no gh pr ready" {
  export GH_POST_FAIL=1
  review '{"prd":"met","gaps":[],"findings":[]}'
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 422"* ]]
  ! grep -q '^pr ready' "$STATE/gh.log"
}

@test "no subcommand, an unknown one, the old one-argument form or a non-numeric PR is a usage error (exit 2) before gh" {
  local args
  for args in "" "9" "review 9" "prepare abc" "post" "prepare 9 --agent claude"; do
    run bash "$SCRIPT" $args
    [ "$status" -eq 2 ] || { echo "'$args': $status"; return 1; }
    [[ "$output" == *"usage: review-pr.sh prepare|post <pr-number>"* ]]
  done
  [ ! -f "$STATE/gh.log" ]
}
