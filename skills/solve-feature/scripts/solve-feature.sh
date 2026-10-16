#!/usr/bin/env bash
# solve-feature.sh start|next|land|fix|describe — the guards of solve-feature's loop. SKILL.md drives the loop and
# runs each issue's coder (between `next` and `land`), the review's reviewer and fixer (before `fix`) and the PR's
# writer (before `describe`) as subagents of the host agent; every guard is an exit code here.
#   start <slug> [--branch <name>]  preconditions, the slug among the tracker's features, the branch (--branch, else
#                                   feature/<slug>; an existing one gets origin's default branch merged in and
#                                   pushed), .solve-feature/spec.md; prints branch=, coder-model=,
#                                   reviewer-model= (.coding-crew/config.json solveFeature.models) and pr=
#   next <slug>                     the next ready issue, saved for land; prints its ref. The coder writes its
#                                   report to .solve-feature/coder.report.md, which land's solve stop names
#   land <slug> <ref> <branch>      the coder left <branch> clean with <ref> closed and the checks pass: push, and
#                                   open the draft PR if the branch has none; prints pr=<n>. Failed checks reopen
#                                   <ref> and push its work before the stop, and a failed push reopens it, so a
#                                   plain re-run picks it up again
#   fix <slug> <pr> <branch>        the review report is there and the checks pass on the fixer's tree: commit it,
#                                   push, and write what needs a person to pr-<pr>.attention.md; last stdout line
#                                   `FIX: findings=<k> needs-attention=<a> review-again=yes|no`, yes when a
#                                   CRITICAL/HIGH/MEDIUM finding was there and HEAD moved past the head fix first
#                                   saw that review round (kept in pr-<pr>.head until the attention file is written)
#   describe <slug> <pr>            write the PR's whole body and title, mark the draft ready when nothing needs a
#                                   person, then write the outcome
# .solve-feature/outcome holds the run's result in one line: `ready pr=<n>`, `needs-attention pr=<n>` or
# `stopped: <what> failed: <reason>`, <what> the subcommand (die, nothing_left) or `<ref> <step>` (stop).
# Exit: 0 ok; 1 a stop; 2 a usage error; 3 from next when no ready issue is left.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS=""
# The run's one-line result, read by a host such as the Actions job; a missing file means it never finished.
outcome() { [ -z "$LOGS" ] || printf '%s\n' "$1" >"$LOGS/outcome"; }
die() { echo "solve-feature: $*" >&2; outcome "stopped: $CMD failed: $*"; exit 1; }
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
mkdir -p "$ROOT/.solve-feature" && echo '*' >"$ROOT/.solve-feature/.gitignore" # ignored in any repo, so the tree stays clean
LOGS="$ROOT/.solve-feature"
[ "$CMD" != start ] || rm -f "$LOGS/outcome" "$LOGS"/pr-*.unfixed.md "$LOGS"/pr-*.review.json "$LOGS"/pr-*.summary.md "$LOGS"/pr-*.attention.md "$LOGS"/pr-*.head
# The tracker and checks libraries: this skill's scripts/<lib> (a link into lib/ here, a real directory once installed).
CLI="$SELF/tracker/cli.mjs" CHECKS="$SELF/checks"
[ -f "$CLI" ] || die "tracker CLI not found ($CLI): re-install coding-crew"

# push <git push args> — `git push -q`; on failure sets PUSH_WHY to git's reason and returns 1. git's stderr still
# reaches the terminal. The reason: a rejected ref's parenthesised one (GitHub's workflow-permission refusal arrives
# there), else git's last fatal:/error: line, else its last non-empty one (a network failure ends in advice).
PUSH_WHY=""
push() {
  local err="$LOGS/push.err" rc=0
  git push -q "$@" 2>"$err" || rc=$?
  cat "$err" >&2
  [ "$rc" != 0 ] || return 0
  PUSH_WHY=$(sed -nE 's/^[[:space:]]*! \[(remote )?rejected\][^(]*\((.*)\)[[:space:]]*$/\2/p' "$err" | tail -1)
  [ -n "$PUSH_WHY" ] || PUSH_WHY=$(grep -E '^(fatal|error):' "$err" | tail -1 || true)
  [ -n "$PUSH_WHY" ] || PUSH_WHY=$(grep -v '^[[:space:]]*$' "$err" | tail -1 || true)
  return 1
}

