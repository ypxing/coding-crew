#!/usr/bin/env bash
# solve-feature.sh start|next|land|fix|describe — the guards of solve-feature's loop. SKILL.md drives the loop and
# runs each issue's coder (between `next` and `land`), the review's reviewer and fixer (before `fix`) and the PR's
# writer (before `describe`) as subagents of the host agent; every guard is an exit code here.
#   start <slug> [--branch <name>]  preconditions, the branch, the PRD; prints branch=, coder-model=,
#                                   reviewer-model= (.coding-crew/config.json solveFeature.models) and pr=
#   next <slug>                     the next ready issue, saved for land; prints its ref
#   land <slug> <ref> <branch>      the coder left <branch> clean with <ref> closed and the checks pass: push,
#                                   open the draft PR or rewrite its block, add a progress row; prints pr=<n>
#   fix <slug> <pr> <branch>        the review report is there and the checks pass on the fixer's tree: commit it,
#                                   push, add a review row naming what needs a person (else mark the draft ready),
#                                   write .solve-feature/reviewed; last stdout line
#                                   `FIX: findings=<k> needs-attention=<a> ready=<yes|no|already>`
#   describe <slug> <pr>            the writer's pr-<pr>.summary.md and fix's Needs attention at the top of the PR
#                                   body's block, its title the PR's; without a summary the PR is left as it is
# Env: SOLVE_FEATURE_HOST (the progress comment's host name).
# Exit: 0 ok; 1 a stop or a precondition miss, its reason also in .solve-feature/stopped (an Actions job's
# last step fails on it, and on any run that did not end in fix); 2 a usage error; 3 from next
# when no ready issue is left.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS=""
mark_stopped() { [ -n "$LOGS" ] || return 0; { mkdir -p "$LOGS" && echo '*' >"$LOGS/.gitignore" && printf '%s\n' "$*" >"$LOGS/stopped"; } 2>/dev/null || true; }
die() { echo "solve-feature: $*" >&2; mark_stopped "$*"; exit 1; }
# Any other failure (set -e: a rejected push, a failed gh call) also exits 1 with a reason, so an Actions job sees it.
trap 'rc=$?; case $rc in 0|2|3) ;; *) [ -f "$LOGS/stopped" ] || mark_stopped "solve-feature.sh $CMD failed (exit $rc)"; exit 1 ;; esac' EXIT
usage() {
  [ -z "${1:-}" ] || echo "solve-feature: $1" >&2
  echo "usage: solve-feature.sh start <slug> [--branch <name>] | next <slug> | land <slug> <ref> <branch> | fix <slug> <pr> <branch> | describe <slug> <pr>" >&2; exit 2
}

CMD="${1:-}"; [ $# -eq 0 ] || shift
SLUG="" BRANCH="" REF="" PR=""
case "$CMD" in
  start) while [ $# -gt 0 ]; do case "$1" in
      --branch) [ $# -ge 2 ] || usage "--branch needs a value"; BRANCH="$2"; shift 2 ;;
      -*) usage "unknown flag: $1" ;;
      *) [ -z "$SLUG" ] || usage "unexpected argument: $1"; SLUG="$1"; shift ;;
    esac; done ;;
  next) [ $# -eq 1 ] || usage; SLUG="$1" ;;
  land) [ $# -eq 3 ] || usage; SLUG="$1" REF="$2" BRANCH="$3" ;;
  fix) [ $# -eq 3 ] && [[ "$2" =~ ^[0-9]+$ ]] || usage; SLUG="$1" PR="$2" BRANCH="$3" REF=review ;;
  describe) [ $# -eq 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || usage; SLUG="$1" PR="$2" ;;
  *) usage ;;
