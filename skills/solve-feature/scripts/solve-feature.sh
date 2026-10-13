#!/usr/bin/env bash
# solve-feature.sh <slug> [--branch <name>] [--budget <usd>] [--agent <agent>] — run one feature's
# ready-for-agent issues in order on one branch: per issue the coder, the project's checks and the tracker's
# own close; after the first landed issue a draft PR whose body carries the spec; review-pr on it at the end.
# Env: SOLVE_FEATURE_AGENT (the --agent default), SOLVE_FEATURE_HOST (the progress comment's host name).
# Exit: review-pr's code once no ready issue is left (last stdout line: the PR URL); 0 when nothing ever
# landed on the branch; 1 on a stop or a precondition miss.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "solve-feature: $*" >&2; exit 1; }

SLUG="" BRANCH="" BUDGET=10 AGENT="${SOLVE_FEATURE_AGENT:-claude}"
while [ $# -gt 0 ]; do case "$1" in
    --branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --budget) BUDGET="${2:?--budget needs a value}"; shift 2 ;;
    --agent) AGENT="${2:?--agent needs a value}"; shift 2 ;;
    -*) die "unknown flag: $1" ;;
    *) [ -z "$SLUG" ] || die "unexpected argument: $1"; SLUG="$1"; shift ;;
esac; done
# Installed beside this skill (.coding-crew/<skill>/scripts), else user-level, as solve-issue finds dep-install.
scripts_of() { local d; for d in "$SELF/../../$1/scripts" "$HOME/.coding-crew/$1/scripts"; do [ -d "$d" ] && { (cd "$d" && pwd); return; }; done
  die "$1 scripts not found: run install.sh --skill solve-feature"; }
CHECKS_DIR=$(scripts_of solve-issue) DEP_DIR=$(scripts_of dep-install) REVIEW_DIR=$(scripts_of review-pr)
. "$REVIEW_DIR/agent.sh" # the one owner of the coding-agent axis: names, argv, prompt form, stdin, model, log shape
agent_known "$AGENT" || die "unknown agent '$AGENT'"
for t in "$AGENT" gh jq node git timeout; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
# The tracker's own SLUG rule: the slug reaches argv, so nothing else gets through.
[[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid feature slug: '$SLUG'"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"; cd "$ROOT"
COMMON="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" CLI=""
for c in "$ROOT" "$COMMON" "$HOME"; do [ -f "$c/.coding-crew/tracker/cli.mjs" ] && { CLI="$c/.coding-crew/tracker/cli.mjs"; break; }; done
[ -n "$CLI" ] || die "tracker CLI not found (.coding-crew/tracker/cli.mjs): run install.sh"
KIND="$(node "$CLI" config | sed -n 's/^tracker=//p')"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean: commit or stash first"
# DISCOVER needs an agent and a human once; run-checks.sh's own exit 3 guards a file that names no usable command.
[ -f "$ROOT/.coding-crew/dev-commands.json" ] || die "no .coding-crew/dev-commands.json: run /solve-issue or dep-install once by hand and commit it"
CODER_MODEL=$(agent_model "$AGENT" coder)
unset CREW_ORCHESTRATED # solve-issue's Step 7 closes the issue itself: the loop sees `next` move on

# preflight.sh blocks a coder on the default branch, so the branch comes first. Never reset or rebase
# an existing one: a re-run lands on it as the last run left it.
git fetch -q origin
DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
DEFAULT=${DEFAULT:-main} CUR=$(git branch --show-current)
[ -n "$CUR" ] || die "HEAD is detached: check out a branch first"
if [ "$CUR" = "$DEFAULT" ]; then
  BRANCH=${BRANCH:-feature/$SLUG}
  if git show-ref --verify -q "refs/heads/$BRANCH"; then git checkout -q "$BRANCH"
  elif git show-ref --verify -q "refs/remotes/origin/$BRANCH"; then git checkout -q -t "origin/$BRANCH"
  else git checkout -q -b "$BRANCH" "origin/$DEFAULT" && git push -q -u origin "$BRANCH"; fi
else BRANCH=$CUR; fi
LOGS="$ROOT/.solve-feature" PRD_TEXT="" rc=0
mkdir -p "$LOGS" && echo '*' >"$LOGS/.gitignore" # ignored in any repo, so the tree stays clean
node "$CLI" prd --feature-slug "$SLUG" >"$LOGS/prd.md" || rc=$?
case $rc in 0) PRD_TEXT=$(cat "$LOGS/prd.md") ;; 3) rm -f "$LOGS/prd.md" ;; *) die "reading the feature's PRD failed (exit $rc)" ;; esac