PR_N=""
pr_view() { # sets PR_N when the branch has an OPEN PR, else clears it
  local view; view=$(gh pr view "$BRANCH" --json number,state 2>/dev/null) || view=""
  PR_N=$(jq -r 'select(.state == "OPEN") | .number' <<<"$view" 2>/dev/null || true)
}

# .solve-feature/spec.md, which the reviewer and the PR body read: the PRD, then every issue of the feature, open
# or closed, with its acceptance criteria. All of them: an issue another run landed is met in the code, and one
# still open is a gap a person must see.
write_spec() {
  local spec="$LOGS/spec.md" dir="$LOGS/issues" rc=0 f title
  node "$CLI" prd --feature-slug "$SLUG" >"$spec" || rc=$?
  case $rc in 0) echo >>"$spec" ;; 3) ;; *) die "reading the feature's PRD failed (exit $rc)" ;; esac
  rm -rf "$dir"
  node "$CLI" known --feature-slug "$SLUG" --out "$dir" || die "known failed for '$SLUG' (see above)"
  ls "$dir" | sort -n | while IFS= read -r f; do
    title=$(grep -m1 '^# ' "$dir/$f" | sed 's/^# //' || true)
    printf '### %s — %s\n' "${f%.md}" "${title:-${f%.md}}"
    # Plain bullets, not task boxes: GitHub counts a PR's boxes as its open tasks.
    awk '/^## /{f = tolower($0) ~ /^## acceptance criteria/} f' "$dir/$f" | sed -E 's/^([[:space:]]*)[-*] \[[ xX]\] /\1- /'
  done >>"$spec"
}

start() {
  [ -z "$(git status --porcelain)" ] || die "working tree is not clean: commit or stash first"
  local features; features=$(node "$CLI" features | cut -f1) || die "features failed (see above)"
  grep -qxF "$SLUG" <<<"$features" || die "no feature '$SLUG'; features: $(paste -sd' ' - <<<"$features")"
  # preflight.sh blocks a coder on the default branch, so the branch comes first. Never reset or rebase
  # an existing one: a re-run lands on it as the last run left it, with the default branch merged in.
  git fetch -q origin || die "git fetch origin failed (see above)"
  local default cfg="$ROOT/.coding-crew/config.json"
  default=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  default=${default:-main}
  [ "$BRANCH" != "$default" ] || die "--branch '$BRANCH': '$default' is the default branch; name a feature branch"
  BRANCH=${BRANCH:-feature/$SLUG}
  if git show-ref --verify -q "refs/heads/$BRANCH"; then git checkout -q "$BRANCH"
  elif git show-ref --verify -q "refs/remotes/origin/$BRANCH"; then git checkout -q -t "origin/$BRANCH"
  else git checkout -q -b "$BRANCH" "origin/$default"
  fi || die "cannot check out $BRANCH (see above)"
  # A branch origin lacks is new, or one whose first push was refused: a re-run pushes it before any coder runs.
  git show-ref --verify -q "refs/remotes/origin/$BRANCH" || push -u origin "$BRANCH" || die "cannot push $BRANCH: $PUSH_WHY"
  # The checks run the branch's own files, so a branch an earlier run left takes the default branch's fixes first.
  if ! git merge-base --is-ancestor "origin/$default" HEAD; then
    if ! git merge -q --no-edit "origin/$default" >&2; then
      local conflicts; conflicts=$(git diff --name-only --diff-filter=U | paste -sd' ' -)
      git merge --abort 2>/dev/null || true
      [ -n "$conflicts" ] || die "merging origin/$default into $BRANCH failed (see above)"
      die "merging origin/$default into $BRANCH conflicts in $conflicts: merge it by hand, push $BRANCH, then re-run"
    fi
    push origin "$BRANCH" || die "cannot push $BRANCH after merging origin/$default into it: $PUSH_WHY"
  fi
  write_spec
  pr_view
  echo "branch=$BRANCH"
  echo "coder-model=$(jq -r '.solveFeature.models.coder | strings' "$cfg" 2>/dev/null || true)"
  echo "reviewer-model=$(jq -r '.solveFeature.models.reviewer | strings' "$cfg" 2>/dev/null || true)"
  echo "pr=$PR_N"
}

