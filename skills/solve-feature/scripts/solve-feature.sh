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
[ "$CMD" != start ] || rm -f "$LOGS/outcome" "$LOGS"/pr-*.unfixed.md "$LOGS"/pr-*.review.json "$LOGS"/pr-*.summary.md "$LOGS"/pr-*.attention.md
COMMON="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" CLI=""
for c in "$ROOT" "$COMMON" "$HOME"; do [ -f "$c/.coding-crew/tracker/cli.mjs" ] && { CLI="$c/.coding-crew/tracker/cli.mjs"; break; }; done
[ -n "$CLI" ] || die "tracker CLI not found (.coding-crew/tracker/cli.mjs): run install.sh"

PR_N="" URL="" VIEW="" PRD_TEXT="" SUMMARY=""
pr_view() { # sets PR_N and URL (and VIEW) when the branch has an OPEN PR, else clears them
  VIEW=$(gh pr view "$BRANCH" --json number,state,url,isDraft,body 2>/dev/null) || VIEW=""
  if [ "$(jq -r '.state // empty' <<<"$VIEW" 2>/dev/null || true)" = OPEN ]; then
    PR_N=$(jq -r '.number' <<<"$VIEW") URL=$(jq -r '.url' <<<"$VIEW")
  else PR_N="" URL=""; fi
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
  # DISCOVER needs an agent and a human once; run-checks.sh's own exit 3 guards a file that names no usable command.
  [ -f "$ROOT/.coding-crew/dev-commands.json" ] || die "no .coding-crew/dev-commands.json: run /solve-issue or dep-install once by hand and commit it"
  # solve-issue's Step 7 must close the issue itself: land sees `next` move on.
  [ -z "${CREW_ORCHESTRATED:-}" ] || die "CREW_ORCHESTRATED is set: solve-issue would leave every close to crew-afk; unset it"
  local features; features=$(node "$CLI" features | cut -f1) || die "features failed (see above)"
  grep -qxF "$SLUG" <<<"$features" || die "no feature '$SLUG'; features: $(paste -sd' ' - <<<"$features")"
  # preflight.sh blocks a coder on the default branch, so the branch comes first. Never reset or rebase
  # an existing one: a re-run lands on it as the last run left it.
  git fetch -q origin
  local default cfg="$ROOT/.coding-crew/config.json"
  default=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  default=${default:-main}
  [ "$BRANCH" != "$default" ] || die "--branch '$BRANCH': '$default' is the default branch; name a feature branch"
  BRANCH=${BRANCH:-feature/$SLUG}
  if git show-ref --verify -q "refs/heads/$BRANCH"; then git checkout -q "$BRANCH"
  elif git show-ref --verify -q "refs/remotes/origin/$BRANCH"; then git checkout -q -t "origin/$BRANCH"
  else git checkout -q -b "$BRANCH" "origin/$default" && git push -q -u origin "$BRANCH"; fi
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
    outcome "stopped: nothing landed: no ready issue for $SLUG and no open PR"
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
  echo "$ref"
}

stop() { # <step> <reason> [<log>]; exit 1
  echo "solve-feature: $REF $1 failed: $2${3:+ — log: $3}"
  outcome "stopped: $REF $1 failed: $2"; exit 1
}