# Prepare: the coder's own solve-issue retries a missing dependency with dep-install's recovery prose,
# so a failed install here is a warning, not a stop.
PLOG="$LOGS/prepare.log" rc=0
bash "$DEP_DIR/resolve-mode.sh" --project-root "$ROOT" --main-root "$ROOT" >"$PLOG" 2>&1 || true
MODE=$(sed -n 's/^INSTALL_MODE=//p' "$PLOG" | tail -n 1) SVC=$(sed -n 's/^DOCKER_SERVICE=//p' "$PLOG" | tail -n 1)
if [ "$MODE" = docker ]; then
  bash "$DEP_DIR/docker-install.sh" --project-root "$ROOT" --main-root "$ROOT" ${SVC:+--service "$SVC"} >>"$PLOG" 2>&1 || rc=$?
else bash "$DEP_DIR/host-install.sh" --project-root "$ROOT" --main-root "$ROOT" >>"$PLOG" 2>&1 || rc=$?; fi
case $rc in 0|2) ;; *) echo "solve-feature: warning: prepare failed (exit $rc) — see $PLOG" >&2 ;; esac

PR_N="" URL="" VIEW="" CID="" ROWS="" ROW="" NOTE="" REF="" TAG=""
row() { ROW="$TAG  solve $1  checks $2"; if [ -n "$PR_N" ]; then progress; else echo "$ROW"; fi; }
progress() { # the PR's one solve-feature-progress comment, rewritten whole; a failed write never stops the loop
  [ -n "$PR_N" ] || return 0
  local body list
  body="<!-- solve-feature-progress -->"$'\n'"solve-feature — $SLUG — host ${SOLVE_FEATURE_HOST:-$(hostname 2>/dev/null || uname -n)} — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  body+=$'\n'"$ROWS$ROW${NOTE:+$'\n\n'$NOTE}"
  if [ -z "$CID" ]; then
    list=$(gh api "repos/{owner}/{repo}/issues/$PR_N/comments" --paginate 2>/dev/null) || { echo "solve-feature: warning: progress comment not read" >&2; return 0; }
    CID=$(jq -r '.[] | select(.body | contains("<!-- solve-feature-progress -->")) | .id' <<<"$list" 2>/dev/null | head -1) || CID=""
  fi
  if [ -n "$CID" ]; then gh api -X PATCH "repos/{owner}/{repo}/issues/comments/$CID" -f body="$body" >/dev/null 2>&1
  else CID=$(gh api "repos/{owner}/{repo}/issues/$PR_N/comments" -f body="$body" 2>/dev/null | jq -r '.id // empty'); [ -n "$CID" ]
  fi || echo "solve-feature: warning: progress comment on PR #$PR_N not written" >&2
}
stop() { # <step> <reason> <log>
  NOTE="Stopped at $1: $2"$'\n```\n'"$(agent_log_tail "$AGENT" "$3")"$'\n```'
  case $1 in solve) row ✗ · ;; checks) row ✓ ✗ ;; esac
  echo "solve-feature: $TAG $1 failed: $2 — log: $3"; exit 1
}
assert_tree() { # <step> <log> — the branch and a clean tree
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop "$1" "branch changed to '$(git branch --show-current)'" "$2"
  [ -z "$(git status --porcelain)" ] || stop "$1" "working tree left dirty" "$2"
}