esac
for t in gh jq node git; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
# The tracker's own SLUG rule: the slug reaches argv, so nothing else gets through.
[[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid feature slug: '$SLUG'"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"; cd "$ROOT"
LOGS="$ROOT/.solve-feature"
[ "$CMD" != start ] || rm -f "$LOGS/stopped" "$LOGS/reviewed" "$LOGS"/pr-*.unfixed.md "$LOGS"/pr-*.review.json "$LOGS"/pr-*.summary.md "$LOGS"/pr-*.attention.md
COMMON="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" CLI=""
for c in "$ROOT" "$COMMON" "$HOME"; do [ -f "$c/.coding-crew/tracker/cli.mjs" ] && { CLI="$c/.coding-crew/tracker/cli.mjs"; break; }; done
[ -n "$CLI" ] || die "tracker CLI not found (.coding-crew/tracker/cli.mjs): run install.sh"
mkdir -p "$LOGS" && echo '*' >"$LOGS/.gitignore" # ignored in any repo, so the tree stays clean

PR_N="" URL="" VIEW="" PRD_TEXT="" SUMMARY=""
pr_view() { # sets PR_N and URL (and VIEW) when the branch has an OPEN PR, else clears them
  VIEW=$(gh pr view "$BRANCH" --json number,state,url,isDraft,body 2>/dev/null) || VIEW=""
  if [ "$(jq -r '.state // empty' <<<"$VIEW" 2>/dev/null || true)" = OPEN ]; then
    PR_N=$(jq -r '.number' <<<"$VIEW") URL=$(jq -r '.url' <<<"$VIEW")
  else PR_N="" URL=""; fi
}

start() {
  [ -z "$(git status --porcelain)" ] || die "working tree is not clean: commit or stash first"
  # DISCOVER needs an agent and a human once; run-checks.sh's own exit 3 guards a file that names no usable command.
  [ -f "$ROOT/.coding-crew/dev-commands.json" ] || die "no .coding-crew/dev-commands.json: run /solve-issue or dep-install once by hand and commit it"
  # solve-issue's Step 7 must close the issue itself: land sees `next` move on.
  [ -z "${CREW_ORCHESTRATED:-}" ] || die "CREW_ORCHESTRATED is set: solve-issue would leave every close to crew-afk; unset it"
  # preflight.sh blocks a coder on the default branch, so the branch comes first. Never reset or rebase
  # an existing one: a re-run lands on it as the last run left it.
  git fetch -q origin
  local default cur rc=0 cfg="$ROOT/.coding-crew/config.json"
  default=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  default=${default:-main} cur=$(git branch --show-current)
  [ -n "$cur" ] || die "HEAD is detached: check out a branch first"
  if [ "$cur" = "$default" ]; then
    BRANCH=${BRANCH:-feature/$SLUG}
    if git show-ref --verify -q "refs/heads/$BRANCH"; then git checkout -q "$BRANCH"
    elif git show-ref --verify -q "refs/remotes/origin/$BRANCH"; then git checkout -q -t "origin/$BRANCH"
    else git checkout -q -b "$BRANCH" "origin/$default" && git push -q -u origin "$BRANCH"; fi
  else BRANCH=$cur; fi
  node "$CLI" prd --feature-slug "$SLUG" >"$LOGS/prd.md" || rc=$?
  case $rc in 0) ;; 3) rm -f "$LOGS/prd.md" ;; *) die "reading the feature's PRD failed (exit $rc)" ;; esac
  pr_view
  echo "branch=$BRANCH"
  echo "coder-model=$(jq -r '.solveFeature.models.coder | strings' "$cfg" 2>/dev/null || true)"
  echo "reviewer-model=$(jq -r '.solveFeature.models.reviewer | strings' "$cfg" 2>/dev/null || true)"
  echo "pr=$PR_N"
}

next() {
  local rc=0 ref
  ref=$(node "$CLI" next --feature-slug "$SLUG") || rc=$?
  case $rc in 0) ;; 3) exit 3 ;; *) die "next failed for '$SLUG' (exit $rc, see above)" ;; esac
  # Saved now, not in land: the local tracker's close moves the file, and fetch then exits 3. fetch runs the
  # backend's validateRef, so a ref it rejects stops here, before it reaches the coder's prompt.
  node "$CLI" fetch "$ref" >"$LOGS/${ref//\//_}.issue.md" || die "fetch $ref failed (see above)"
  echo "$ref"
}