nothing_left() { # exit 3; with no open PR on the branch, the run has nothing to review and stops here
  BRANCH=$(git branch --show-current); pr_view
  if [ -z "$PR_N" ]; then
    echo "solve-feature: nothing landed: no ready issue for $SLUG and no open PR" >&2
    outcome "stopped: next failed: nothing landed: no ready issue for $SLUG and no open PR"
  fi
  exit 3
}

next() {
  local rc=0 ref
  ref=$(node "$CLI" next --feature-slug "$SLUG") || rc=$?
  case $rc in 0) ;; 3) nothing_left ;; *) die "next failed for '$SLUG' (exit $rc, see above)" ;; esac
  # Saved now, not in land: the local tracker's close moves the file, and fetch then exits 3. fetch runs the
  # backend's validateRef, so a ref it rejects stops here, before it reaches the coder's prompt.
  node "$CLI" fetch "$ref" >"$LOGS/${ref//\//_}.issue.md" || die "fetch $ref failed (see above)"
  # One coder at a time writes its report here; an earlier one's would read as this coder's at land's solve stop.
  rm -f "$LOGS/coder.report.md"
  echo "$ref"
}

stop() { # <step> <reason> [<log>]; exit 1
  echo "solve-feature: $REF $1 failed: $2${3:+ — log: $3}"
  outcome "stopped: $REF $1 failed: $2"; exit 1
}

# address-pr-comments finds a solve-feature PR by the begin line and reads its slug from the slug line.
BEGIN='<!-- solve-feature:begin -->' END='<!-- solve-feature:end -->'
pr_title() { # <ref-slug> — the PRD's title when the CLI's note heads the spec, else the issue's own
  local t; t=$(head -n 1 "$LOGS/spec.md" | sed -nE 's/^<!-- PRD issue #[0-9]+: (.*) -->$/\1/p' | sed 's/^PRD: //')
  [ -n "$t" ] || t=$(grep -m1 '^# ' "$LOGS/$1.issue.md" | sed 's/^# //')
  printf '%s' "$t"
}
checks_lib() { [ -f "$CHECKS/run-checks.sh" ] || die "checks library not found ($CHECKS): re-install coding-crew"; }

# reopen_ref <step> <reason> <commit message> <recovery when reopen fails> [<log>] — make the closed $REF ready
# again, so a plain re-run's coder takes it up instead of the tracker counting it landed; a failure stops at <step>.
reopen_ref() {
  local before changed
  before=$(git status --porcelain -uall)
  node "$CLI" reopen "$REF" >/dev/null || stop "$1" "$2; reopen $REF failed (see above): $4" "${5:-}"
  # A file tracker's reopen moves a tracked issue file; only that is committed, never what the checks left.
  changed=$(comm -13 <(sort <<<"$before") <(git status --porcelain -uall | sort) | cut -c4-)
  if [ -n "$changed" ]; then
    xargs git add -A -- <<<"$changed" && git commit -q -m "$3" ||
      stop "$1" "$2; $REF is ready again but committing its reopen failed (see above): commit it, then re-run" "${5:-}"
  fi
}

# hand_back <reason> <recovery> <log> — the checks failed on a closed issue: reopen it and push its work, then stop.
# Pushed, the work outlives this checkout (an Actions runner's goes with its job); reopened, a plain re-run's coder
# starts from that work instead of skipping the issue. The PR stays a draft until describe, so nothing reads as ready.
hand_back() {
  reopen_ref checks "$1" "Reopen $REF: its checks failed" "once fixed and committed, run land $SLUG $REF $BRANCH before a re-run" "$3"
  push -u origin "$BRANCH" || stop checks "$1; $REF is ready again but git push failed: $PUSH_WHY; once it can push, $2" "$3"
  stop checks "$1; $REF is ready again with its work pushed to $BRANCH: $2" "$3"
}