# The PR body: address-pr-comments finds a solve-feature PR by the begin line and reads its slug from the
# slug line; review-pr reads the <details> block as the spec. Text outside the block is a human's and kept.
LIMIT=65536 CUT_LINE="(spec truncated at GitHub's 65,536-character body limit)"
BEGIN='<!-- solve-feature:begin -->' END='<!-- solve-feature:end -->'
pr_title() { # <ref-slug> — the PRD's title when the CLI's note heads the prd output, else the issue's own
  local t; t=$(head -n 1 <<<"$PRD_TEXT" | sed -nE 's/^<!-- PRD issue #[0-9]+: (.*) -->$/\1/p' | sed 's/^PRD: //')
  [ -n "$t" ] || t=$(grep -m1 '^# ' "$LOGS/$1.issue.md" | sed 's/^# //')
  printf '%s' "$t"
}
pr_body() { # <ref> <ref-slug> <existing body> — the whole body, the block rebuilt with this issue appended
  local old="$3" before after old_sections="" title crit sections head tail inner avail
  if [[ "$old" == *"$BEGIN"* && "$old" == *"$END"* ]]; then
    before=$(awk -v b="$BEGIN" '$0 == b {exit} {print}' <<<"$old")
    after=$(awk -v e="$END" 'f {print} $0 == e {f = 1}' <<<"$old")
    old_sections=$(awk -v b="$BEGIN" '$0 == b {blk = 1} blk && /^### / {s = 1} blk && /^<\/details>$/ {s = 0; blk = 0} s' <<<"$old" | grep -vxF "$CUT_LINE" || true)
  else before="$old" after=""; fi
  title=$(grep -m1 '^# ' "$LOGS/$2.issue.md" | sed 's/^# //')
  crit=$(awk '/^## /{f = tolower($0) ~ /^## acceptance criteria/} f' "$LOGS/$2.issue.md")
  sections="$old_sections"
  [[ "$old_sections" == *"### $1 — "* ]] || sections="${old_sections:+$old_sections$'\n\n'}### $1 — $title"$'\n'"$crit"
  head="$BEGIN"$'\n'"Implemented by solve-feature (\`$SLUG\`)."$'\n\n'"<details><summary>Spec</summary>"$'\n\n'
  tail=$'\n</details>\n\n'
  [ "$KIND" != github ] || tail+="$(node "$CLI" closing-refs --feature-slug "$SLUG")"$'\n'
  tail+="<!-- solve-feature:slug $SLUG -->"$'\n'"$END"
  inner="${PRD_TEXT:+$PRD_TEXT$'\n\n'}$sections"$'\n'
  avail=$(( LIMIT - ${#head} - ${#tail} - ${#before} - ${#after} - 4 ))
  if [ "${#inner}" -gt "$avail" ]; then
    avail=$(( avail - ${#CUT_LINE} - 1 )); [ "$avail" -gt 0 ] || avail=0
    inner="${inner:0:$avail}"$'\n'"$CUT_LINE"
  fi
  printf '%s' "${before:+$before$'\n'}$head$inner$tail${after:+$'\n'$after}"
}
pr_view() { # sets PR_N and URL (and VIEW) when the branch has an OPEN PR, else clears them
  VIEW=$(gh pr view "$BRANCH" --json number,state,url,isDraft,body 2>/dev/null) || VIEW=""
  if [ "$(jq -r '.state // empty' <<<"$VIEW" 2>/dev/null || true)" = OPEN ]; then
    PR_N=$(jq -r '.number' <<<"$VIEW") URL=$(jq -r '.url' <<<"$VIEW")
  else PR_N="" URL=""; fi
}
land() { # <ref> <ref-slug> — push, then open the draft PR or rewrite the block of the open one
  git push -q -u origin "$BRANCH"
  local f="$LOGS/$2.pr-body.md"
  pr_view
  if [ -n "$PR_N" ]; then
    pr_body "$1" "$2" "$(jq -r '.body // ""' <<<"$VIEW")" >"$f"
    gh pr edit "$PR_N" --body-file "$f" >/dev/null || die "gh pr edit $PR_N failed"
  else
    pr_body "$1" "$2" "" >"$f"
    URL=$(gh pr create --draft --title "$(pr_title "$2")" --body-file "$f") || die "gh pr create failed"
    PR_N="${URL##*/}"; [[ "$PR_N" =~ ^[0-9]+$ ]] || die "gh pr create printed no PR URL: $URL"
  fi
}

pr_view # a re-run's stop reports on the PR an earlier run (or a human) opened; before one exists, rows go to stdout
while :; do
  rc=0; REF=$(node "$CLI" next --feature-slug "$SLUG") || rc=$?
  case $rc in 0) ;; 3) break ;; *) die "next failed for '$SLUG' (exit $rc, see above)" ;; esac
  # The ref goes into the coder's prompt: only what the CLI itself would accept.
  [[ "$REF" =~ ^[0-9]+$ ]] || { [[ "$REF" =~ ^\.scratch/[A-Za-z0-9._/-]+\.md$ && "$REF" != *..* ]]; } || die "next printed an unusable ref: '$REF'"
  [[ "$REF" =~ ^[0-9]+$ ]] && TAG="#$REF" || TAG="$REF"
  RS=${REF//\//_}
  [ -z "$ROW" ] || ROWS+="$ROW"$'\n'
  LOG="$LOGS/$RS.log" CLOG="$LOGS/$RS.checks.log"
  node "$CLI" fetch "$REF" >"$LOGS/$RS.issue.md" || die "fetch $REF failed (see above)"
  row · ·
  agent_cmd coder "$AGENT" "$CODER_MODEL" "$BUDGET" "$(agent_coder_prompt "$AGENT" "$REF")"
  timeout 60m "${AGENT_ARGV[@]}" <"$AGENT_STDIN_FILE" >"$LOG" 2>&1 || stop solve "coder exited non-zero" "$LOG"
  assert_tree solve "$LOG"
  # solve-issue's close moves the issue out of `next`; still first means it stopped short (partial, blocked).
  rc=0; again=$(node "$CLI" next --feature-slug "$SLUG") || rc=$?
  case $rc in 0|3) ;; *) die "next failed for '$SLUG' (exit $rc, see above)" ;; esac
  [ "$again" != "$REF" ] || stop solve "coder ran but did not close $TAG" "$LOG"
  row ✓ ·
  rc=0; bash "$CHECKS_DIR/run-checks.sh" --project-root "$ROOT" --main-root "$ROOT" --dep-scripts "$DEP_DIR" >"$CLOG" 2>&1 || rc=$?
  [ "$rc" != 3 ] || stop checks "no check commands known (DISCOVER): run /solve-issue or dep-install once by hand and commit .coding-crew/dev-commands.json" "$CLOG"
  [ "$rc" = 0 ] || stop checks "run-checks.sh exit $rc" "$CLOG"
  land "$REF" "$RS"; row ✓ ✓
done

# Finish: a re-run with nothing left to land still reviews the branch's open PR, whoever opened it.
pr_view
[ -n "$PR_N" ] || { echo "solve-feature: nothing landed on $BRANCH: no open PR to review"; exit 0; }
rc=0; REVIEW=$(bash "$REVIEW_DIR/review-pr.sh" "$PR_N" --agent "$AGENT" | grep '^REVIEW:' | tail -n 1) || rc=$?
[ -n "$REVIEW" ] || REVIEW="REVIEW: failed (exit $rc)"
echo "$REVIEW"
NOTE="$REVIEW"$'\n'"PR: $URL"; progress
echo "$URL"
exit "$rc"