MARK='<!-- solve-feature-progress -->'
progress() { # <row> [<note>] — the PR's one progress comment: its earlier rows, then <row>, then <note>; a failed write never stops land
  if [ -z "$PR_N" ]; then printf '%s\n' "$1" ${2:+"$2"}; return 0; fi
  local list cid="" rows="" body
  list=$(gh api "repos/{owner}/{repo}/issues/$PR_N/comments" --paginate 2>/dev/null) || { echo "solve-feature: warning: progress comment not read" >&2; return 0; }
  cid=$(jq -r --arg m "$MARK" '.[] | select(.body | contains($m)) | .id' <<<"$list" 2>/dev/null | head -1) || cid=""
  # The rows sit between the header line and the first blank line, which opens a note.
  [ -z "$cid" ] || rows=$(jq -r --argjson id "$cid" '.[] | select(.id == $id) | .body' <<<"$list" | awk 'NR > 2 && /^$/ {exit} NR > 2')
  body="$MARK"$'\n'"solve-feature — $SLUG — host ${SOLVE_FEATURE_HOST:-$(hostname 2>/dev/null || uname -n)} — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  body+=$'\n'"${rows:+$rows$'\n'}$1${2:+$'\n\n'$2}"
  if [ -n "$cid" ]; then gh api -X PATCH "repos/{owner}/{repo}/issues/comments/$cid" -f body="$body" >/dev/null 2>&1
  else gh api "repos/{owner}/{repo}/issues/$PR_N/comments" -f body="$body" 2>/dev/null | jq -e '.id' >/dev/null
  fi || echo "solve-feature: warning: progress comment on PR #$PR_N not written" >&2
}
stop() { # <row> <step> <reason> [<log>] — a Stopped-at note (with the log's last 20 lines) after the row; exit 1
  local note="Stopped at $2: $3"
  [ -z "${4:-}" ] || note+=$'\n```\n'"$(tail -n 20 "$4")"$'\n```'
  progress "$1" "$note"
  echo "solve-feature: $REF $2 failed: $3${4:+ — log: $4}"
  mark_stopped "$REF $2 failed: $3"; exit 1
}

# The PR body: address-pr-comments finds a solve-feature PR by the begin line and reads its slug from the
# slug line; the reviewer reads the <details> block as the spec. Text outside the block is a human's and kept.
BEGIN='<!-- solve-feature:begin -->' END='<!-- solve-feature:end -->'
pr_title() { # <ref-slug> — the PRD's title when the CLI's note heads the prd output, else the issue's own
  local t; t=$(head -n 1 <<<"$PRD_TEXT" | sed -nE 's/^<!-- PRD issue #[0-9]+: (.*) -->$/\1/p' | sed 's/^PRD: //')
  [ -n "$t" ] || t=$(grep -m1 '^# ' "$LOGS/$1.issue.md" | sed 's/^# //')
  printf '%s' "$t"
}
pr_body() { # <ref> <ref-slug> <existing body> — the whole body, the block rebuilt with $SUMMARY at its top and this
  # issue appended (none for an empty <ref>)
  local old="$3" before after old_sections="" title crit sections head tail refs
  if [[ "$old" == *"$BEGIN"* && "$old" == *"$END"* ]]; then
    before=$(awk -v b="$BEGIN" '$0 == b {exit} {print}' <<<"$old")
    after=$(awk -v e="$END" 'f {print} $0 == e {f = 1}' <<<"$old")
    old_sections=$(awk -v b="$BEGIN" '$0 == b {blk = 1} blk && /^### / {s = 1} blk && /^<\/details>$/ {s = 0; blk = 0} s' <<<"$old")
  else before="$old" after=""; fi
  sections="$old_sections"
  if [ -n "$1" ] && [[ "$old_sections" != *"### $1 — "* ]]; then
    title=$(grep -m1 '^# ' "$LOGS/$2.issue.md" | sed 's/^# //')
    # Plain bullets, not task boxes: GitHub counts a PR's boxes as its open tasks.
    crit=$(awk '/^## /{f = tolower($0) ~ /^## acceptance criteria/} f' "$LOGS/$2.issue.md" | sed -E 's/^([[:space:]]*)[-*] \[[ xX]\] /\1- /')
    sections="${old_sections:+$old_sections$'\n\n'}### $1 — $title"$'\n'"$crit"
  fi
  head="$BEGIN"$'\n'"${SUMMARY:+$SUMMARY$'\n\n'}Implemented by solve-feature (\`$SLUG\`)."$'\n\n'"<details><summary>Spec</summary>"$'\n\n'
  tail=$'\n</details>\n\n'
  refs=$(node "$CLI" closing-refs --feature-slug "$SLUG") || die "closing-refs failed for '$SLUG' (exit $?, see above)"
  tail+="$refs"$'\n'
  tail+="<!-- solve-feature:slug $SLUG -->"$'\n'"$END"
  printf '%s' "${before:+$before$'\n'}$head${PRD_TEXT:+$PRD_TEXT$'\n\n'}$sections"$'\n'"$tail${after:+$'\n'$after}"
}

# Installed beside this skill (.coding-crew/<skill>/scripts), else user-level, as solve-issue finds dep-install.
scripts_of() { local d; for d in "$SELF/../../$1/scripts" "$HOME/.coding-crew/$1/scripts"; do [ -d "$d" ] && { (cd "$d" && pwd); return; }; done
  die "$1 scripts not found: run install.sh --skill solve-feature"; }