# The PR body: address-pr-comments finds a solve-feature PR by the begin line and reads its slug from the
# slug line; the reviewer reads the <details> block as the spec. Text outside the block is a human's and kept.
BEGIN='<!-- solve-feature:begin -->' END='<!-- solve-feature:end -->'
pr_title() { # <ref-slug> — the PRD's title when the CLI's note heads the spec, else the issue's own
  local t; t=$(head -n 1 "$LOGS/spec.md" | sed -nE 's/^<!-- PRD issue #[0-9]+: (.*) -->$/\1/p' | sed 's/^PRD: //')
  [ -n "$t" ] || t=$(grep -m1 '^# ' "$LOGS/$1.issue.md" | sed 's/^# //')
  printf '%s' "$t"
}
pr_body() { # <ref> <ref-slug> <existing body> — the whole body, the block rebuilt with $SUMMARY at its top and this
  # issue appended (none for an empty <ref>)
  local old="$3" before after old_sections="" title crit sections head tail refs
  if [[ "$old" == *"$BEGIN"* && "$old" == *"$END"* ]]; then
    before=$(awk -v b="$BEGIN" '$0 == b {exit} {print}' <<<"$old")
    after=$(awk -v e="$END" 'f {print} $0 == e {f = 1}' <<<"$old")
    # Only inside the spec's <details>: the summary above it is the writer's free text.
    old_sections=$(awk -v b="$BEGIN" '$0 == b {blk = 1} blk && $0 == "<details><summary>Spec</summary>" {d = 1}
      d && /^### / {s = 1} d && /^<\/details>$/ {s = 0; d = 0; blk = 0} s' <<<"$old")
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

# A dependency skill is installed beside this one.
scripts_of() { [ -d "$SELF/../../$1/scripts" ] && { (cd "$SELF/../../$1/scripts" && pwd); return; }
  die "$1 scripts not found: run install.sh --skill solve-feature"; }

land() {
  local rs="${REF//\//_}" rc=0 again checks_dir dep_dir clog f
  [ -f "$LOGS/$rs.issue.md" ] || die "no saved issue for $REF: run next first"
  checks_dir=$(scripts_of solve-issue)
  dep_dir=$(scripts_of dep-install) clog="$LOGS/$rs.checks.log"
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop solve "branch changed to '$(git branch --show-current)'"
  [ -z "$(git status --porcelain)" ] || stop solve "working tree left dirty"
  # solve-issue's close moves the issue out of `next`; still first means it stopped short (partial, blocked).
  again=$(node "$CLI" next --feature-slug "$SLUG") || rc=$?
  case $rc in 0|3) ;; *) die "next failed for '$SLUG' (exit $rc, see above)" ;; esac
  [ "$again" != "$REF" ] || stop solve "coder ran but did not close $REF (its report says why)"
  rc=0; bash "$checks_dir/run-checks.sh" --project-root "$ROOT" --main-root "$ROOT" --dep-scripts "$dep_dir" >"$clog" 2>&1 || rc=$?
  [ "$rc" != 3 ] || stop checks "no check commands known (DISCOVER): run /solve-issue or dep-install once by hand and commit .coding-crew/dev-commands.json" "$clog"
  # $REF is closed and committed but not pushed, so a plain re-run would skip it.
  [ "$rc" = 0 ] || stop checks "run-checks.sh exit $rc; once fixed and committed, run land $SLUG $REF $BRANCH before a re-run" "$clog"
  git push -q -u origin "$BRANCH" || stop push "git push failed; once it can push, run land $SLUG $REF $BRANCH before a re-run"
  pr_view
  if [ -z "$PR_N" ]; then
    # describe writes the whole body at the end; until then it only carries the markers address-pr-comments reads.
    f="$LOGS/pr-body.md"
    printf '%s\n' "$BEGIN" "Implemented by solve-feature (\`$SLUG\`) — in progress." "<!-- solve-feature:slug $SLUG -->" "$END" >"$f"
    URL=$(gh pr create --draft --title "$(pr_title "$rs")" --body-file "$f") || die "gh pr create failed"
    PR_N="${URL##*/}"; [[ "$PR_N" =~ ^[0-9]+$ ]] || die "gh pr create printed no PR URL: $URL"
  fi
  echo "pr=$PR_N"
}

# The fixer's edits are staged before the checks and committed after, so the push carries exactly what was gated.
fix() {
  local report="$LOGS/pr-$PR.review.json" unfixed="$LOGS/pr-$PR.unfixed.md" clog="$LOGS/pr-$PR.checks.log"
  local checks_dir dep_dir head_oid prd rc=0 total attention=""
  checks_dir=$(scripts_of solve-issue) dep_dir=$(scripts_of dep-install)
  head_oid=$(gh pr view "$PR" --json headRefOid | jq -r '.headRefOid // empty') || die "gh pr view $PR failed"
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop fix "branch changed to '$(git branch --show-current)'"
  [ -f "$report" ] || stop fix "no review report at $report"
  prd=$(jq -r '.prd // empty' "$report" 2>/dev/null) || stop fix "unreadable review report $report"
  jq -e '.gaps // [] | type == "array"' "$report" >/dev/null || stop fix "the review report's gaps is not a list: $report"
  total=$(jq '.findings // [] | length' "$report")
  # Staged before the checks, so run-checks.sh's modified-files test also sees a check rewrite a file the fixer changed.
  git add -A
  bash "$checks_dir/run-checks.sh" --project-root "$ROOT" --main-root "$ROOT" --dep-scripts "$dep_dir" >"$clog" 2>&1 || rc=$?
  [ "$rc" != 3 ] || stop fix "no check commands known (DISCOVER): run /solve-issue or dep-install once by hand and commit .coding-crew/dev-commands.json" "$clog"
  [ "$rc" = 0 ] || stop fix "run-checks.sh exit $rc; once fixed and committed (not pushed), run fix $SLUG $PR $BRANCH" "$clog"
  git diff --cached --quiet || git commit -q -m "Fix the review's findings on PR #$PR"
  git push -q -u origin "$BRANCH" || stop fix "git push failed; once it can push, run fix $SLUG $PR $BRANCH"

  # Needs a person: the reviewer's gaps, an unmet spec, each line the fixer left in unfixed.md, and a fixer that
  # changed nothing without saying why (it crashed or gave up). "Changed nothing" is HEAD still at the PR's head,
  # which is why the stops say to commit, not push, before a re-run.
  attention=$(jq -r '.gaps // [] | .[] | tostring' "$report")
  [ "$prd" = met ] || attention+=$'\n'"the reviewer found the spec unmet"
  [ ! -f "$unfixed" ] || attention+=$'\n'"$(cat "$unfixed")"
  [ "$total" = 0 ] || [ "$(git rev-parse HEAD)" != "$head_oid" ] || [ -s "$unfixed" ] || attention+=$'\n'"the fixer changed nothing"
  rm -f "$unfixed"
  # describe reads it: an empty file is a review with nothing needing a person.
  grep -v '^[[:space:]]*$' <<<"$attention" >"$LOGS/pr-$PR.attention.md" || true
  echo "FIX: findings=$total needs-attention=$(grep -c . "$LOGS/pr-$PR.attention.md" || true)"
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