land() {
  local rs="${REF//\//_}" rc=0 again clog="$LOGS/${REF//\//_}.checks.log" f url
  [ -f "$LOGS/$rs.issue.md" ] || die "no saved issue for $REF: run next first"
  checks_lib
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop solve "branch changed to '$(git branch --show-current)'"
  # solve-issue's blocked leaves files a check rewrote for a human to commit, and its report says so.
  [ -z "$(git status --porcelain)" ] || stop solve "working tree left dirty$([ ! -s "$LOGS/coder.report.md" ] || echo "; why: $LOGS/coder.report.md")"
  # solve-issue's close moves the issue out of `next`; still first means it stopped short (partial, blocked).
  again=$(node "$CLI" next --feature-slug "$SLUG") || rc=$?
  case $rc in 0|3) ;; *) die "next failed for '$SLUG' (exit $rc, see above)" ;; esac
  if [ "$again" = "$REF" ]; then
    [ -s "$LOGS/coder.report.md" ] || stop solve "coder ran but did not close $REF and left no report at $LOGS/coder.report.md"
    stop solve "coder ran but did not close $REF; why: $LOGS/coder.report.md"
  fi
  rc=0; bash "$CHECKS/run-checks.sh" --project-root "$ROOT" >"$clog" 2>&1 || rc=$?
  [ "$rc" != 3 ] || hand_back "no check commands known (DISCOVER): the coder discovered none" "run /setup-coding-crew and commit .coding-crew/dev-commands.json, then re-run" "$clog"
  [ "$rc" = 0 ] || hand_back "run-checks.sh exit $rc" "fix the cause, then re-run" "$clog"
  # Any failed push reopens the issue, unretried: an Actions runner's commits go with its job, so a closed issue
  # would count as landed work that exists nowhere. Here a re-run finds the commits, since start never resets a branch.
  if ! push -u origin "$BRANCH"; then
    local why="git push failed: $PUSH_WHY"
    reopen_ref push "$why" "Reopen $REF: its push failed" "reopen $REF by hand, then re-run where git can push"
    stop push "$why; $REF is ready again: re-run where git can push (a re-run in this checkout starts from its unpushed commits)"
  fi
  pr_view
  if [ -z "$PR_N" ]; then
    # describe writes the whole body at the end; until then it only carries the markers address-pr-comments reads.
    f="$LOGS/pr-body.md"
    printf '%s\n' "$BEGIN" "Implemented by solve-feature (\`$SLUG\`) — in progress." "<!-- solve-feature:slug $SLUG -->" "$END" >"$f"
    url=$(gh pr create --draft --title "$(pr_title "$rs")" --body-file "$f") || die "gh pr create failed"
    PR_N="${url##*/}"; [[ "$PR_N" =~ ^[0-9]+$ ]] || die "gh pr create printed no PR URL: $url"
  fi
  echo "pr=$PR_N"
}