land() {
  local rs="${REF//\//_}" rc=0 again checks_dir dep_dir clog f
  [ -f "$LOGS/$rs.issue.md" ] || die "no saved issue for $REF: run next first"
  [ ! -f "$LOGS/prd.md" ] || PRD_TEXT=$(cat "$LOGS/prd.md")
  checks_dir=$(scripts_of solve-issue)
  dep_dir=$(scripts_of dep-install) clog="$LOGS/$rs.checks.log"
  pr_view # a stop reports on the PR an earlier land (or a human) opened; before one exists, on stdout
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop "$REF  solve ✗  checks ·" solve "branch changed to '$(git branch --show-current)'"
  [ -z "$(git status --porcelain)" ] || stop "$REF  solve ✗  checks ·" solve "working tree left dirty"
  # solve-issue's close moves the issue out of `next`; still first means it stopped short (partial, blocked).
  again=$(node "$CLI" next --feature-slug "$SLUG") || rc=$?
  case $rc in 0|3) ;; *) die "next failed for '$SLUG' (exit $rc, see above)" ;; esac
  [ "$again" != "$REF" ] || stop "$REF  solve ✗  checks ·" solve "coder ran but did not close $REF (its report says why)"
  rc=0; bash "$checks_dir/run-checks.sh" --project-root "$ROOT" --main-root "$ROOT" --dep-scripts "$dep_dir" >"$clog" 2>&1 || rc=$?
  [ "$rc" != 3 ] || stop "$REF  solve ✓  checks ✗" checks "no check commands known (DISCOVER): run /solve-issue or dep-install once by hand and commit .coding-crew/dev-commands.json" "$clog"
  # $REF is closed and committed but not pushed: only a land for it pushes it with its spec in the PR body.
  [ "$rc" = 0 ] || stop "$REF  solve ✓  checks ✗" checks "run-checks.sh exit $rc; once fixed and committed, run land $SLUG $REF $BRANCH before a re-run" "$clog"
  # The body first: a closing-refs failure stops before anything is pushed.
  f="$LOGS/$rs.pr-body.md"
  pr_body "$REF" "$rs" "$( [ -z "$PR_N" ] || jq -r '.body // ""' <<<"$VIEW")" >"$f"
  git push -q -u origin "$BRANCH" || stop "$REF  solve ✓  checks ✓" push "git push failed; once it can push, run land $SLUG $REF $BRANCH before a re-run"
  if [ -n "$PR_N" ]; then
    gh pr edit "$PR_N" --body-file "$f" >/dev/null || die "gh pr edit $PR_N failed"
  else
    URL=$(gh pr create --draft --title "$(pr_title "$rs")" --body-file "$f") || die "gh pr create failed"
    PR_N="${URL##*/}"; [[ "$PR_N" =~ ^[0-9]+$ ]] || die "gh pr create printed no PR URL: $URL"
  fi
  progress "$REF  solve ✓  checks ✓"
  echo "pr=$PR_N"
}