# The fixer's edits are staged before the checks and committed after, so the push carries exactly what was gated.
fix() {
  local report="$LOGS/pr-$PR.review.json" unfixed="$LOGS/pr-$PR.unfixed.md" clog="$LOGS/pr-$PR.checks.log"
  local headf="$LOGS/pr-$PR.head" head_oid spec rc=0 total severe moved=no again=no attention=""
  checks_lib
  # The round's first run keeps the PR's head, so a re-run after a person pushed the fix by hand still sees it moved.
  if [ -s "$headf" ]; then head_oid=$(cat "$headf")
  else
    head_oid=$(gh pr view "$PR" --json headRefOid | jq -r '.headRefOid // empty') || die "gh pr view $PR failed"
    printf '%s\n' "$head_oid" >"$headf"
  fi
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop fix "branch changed to '$(git branch --show-current)'"
  [ -f "$report" ] || stop fix "no review report at $report"
  spec=$(jq -r '.spec // empty' "$report" 2>/dev/null) || stop fix "unreadable review report $report"
  jq -e '.gaps // [] | type == "array"' "$report" >/dev/null || stop fix "the review report's gaps is not a list: $report"
  total=$(jq '.findings // [] | length' "$report")
  # crew-review's own severity field; a missing or unknown one is not severe.
  severe=$(jq '[.findings // [] | .[]? | select(.severity? | IN("CRITICAL", "HIGH", "MEDIUM"))] | length' "$report")
  # Staged before the checks, so run-checks.sh's modified-files test also sees a check rewrite a file the fixer changed.
  git add -A
  bash "$CHECKS/run-checks.sh" --project-root "$ROOT" >"$clog" 2>&1 || rc=$?
  [ "$rc" != 3 ] || stop fix "no check commands known (DISCOVER): run /setup-coding-crew and commit .coding-crew/dev-commands.json" "$clog"
  [ "$rc" = 0 ] || stop fix "run-checks.sh exit $rc; once fixed and committed, run fix $SLUG $PR $BRANCH, then describe $SLUG $PR" "$clog"
  git diff --cached --quiet || git commit -q -m "Fix the review's findings on PR #$PR"
  push -u origin "$BRANCH" || stop fix "git push failed: $PUSH_WHY; once it can push, or once you have pushed it, run fix $SLUG $PR $BRANCH, then describe $SLUG $PR"

  # "Changed nothing" is HEAD still at the head fix first saw this round, so a push by hand before a re-run counts.
  [ "$(git rev-parse HEAD)" = "$head_oid" ] || moved=yes
  # Needs a person: the reviewer's gaps, an unmet spec, each line the fixer left in unfixed.md, and a fixer that
  # changed nothing without saying why (it crashed or gave up).
  attention=$(jq -r '.gaps // [] | .[] | tostring' "$report")
  [ "$spec" = met ] || attention+=$'\n'"the reviewer found the spec unmet"
  [ ! -f "$unfixed" ] || attention+=$'\n'"$(cat "$unfixed")"
  [ "$total" = 0 ] || [ "$moved" = yes ] || [ -s "$unfixed" ] || attention+=$'\n'"the fixer changed nothing"
  # Fixes to a CRITICAL/HIGH/MEDIUM finding are worth reviewing again; SKILL.md caps that at one re-review.
  [ "$severe" = 0 ] || [ "$moved" = no ] || again=yes
  rm -f "$unfixed"
  # describe reads it: an empty file is a review with nothing needing a person.
  grep -v '^[[:space:]]*$' <<<"$attention" >"$LOGS/pr-$PR.attention.md" || true
  # A second review round starts from the head its reviewer saw.
  rm -f "$headf"
  echo "FIX: findings=$total needs-attention=$(grep -c . "$LOGS/pr-$PR.attention.md" || true) review-again=$again"
}

# The whole body, written once at the end. Readiness and the outcome come after it, so a failed write never leaves a
# ready PR with land's one-line body. A re-run rewrites all of it, text a person added included.
describe() {
  local f="$LOGS/pr-$PR.summary.md" att="$LOGS/pr-$PR.attention.md" body="$LOGS/pr-$PR.body.md" title="" refs draft result
  [ -f "$att" ] || die "no review result at $att: run fix $SLUG $PR <branch> first"
  refs=$(node "$CLI" closing-refs --feature-slug "$SLUG") || die "closing-refs failed for '$SLUG' (see above)"
  [ ! -f "$f" ] || title=$(head -n 1 "$f" | sed -n 's/^# //p')
  {
    echo "$BEGIN"
    # Written here, not by the writer subagent, so a reviewer always sees that agents wrote this PR.
    printf '> Written by solve-feature (`%s`): its coder, reviewer and fixer were agents; no person has read this body.\n\n' "$SLUG"
    # write-pr's summary minus its title line, which titles the PR instead.
    if [ -f "$f" ]; then if [ -n "$title" ]; then tail -n +2 "$f"; else cat "$f"; fi | sed '/./,$!d'; echo; fi
    if [ -s "$att" ]; then printf '## Needs attention\n\n'; sed 's/^/- /' "$att"; echo; fi
    printf '<details><summary>Spec</summary>\n\n%s\n\n</details>\n\n' "$(cat "$LOGS/spec.md")"
    [ -z "$refs" ] || printf '%s\n' "$refs"
    printf '%s\n' "<!-- solve-feature:slug $SLUG -->" "$END"
  } >"$body"
  gh pr edit "$PR" ${title:+--title "$title"} --body-file "$body" >/dev/null || die "gh pr edit $PR failed"
  if [ -s "$att" ]; then result=needs-attention
  else
    result=ready draft=$(gh pr view "$PR" --json isDraft | jq -r '.isDraft') || die "gh pr view $PR failed"
    [ "$draft" != true ] || gh pr ready "$PR" >/dev/null || die "gh pr ready $PR failed; the body is written, so run gh pr ready $PR by hand"
  fi
  outcome "$result pr=$PR"
  echo "$result pr=$PR"
}

"$CMD"