# The fixer's edits are staged before the checks and committed after, so the push carries exactly what was gated.
fix() {
  local report="$LOGS/pr-$PR.review.json" unfixed="$LOGS/pr-$PR.unfixed.md" clog="$LOGS/pr-$PR.checks.log"
  local checks_dir dep_dir head_oid draft prd rc=0 total sha="" listed="" result attention="" ready=no note
  checks_dir=$(scripts_of solve-issue) dep_dir=$(scripts_of dep-install)
  VIEW=$(gh pr view "$PR" --json headRefOid,isDraft) || die "gh pr view $PR failed"
  PR_N=$PR head_oid=$(jq -r '.headRefOid // empty' <<<"$VIEW") draft=$(jq -r '.isDraft' <<<"$VIEW")
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop "review ✗  checks ·" fix "branch changed to '$(git branch --show-current)'"
  [ -f "$report" ] || stop "review ✗  checks ·" fix "no review report at $report"
  prd=$(jq -r '.prd // empty' "$report" 2>/dev/null) || stop "review ✗  checks ·" fix "unreadable review report $report"
  total=$(jq '.findings // [] | length' "$report")
  # Staged before the checks, so run-checks.sh's modified-files test also sees a check rewrite a file the fixer changed.
  git add -A
  bash "$checks_dir/run-checks.sh" --project-root "$ROOT" --main-root "$ROOT" --dep-scripts "$dep_dir" >"$clog" 2>&1 || rc=$?
  [ "$rc" != 3 ] || stop "review ✓  checks ✗" fix "no check commands known (DISCOVER): run /solve-issue or dep-install once by hand and commit .coding-crew/dev-commands.json" "$clog"
  [ "$rc" = 0 ] || stop "review ✓  checks ✗" fix "run-checks.sh exit $rc; once fixed and committed (not pushed), run fix $SLUG $PR $BRANCH" "$clog"
  git diff --cached --quiet || git commit -q -m "Fix the review's findings on PR #$PR"
  git push -q -u origin "$BRANCH" || stop "review ✓  checks ✓" fix "git push failed; once it can push, run fix $SLUG $PR $BRANCH"

  # Needs a person: the reviewer's gaps, an unmet spec, each line the fixer left in unfixed.md, and a fixer that
  # changed nothing without saying why (it crashed or gave up). "Changed nothing" is HEAD still at the PR's head,
  # which is why the stops say to commit, not push, before a re-run.
  [ "$(git rev-parse HEAD)" = "$head_oid" ] || sha=$(git rev-parse --short HEAD)
  # Markdown headings in unfixed.md are not findings ('#2: …' is).
  [ ! -f "$unfixed" ] || listed=$({ grep -v -E '^[[:space:]]*#+[[:space:]]' "$unfixed" || true; } | sed -E 's/^[[:space:]]*[-*][[:space:]]+//' | grep -v '^[[:space:]]*$' || true)
  attention=$(jq -r '.gaps // [] | .[] | tostring' "$report")
  [ "$prd" = met ] || attention+=$'\n'"the reviewer found the spec unmet"
  attention+=$'\n'"$listed"
  [ "$total" = 0 ] || [ -n "$sha" ] || [ -n "$listed" ] || attention+=$'\n'"the fixer changed nothing"
  rm -f "$unfixed"
  attention=$(grep -v '^[[:space:]]*$' <<<"$attention" || true)
  if [ "$total" = 0 ]; then result="no findings"; else result="$total finding(s)${sha:+, fixed in $sha}"; fi
  if [ -n "$attention" ]; then
    note="Needs attention:"$'\n'"$(sed 's/^/- /' <<<"$attention")"
  elif [ "$draft" = true ]; then
    gh pr ready "$PR" >/dev/null || stop "review ✓  $result  checks ✓" fix "gh pr ready $PR failed; the fixes are pushed, so run gh pr ready $PR by hand"
    ready=yes note="Marked ready for review: nothing needs attention."
  else ready=already note="Nothing needs attention; the PR was already ready for review."; fi
  progress "review ✓  $result  checks ✓" "$note"
  if [ -n "$attention" ]; then printf '%s\n' "$attention" >"$LOGS/pr-$PR.attention.md"; else rm -f "$LOGS/pr-$PR.attention.md"; fi
  rm -f "$LOGS/stopped"
  printf 'pr=%s head=%s\n' "$PR" "$(git rev-parse HEAD)" >"$LOGS/reviewed"
  echo "FIX: findings=$total needs-attention=$(grep -c . <<<"$attention" || true) ready=$ready"
}

# The writer's summary goes inside the block, so a later land's rebuild drops it rather than leave it stale.
describe() {
  local f="$LOGS/pr-$PR.summary.md" att="$LOGS/pr-$PR.attention.md" title body
  [ -f "$f" ] || { echo "solve-feature: warning: no summary at $f; PR #$PR's body is unchanged" >&2; return 0; }
  title=$(head -n 1 "$f" | sed -n 's/^# //p')
  SUMMARY=$(if [ -n "$title" ]; then tail -n +2 "$f"; else cat "$f"; fi | sed '/./,$!d')
  [ ! -s "$att" ] || SUMMARY+=$'\n\n'"## Needs attention"$'\n\n'"$(sed 's/^/- /' "$att")"
  [ ! -f "$LOGS/prd.md" ] || PRD_TEXT=$(cat "$LOGS/prd.md")
  body=$(gh pr view "$PR" --json body | jq -r '.body // ""') || die "gh pr view $PR failed"
  pr_body "" "" "$body" >"$LOGS/pr-$PR.body.md"
  gh pr edit "$PR" ${title:+--title "$title"} --body-file "$LOGS/pr-$PR.body.md" >/dev/null || die "gh pr edit $PR failed"
  echo "described PR #$PR"
}

"$CMD"
