#!/usr/bin/env bash
# solve-feature.sh start|next|land|sync|reviewed|fix|describe — the guards of solve-feature's loop. SKILL.md drives the
# loop and runs each issue's coder (between `next` and `land`), a conflicting merge's resolver (between `sync`'s exit 4
# and its re-run), the review's reviewer (before `reviewed`) and fixer
# (before `fix`) and the PR's writer (before `describe`) as subagents of the host agent; every guard is an exit code here.
#   start <slug> [--branch <name>] | next <slug> | land <slug> <ref> <branch> | sync <slug> <branch>
#   | reviewed <slug> <pr> <branch> | fix <slug> <pr> <branch> | describe <slug> <pr> — each function's comment states its contract.
# Exit: 0 ok; 1 a stop (its one-line result in .coding-crew/solve-feature/outcome); 2 a usage error; 3 from next
# when no ready issue is left; 4 from sync when its merge of the default branch conflicts, left in progress.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS=""
# The run's one-line result, read by a host such as the Actions job; a missing file means it never finished.
# next only reads the tracker, so a stop it writes after another stop is that stop's consequence: it keeps the first.
outcome() {
  [ -n "$LOGS" ] || return 0
  [ "$CMD" = next ] && grep -q '^stopped:' "$LOGS/outcome" 2>/dev/null && return 0
  printf '%s\n' "$1" >"$LOGS/outcome"
}
die() { echo "solve-feature: $*" >&2; outcome "stopped: $CMD failed: $*"; exit 1; }
usage() {
  [ -z "${1:-}" ] || echo "solve-feature: $1" >&2
  echo "usage: solve-feature.sh start <slug> [--branch <name>] | next <slug> | land <slug> <ref> <branch> | sync <slug> <branch> | reviewed <slug> <pr> <branch> | fix <slug> <pr> <branch> | describe <slug> <pr>" >&2; exit 2
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
  sync) [ $# -eq 2 ] || usage; SLUG="$1" BRANCH="$2" ;;
  reviewed) [ $# -eq 3 ] && [[ "$2" =~ ^([0-9]+|local)$ ]] || usage; SLUG="$1" PR="$2" BRANCH="$3" REF=review ;;
  fix) [ $# -eq 3 ] && [[ "$2" =~ ^([0-9]+|local)$ ]] || usage; SLUG="$1" PR="$2" BRANCH="$3" REF=review ;;
  describe) [ $# -eq 2 ] && [[ "$2" =~ ^([0-9]+|local)$ ]] || usage; SLUG="$1" PR="$2" ;;
  *) usage ;;
esac
for t in gh jq node git; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
# The tracker's own SLUG rule: the slug reaches argv, so nothing else gets through.
[[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid feature slug: '$SLUG'"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"; cd "$ROOT"
mkdir -p "$ROOT/.coding-crew/solve-feature" && echo '*' >"$ROOT/.coding-crew/solve-feature/.gitignore" # ignored in any repo, so the tree stays clean
LOGS="$ROOT/.coding-crew/solve-feature"
# The main checkout, as the tracker finds it: its .coding-crew/ files are read from every worktree, committed or not.
MAIN_ROOT=$(git rev-parse --path-format=absolute --git-common-dir)
[ "$(basename "$MAIN_ROOT")" = .git ] && MAIN_ROOT=$(dirname "$MAIN_ROOT") || MAIN_ROOT="$ROOT"
# The setup files a user commits once satisfied: no tree check counts them, and no run commits them. A dev commands
# file this tree tracks is not one: it is the branch's own copy, the one its checks read, counted and committed.
BRANCH_WORK=(. ':!.coding-crew/config.json') SETUP_FILES=(.coding-crew/config.json)
git ls-files --error-unmatch -- .coding-crew/dev-commands.json >/dev/null 2>&1 ||
  { BRANCH_WORK+=(':!.coding-crew/dev-commands.json'); SETUP_FILES+=(.coding-crew/dev-commands.json); }
[ "$CMD" != start ] || rm -f "$LOGS/outcome" "$LOGS"/pr-*.unfixed.md "$LOGS"/pr-*.review.json "$LOGS"/pr-*.summary.md "$LOGS"/pr-*.attention.md "$LOGS"/pr-*.head \
  "$LOGS"/pr-*.discarded.md "$LOGS"/pr-*.notes.md "$LOGS/review.base"
# solveFeature.publish: false keeps the run on this machine: no push, no PR, the body in local_body's file. Read from
# the user-level config only: an Actions runner has none, so it never keeps commits that vanish with the runner.
PUBLISH=yes
[ "$(jq -r '.solveFeature.publish' "$HOME/.coding-crew/config.json" 2>/dev/null || true)" != false ] || PUBLISH=no
# Keyed by branch as `gh pr view "$BRANCH"` is; not pr-body.md, land's draft body in publish mode.
local_body() { echo "$LOGS/local-pr-${BRANCH//\//_}.md"; }
# The issue next handed out for this feature until its land records it: per feature, as runs share this directory.
landing() { echo "$LOGS/landing-$SLUG"; }
# The tracker and checks libraries, in the coding-crew-lib skill installed beside this one.
CLI="$SELF/../../coding-crew-lib/scripts/tracker/cli.mjs" CHECKS="$SELF/../../coding-crew-lib/scripts/checks"
[ -f "$CLI" ] || die "tracker CLI not found ($CLI): install the coding-crew-lib skill beside solve-feature, from the source you installed solve-feature from (npx skills add <that source> -s coding-crew-lib, adding -g at user level) or re-run install.sh"

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

# merge_in [--keep] <ref> — merge <ref> into HEAD unless it is already there, always as a merge commit, so the
# branch's own commits stay its first-parent line. On failure MERGE_CONFLICTS holds the conflicting files (empty when
# git refused for another reason) and it returns 1: the caller decides. The merge is aborted, unless --keep leaves a
# conflicting one in progress for someone to finish.
MERGE_CONFLICTS=""
merge_in() {
  local keep=""; [ "$1" != --keep ] || { keep=1; shift; }
  MERGE_CONFLICTS=""
  ! git merge-base --is-ancestor "$1" HEAD || return 0
  git merge -q --no-ff --no-edit "$1" >&2 && return 0
  MERGE_CONFLICTS=$(git diff --name-only --diff-filter=U | paste -sd' ' -)
  [ -n "$keep" ] && [ -n "$MERGE_CONFLICTS" ] || git merge --abort 2>/dev/null || true
  return 1
}

# fetch_branch — fetch origin's copy of $BRANCH; with PUBLISH=no origin usually has none, which is no error to show.
fetch_branch() { if [ "$PUBLISH" = yes ]; then git fetch -q origin "$BRANCH"; else git fetch -q origin "$BRANCH" 2>/dev/null; fi; }

# default_branch — origin's default branch, as origin/HEAD names it, else main.
default_branch() {
  local d; d=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  echo "${d:-main}"
}

PR_N="" PR_IS_DRAFT=""
pr_view() { # sets PR_N and PR_IS_DRAFT (true|false) when the branch has an OPEN PR, else clears them
  if [ "$PUBLISH" = no ]; then PR_IS_DRAFT=""; PR_N=""; [ ! -f "$(local_body)" ] || PR_N=local; return 0; fi
  local view; view=$(gh pr view "$BRANCH" --json number,state,isDraft 2>/dev/null) || view=""
  PR_N=$(jq -r 'select(.state == "OPEN") | .number' <<<"$view" 2>/dev/null || true)
  PR_IS_DRAFT=$(jq -r 'select(.state == "OPEN") | .isDraft' <<<"$view" 2>/dev/null || true)
}

# pr_body_read <pr> / pr_body_write <pr> <file> [<title>] — the PR body's one store: the PR on GitHub, or with
# PUBLISH=no the branch's local body file, whose first line is `# <title>` so its reader has both.
pr_body_read() {
  # A body a person edited, in the web UI or the local file, can come back with CRLF line endings, which no marker
  # match would see.
  if [ "$PUBLISH" = yes ]; then gh pr view "$1" --json body | jq -r '.body' | tr -d '\r'
  else tail -n +2 "$(local_body)" | tr -d '\r' | sed '1{/^$/d;}'
  fi
}
pr_body_write() {
  local f t="${3:-}"
  if [ "$PUBLISH" = yes ]; then gh pr edit "$1" ${t:+--title "$t"} --body-file "$2" >/dev/null; return; fi
  f=$(local_body)
  [ -n "$t" ] || [ ! -f "$f" ] || t=$(sed -n '1s/^# //p' "$f" | tr -d '\r')
  { printf '# %s\n\n' "$t"; cat "$2"; } >"$f.tmp" && mv "$f.tmp" "$f"
}

# .coding-crew/solve-feature/spec.md, which the reviewer and the PR writer read: the tracker's spec op, the PRD then
# every issue of the feature, open or closed. All of them: an issue another run landed is met in the code, and one
# still open is a gap a person must see.
write_spec() {
  node "$CLI" spec --feature-slug "$SLUG" >"$LOGS/spec.md" || die "spec failed for '$SLUG' (see above)"
}

# die_setup_clash <default> — after a failed checkout or merge: when an untracked setup file is one origin/<default>
# now has, git refused to overwrite it, and only the user can choose which copy to keep.
die_setup_clash() {
  local f
  for f in $(git ls-files --others -- .coding-crew/config.json .coding-crew/dev-commands.json); do
    git cat-file -e "origin/$1:$f" 2>/dev/null || continue
    die "origin/$1 now has $f: compare it with your uncommitted copy, keep one (commit, or move yours aside), then re-run"
  done
}

# model <coder|reviewer> — CREW_CODER_MODEL / CREW_REVIEWER_MODEL, else solveFeature.models.<key> from the project's
# config.json, else the user-level one's, else empty. An empty variable counts as unset: an Actions repo variable that
# does not exist expands to "".
model() {
  local cfg m
  case $1 in coder) m=${CREW_CODER_MODEL:-} ;; reviewer) m=${CREW_REVIEWER_MODEL:-} ;; esac
  [ -z "$m" ] || { echo "$m"; return; }
  for cfg in "$MAIN_ROOT/.coding-crew/config.json" "$HOME/.coding-crew/config.json"; do
    m=$(jq -r --arg k "$1" '.solveFeature.models[$k] | strings' "$cfg" 2>/dev/null || true)
    [ -z "$m" ] || { echo "$m"; return; }
  done
}

# start — preconditions, the branch (--branch, else feature/<slug>), spec.md; prints branch=, coder-model=,
# reviewer-model= and pr= (empty with no open PR).
start() {
  [ -z "$(git status --porcelain -- "${BRANCH_WORK[@]}")" ] || die "working tree is not clean: commit or stash first"
  local features; features=$(node "$CLI" features | cut -f1) || die "features failed (see above)"
  grep -qxF "$SLUG" <<<"$features" || die "no feature '$SLUG'; features: $(paste -sd' ' - <<<"$features")"
  # preflight.sh blocks a coder on the default branch, so the branch comes first. Never reset or rebase
  # an existing one: a re-run lands on it as the last run left it, with the default branch merged in (and land and
  # fix merge in origin's copy of the branch, so a commit someone else pushed there never refuses their push).
  git fetch -q origin || die "git fetch origin failed (see above)"
  local default; default=$(default_branch)
  [ "$BRANCH" != "$default" ] || die "--branch '$BRANCH': '$default' is the default branch; name a feature branch"
  BRANCH=${BRANCH:-feature/$SLUG}
  if git show-ref --verify -q "refs/heads/$BRANCH"; then git checkout -q "$BRANCH"
  elif git show-ref --verify -q "refs/remotes/origin/$BRANCH"; then git checkout -q -t "origin/$BRANCH"
  else git checkout -q -b "$BRANCH" "origin/$default"
  fi || { die_setup_clash "$default"; die "cannot check out $BRANCH (see above)"; }
  # A branch origin lacks is new, or one whose first push was refused: a re-run pushes it before any coder runs.
  [ "$PUBLISH" = no ] || git show-ref --verify -q "refs/remotes/origin/$BRANCH" || push -u origin "$BRANCH" || die "cannot push $BRANCH: $PUSH_WHY"
  # The checks run the branch's own files, so a branch an earlier run left takes the default branch's fixes first.
  local before; before=$(git rev-parse HEAD)
  if ! merge_in "origin/$default"; then
    [ -n "$MERGE_CONFLICTS" ] || die_setup_clash "$default"
    [ -n "$MERGE_CONFLICTS" ] || die "merging origin/$default into $BRANCH failed (see above)"
    die "merging origin/$default into $BRANCH conflicts in $MERGE_CONFLICTS: merge it by hand, $([ "$PUBLISH" = no ] && echo commit || echo "push $BRANCH"), then re-run"
  fi
  [ "$PUBLISH" = no ] || [ "$(git rev-parse HEAD)" = "$before" ] || push origin "$BRANCH" || die "cannot push $BRANCH after merging origin/$default into it: $PUSH_WHY"
  write_spec
  pr_view
  # A ready PR would read as reviewed while coders and the review change it; describe marks it ready again.
  [ -z "$PR_N" ] || [ "$PR_IS_DRAFT" != false ] || gh pr ready "$PR_N" --undo >/dev/null ||
    die "gh pr ready $PR_N --undo failed: run gh pr ready $PR_N --undo by hand, then re-run"
  echo "branch=$BRANCH"
  echo "coder-model=$(model coder)"
  echo "reviewer-model=$(model reviewer)"
  echo "pr=$PR_N"
}

nothing_left() { # exit 3; with no open PR on the branch, the run has nothing to review and stops here
  BRANCH=$(git branch --show-current); pr_view
  if [ -z "$PR_N" ]; then
    echo "solve-feature: nothing landed: no ready issue for $SLUG and no open PR" >&2
    outcome "stopped: next failed: nothing landed: no ready issue for $SLUG and no open PR"
  else
    # Again here, beside the review step: start's line is issues behind by now, and a run lost it once (PR 343).
    echo "reviewer-model=$(model reviewer)"
  fi
  exit 3
}

# next — the next ready issue, saved for land; prints its ref, or exits 3 when none is left (printing reviewer-model=
# when there is a PR to review).
next() {
  local rc=0 ref
  ref=$(node "$CLI" next --feature-slug "$SLUG") || rc=$?
  case $rc in 0|3) ;; *) die "next failed for '$SLUG' (exit $rc, see above)" ;; esac
  # The issue handed out last, cleared once its land records it. Done in the tracker but still named here, it was
  # closed with no land to gate or record it, and the run would skip it as landed.
  local on
  if [ -s "$(landing)" ] && IFS=$'\t' read -r REF on <"$(landing)" && { [ "$rc" = 3 ] || [ "$ref" != "$REF" ]; }; then
    # Landed on the branch its coder committed to: a re-run on another branch would gate a tree without the work.
    on=${on:-$(git branch --show-current)}
    local st src=0 cmds why="$REF is done but its land never finished" todo="land $SLUG $REF $on" go="" rerun="re-run"
    [ "$on" = "$(git branch --show-current)" ] || go="check out $on and " rerun="re-run with --branch $on"
    st=$(node "$CLI" status "$REF") || src=$?
    # Exit 3: the issue is gone (deleted, its file renamed), so there is nothing left to land for it.
    case $src in 0) ;; 3) rm -f "$(landing)" ;; *) die "status $REF failed (see above)" ;; esac
    if [ "$st" = done ]; then
      # shellcheck source=/dev/null
      . "$CHECKS/commands-file.sh" 2>/dev/null && cmds=$(commands_file "$ROOT") && ! commands_field_present "$cmds" test &&
        why="$why and no check commands are known" todo="/setup-coding-crew, then $todo"
      stop land "$why: if its coder finished it, ${go}run $todo; otherwise reopen $REF; then $rerun"
    fi
  fi
  [ "$rc" = 0 ] || nothing_left
  # Saved now, not in land: the local tracker's close moves the file, and fetch then exits 3. fetch runs the
  # backend's validateRef, so a ref it rejects stops here, before it reaches the coder's prompt.
  node "$CLI" fetch "$ref" >"$LOGS/${ref//\//_}.issue.md" || die "fetch $ref failed (see above)"
  # One coder at a time writes its report here; an earlier one's would read as this coder's at land's solve stop.
  rm -f "$LOGS/coder.report.md" "$LOGS/coder.notes.md"
  printf '%s\t%s\n' "$ref" "$(git branch --show-current)" >"$(landing)"
  echo "$ref"
}

# post_notes <pr> <file> <tag> — a non-empty notes file a subagent left for a person goes into the PR body's notes
# section as one block, verbatim under `### <tag>`, then is deleted: only the body keeps it across a stop and a fresh
# runner. The tag is written into the file first, so the file a failed write leaves is ready to add by hand.
post_notes() {
  local n="$1" f="$2" body new why
  [ -s "$f" ] || return 0
  { printf '### %s\n\n' "$3"; cat "$f"; } >"$f.tmp" && mv "$f.tmp" "$f"
  why="adding $f to PR #$n's body failed: add its contents to the PR body's Notes for a person section by hand (gh pr edit $n), then rm $f before a re-run (on Actions the file is in the run's artifact)"
  [ "$PUBLISH" = yes ] || why="adding $f to $(local_body) failed: add its contents to that file's Notes for a person section by hand, then rm $f before a re-run"
  body=$(pr_body_read "$n") || die "$why"
  new="$LOGS/pr-$n.notes-body.md"
  if grep -qxF "$NOTES_END" <<<"$body"; then
    awk -v e="$NOTES_END" -v f="$f" '$0 == e && !d { while ((getline l < f) > 0) print l; print ""; d = 1 } { print }' <<<"$body" >"$new"
  else
    # A new section goes before the slug line address-pr-comments reads, inside begin/end; at the end of a body a
    # person stripped of both, so the note is never dropped.
    awk -v s="<!-- solve-feature:slug " -v e="$END" -v nb="$NOTES_BEGIN" -v ne="$NOTES_END" -v f="$f" '
      function section() {
        print nb; print "## Notes for a person"; print ""; print "Delete a note here once it is handled."; print ""
        while ((getline l < f) > 0) print l; print ""; print ne; d = 1 }
      !d && (index($0, s) == 1 || $0 == e) { section() }
      { print }
      END { if (!d) section() }' <<<"$body" >"$new"
  fi
  pr_body_write "$n" "$new" || die "$why"
  rm -f "$f" "$new"
}

stop() { # <step> <reason> [<log>]; exit 1
  echo "solve-feature: $REF $1 failed: $2${3:+ — log: $3}"
  outcome "stopped: $REF $1 failed: $2"; exit 1
}

# address-pr-comments finds a solve-feature PR by the begin line and reads its slug from the slug line.
BEGIN='<!-- solve-feature:begin -->' END='<!-- solve-feature:end -->'
# The notes section, inside begin/end: post_notes adds to it, describe carries it over verbatim.
NOTES_BEGIN='<!-- solve-feature:notes:begin -->' NOTES_END='<!-- solve-feature:notes:end -->'
pr_title() { # <ref-slug> — the PRD's title when the CLI's note heads the spec, else the issue's own
  local t; t=$(head -n 1 "$LOGS/spec.md" | sed -nE 's/^<!-- PRD issue #[0-9]+: (.*) -->$/\1/p' | sed 's/^PRD: //')
  [ -n "$t" ] || t=$(grep -m1 '^# ' "$LOGS/$1.issue.md" | sed 's/^# //')
  printf '%s' "$t"
}
checks_lib() { [ -f "$CHECKS/run-checks.sh" ] || die "checks library not found ($CHECKS): install the coding-crew-lib skill beside solve-feature, from the source you installed solve-feature from (npx skills add <that source> -s coding-crew-lib, adding -g at user level) or re-run install.sh"; }

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
  [ "$PUBLISH" = yes ] || stop checks "$1; $REF is ready again with its work committed on $BRANCH: $2" "$3"
  push -u origin "$BRANCH" || stop checks "$1; $REF is ready again but git push failed: $PUSH_WHY; once it can push, $2" "$3"
  stop checks "$1; $REF is ready again with its work pushed to $BRANCH: $2" "$3"
}

# pr_create_failed — gh pr create failed on a closed, pushed issue: reopen it, push the reopen's commit (a file
# tracker's), then stop, so a plain re-run's coder takes the issue up and the next land opens the PR.
pr_create_failed() {
  local why redo
  why=$(grep -v '^[[:space:]]*$' "$LOGS/pr-create.err" | tail -1 || true)
  why="gh pr create failed${why:+: $why}"
  redo="fix the cause (on GitHub Actions, the repo's \"Allow GitHub Actions to create and approve pull requests\" setting, under Settings → Actions → General → Workflow permissions), then re-run"
  reopen_ref pr "$why" "Reopen $REF: its PR creation failed" "reopen $REF by hand, then $redo"
  push -u origin "$BRANCH" || stop pr "$why; $REF is ready again but git push failed: $PUSH_WHY; once it can push, $redo"
  stop pr "$why; $REF is ready again with its work pushed to $BRANCH: $redo"
}

# commit_rewrites — after a passing run-checks.sh on a tree clean outside SETUP_FILES, what is left is exactly the
# checks' rewrites (a `lint --fix`): one commit of its own. Tracked files only, as run-checks.sh fails a check that
# creates one. Staged over `.`, then unstaged: git add refuses any pathspec naming an ignored path, an exclude too.
commit_rewrites() {
  git add -u -- . && git reset -q -- "${SETUP_FILES[@]}" || return 1
  git diff --cached --quiet || git commit -q -m "Apply the checks' rewrites"
}

# land — the coder left <branch> clean with <ref> closed: merge in origin's branch, gate with the checks, push,
# open the draft PR if there is none; prints pr=<n>.
land() {
  local rs="${REF//\//_}" rc=0 again clog="$LOGS/${REF//\//_}.checks.log" f url
  [ -f "$LOGS/$rs.issue.md" ] || die "no saved issue for $REF: run next first"
  checks_lib
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop solve "branch changed to '$(git branch --show-current)'"
  [ -z "$(git status --porcelain -- "${BRANCH_WORK[@]}")" ] || stop solve "working tree left dirty$([ ! -s "$LOGS/coder.report.md" ] || echo "; why: $LOGS/coder.report.md")"
  # solve-issue's close moves the issue out of `next`; still first means it stopped short (partial, blocked).
  again=$(node "$CLI" next --feature-slug "$SLUG") || rc=$?
  case $rc in 0|3) ;; *) die "next failed for '$SLUG' (exit $rc, see above)" ;; esac
  if [ "$again" = "$REF" ]; then
    [ -s "$LOGS/coder.report.md" ] || stop solve "coder ran but did not close $REF and left no report at $LOGS/coder.report.md"
    stop solve "coder ran but did not close $REF; why: $LOGS/coder.report.md"
  fi
  # A commit someone else pushed to the branch (a bot, a teammate) is merged before the checks, so the gated tree is
  # the pushed one. A failed fetch skips it: the push owns that failure.
  if fetch_branch && ! merge_in "origin/$BRANCH"; then
    local why="merging origin/$BRANCH into $BRANCH conflicts in $MERGE_CONFLICTS"
    [ -n "$MERGE_CONFLICTS" ] || why="merging origin/$BRANCH into $BRANCH failed (see above)"
    local redo="re-run in a fresh clone, which redoes it on origin's branch, or merge it by hand in this checkout, commit, then re-run"
    # PUBLISH=no: earlier issues' commits exist only here, so a fresh clone would build without them.
    [ "$PUBLISH" = yes ] || redo="merge it by hand in this checkout, commit, then re-run"
    reopen_ref merge "$why" "Reopen $REF: its merge failed" "reopen $REF by hand, then $redo"
    stop merge "$why; $REF is ready again: $redo"
  fi
  rc=0; bash "$CHECKS/run-checks.sh" --project-root "$ROOT" >"$clog" 2>&1 || rc=$?
  [ "$rc" != 3 ] || hand_back "no check commands known (DISCOVER): the coder discovered none" "run /setup-coding-crew, then re-run" "$clog"
  [ "$rc" = 0 ] || hand_back "run-checks.sh exit $rc" "fix the cause, then re-run" "$clog"
  commit_rewrites || hand_back "committing the checks' rewrites failed (see above)" "commit them, then re-run" "$clog"
  # Any failed push reopens the issue, unretried: an Actions runner's commits go with its job, so a closed issue
  # would count as landed work that exists nowhere. Here a re-run finds the commits, since start never resets a branch.
  if [ "$PUBLISH" = yes ] && ! push -u origin "$BRANCH"; then
    local why="git push failed: $PUSH_WHY"
    reopen_ref push "$why" "Reopen $REF: its push failed" "reopen $REF by hand, then re-run where git can push"
    stop push "$why; $REF is ready again: re-run where git can push (a re-run in this checkout starts from its unpushed commits)"
  fi
  pr_view
  if [ -z "$PR_N" ]; then
    # describe writes the whole body at the end; until then it carries the markers address-pr-comments reads and,
    # once a note lands, the notes section.
    f="$LOGS/pr-body.md"
    printf '%s\n' "$BEGIN" "Implemented by solve-feature (\`$SLUG\`) — in progress." "<!-- solve-feature:slug $SLUG -->" "$END" >"$f"
  fi
  if [ -z "$PR_N" ] && [ "$PUBLISH" = no ]; then
    # Reopened like a failed gh pr create: the issue is closed, so a re-run would skip it and never open the body.
    if ! pr_body_write local "$f" "$(pr_title "$rs")"; then
      local why="cannot write $(local_body)"
      reopen_ref pr "$why" "Reopen $REF: writing its local PR body failed" "reopen $REF by hand, then fix the cause and re-run"
      stop pr "$why; $REF is ready again with its work committed on $BRANCH: fix the cause, then re-run"
    fi
    PR_N=local
  elif [ -z "$PR_N" ]; then
    rc=0; url=$(gh pr create --draft --title "$(pr_title "$rs")" --body-file "$f" 2>"$LOGS/pr-create.err") || rc=$?
    cat "$LOGS/pr-create.err" >&2
    [ "$rc" = 0 ] || pr_create_failed
    PR_N="${url##*/}"; [[ "$PR_N" =~ ^[0-9]+$ ]] || die "gh pr create printed no PR URL: $url"
  fi
  # Pushed and on a PR, the issue has landed; a notes stop after this says how to add them by hand.
  rm -f "$(landing)"
  post_notes "$PR_N" "$LOGS/coder.notes.md" "the coder of $REF · $(date +%F)"
  echo "pr=$PR_N"
}

# sync — before the first review: merge origin's default branch (then origin's <branch>) into <branch>, gate a merge with the checks, push it,
# and save HEAD as the head the reviewer starts from. A conflict exits 4 with the merge left in progress, printing
# conflicts=<files>; once someone finishes it, a re-run gates and pushes it. Success is judged here, never from
# whoever resolved it: no merge in progress, a clean tree, the default branch in HEAD.
sync() {
  local default clog="$LOGS/sync.checks.log" rc=0 files before prev
  # Read before any stop below rewrites it: a sync that stopped left a merge, or a fix for its checks, ungated.
  prev=$(cat "$LOGS/outcome" 2>/dev/null || true)
  [ "$(git branch --show-current)" = "$BRANCH" ] || die "branch changed to '$(git branch --show-current)'"
  # Ahead of the clean-tree check, which would otherwise read an unfinished merge as a dirty tree.
  files=$(git diff --name-only --diff-filter=U | paste -sd' ' -)
  if [ -n "$files" ] || git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    [ -n "$files" ] || files=$(git diff --cached --name-only | paste -sd' ' -)
    die "a merge into $BRANCH is still in progress (${files:-no files changed}): finish it (resolve, git add, git commit --no-edit) or undo it with git merge --abort, then re-run"
  fi
  [ -z "$(git status --porcelain -- "${BRANCH_WORK[@]}")" ] || die "working tree is not clean: commit or stash first"
  git fetch -q origin || die "git fetch origin failed (see above)"
  default=$(default_branch)
  before=$(git rev-parse HEAD)
  if ! merge_in --keep "origin/$default"; then
    [ -n "$MERGE_CONFLICTS" ] || die_setup_clash "$default"
    [ -n "$MERGE_CONFLICTS" ] || die "merging origin/$default into $BRANCH failed (see above)"
    # Provisional: the re-call after the resolver overwrites it, so a host whose agent ended here reads a stop.
    local why="merging origin/$default into $BRANCH conflicts in $MERGE_CONFLICTS: the resolver did not finish it; finish it (resolve, git add, git commit --no-edit) or undo it with git merge --abort, then re-run"
    echo "solve-feature: $why" >&2
    outcome "stopped: sync failed: $why"
    echo "conflicts=$MERGE_CONFLICTS"
    exit 4
  fi
  rm -f "$LOGS/outcome"
  # As in land: a commit someone else pushed to the branch would refuse the push, on every re-run. A branch never
  # pushed (PUBLISH=no) has no origin copy to merge.
  if git rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null && ! merge_in "origin/$BRANCH"; then
    [ -n "$MERGE_CONFLICTS" ] || die "merging origin/$BRANCH into $BRANCH failed (see above)"
    die "merging origin/$BRANCH into $BRANCH conflicts in $MERGE_CONFLICTS: merge it by hand, commit, then re-run"
  fi
  # Ungated work is what origin lacks; with nothing pushed, what these merges brought in, or what an earlier sync left.
  local gate=no
  if [ "$PUBLISH" = no ]; then [ "$(git rev-parse HEAD)" = "$before" ] && [[ "$prev" != "stopped: sync failed:"* ]] || gate=yes
  elif ! git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null; then gate=yes
  fi
  if [ "$gate" = yes ]; then
    checks_lib
    bash "$CHECKS/run-checks.sh" --project-root "$ROOT" >"$clog" 2>&1 || rc=$?
    [ "$rc" != 3 ] || die "no check commands known (DISCOVER): run /setup-coding-crew, then re-run"
    [ "$rc" = 0 ] || die "run-checks.sh exit $rc on $BRANCH merged with origin/$default — log: $clog; once fixed and committed, re-run"
    commit_rewrites || die "committing the checks' rewrites failed (see above): commit them, then re-run"
    [ "$PUBLISH" = no ] || push -u origin "$BRANCH" || die "git push failed: $PUSH_WHY; once it can push, or once you have pushed it, re-run"
  fi
  git rev-parse HEAD >"$LOGS/review.base"
}

# The reviewer may run the tests and its own experiments but leaves the tree as it found it; what it left anyway
# (installed dependencies, a commit) is discarded before the fixer runs, so fix never commits it as the fixer's.
reviewed() {
  local base="$LOGS/review.base" report="$LOGS/pr-$PR.review.json" list="$LOGS/pr-$PR.discarded.md" saved paths redo
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop reviewer "branch changed to '$(git branch --show-current)'"
  [ -s "$base" ] || stop reviewer "no saved head at $base: run sync $SLUG $BRANCH first"
  saved=$(cat "$base")
  if [ "$(git rev-parse HEAD)" != "$saved" ] || [ -n "$(git status --porcelain -- "${BRANCH_WORK[@]}")" ]; then
    paths=$({ git diff --name-only "$saved" HEAD; git status --porcelain -uall -- "${BRANCH_WORK[@]}" | cut -c4-; } | sort -u)
    # Written first, so a discard that fails part-way is still flagged once a person finishes it. Added to an earlier
    # round's list, which start alone deletes: describe flags every round's discard.
    touch "$list" && printf '%s\n' "$paths" | sort -u -o "$list" - "$list"
    redo="clean the tree by hand to $saved, then run reviewed $SLUG $PR $BRANCH"
    # Not --hard: that would also revert a person's uncommitted config.json, which BRANCH_WORK leaves out.
    git reset -q "$saved" && git checkout -q -- "${BRANCH_WORK[@]}" || stop reviewer "git reset failed (see above): $redo"
    # No -x: ignored files (dependency dirs, this run's own files) stay. -ff: a nested repository (a clone,
    # a worktree) is the reviewer's too, since start and land require a clean tree; one -f skips it.
    git clean -ffdq -- "${BRANCH_WORK[@]}" || stop reviewer "git clean failed (see above): $redo"
  fi
  [ -f "$report" ] || stop reviewer "no review report at $report"
  jq -e . "$report" >/dev/null 2>&1 || stop reviewer "unreadable review report $report"
  echo "findings=$(jq '.findings // [] | length' "$report")"
}

# The fixer's edits are committed, then what others pushed to the branch merged in (git refuses a merge over staged
# changes), then the checks run on that clean tree, so the push carries exactly what was gated.
# fix — last stdout line `FIX: findings=<k> needs-attention=<a> review-again=yes|no`.
fix() {
  local report="$LOGS/pr-$PR.review.json" unfixed="$LOGS/pr-$PR.unfixed.md" clog="$LOGS/pr-$PR.checks.log"
  local discarded="$LOGS/pr-$PR.discarded.md" headf="$LOGS/pr-$PR.head" head_oid spec rc=0 total severe moved=no again=no attention=""
  local pr_name="PR #$PR" fresh="; or re-run in a fresh clone"
  [ "$PUBLISH" = yes ] || pr_name=$BRANCH fresh=""
  checks_lib
  # The round's first run keeps the PR's head, so a re-run after a person pushed the fix by hand still sees it moved.
  if [ -s "$headf" ]; then head_oid=$(head -n1 "$headf")
  else
    if [ "$PUBLISH" = no ]; then
      head_oid=$(cat "$LOGS/review.base" 2>/dev/null) || die "no saved head at $LOGS/review.base: run sync $SLUG $BRANCH first"
    else
      head_oid=$(gh pr view "$PR" --json headRefOid | jq -r '.headRefOid // empty') || die "gh pr view $PR failed"
    fi
    printf '%s\n' "$head_oid" >"$headf"
  fi
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop fix "branch changed to '$(git branch --show-current)'"
  [ -f "$report" ] || stop fix "no review report at $report"
  spec=$(jq -r '.spec // empty' "$report" 2>/dev/null) || stop fix "unreadable review report $report"
  jq -e '.gaps // [] | type == "array"' "$report" >/dev/null || stop fix "the review report's gaps is not a list: $report"
  total=$(jq '.findings // [] | length' "$report")
  # crew-review's own severity field; a missing or unknown one is not severe.
  severe=$(jq '[.findings // [] | .[]? | select(.severity? | IN("CRITICAL", "HIGH", "MEDIUM"))] | length' "$report")
  # Committed before the checks, so what they leave is their own rewrites, committed apart.
  # Listed by ls-files, not passed to git add: git add exits 1 on any pathspec naming an ignored path, an exclude too.
  git ls-files -z -m -o --exclude-standard -- "${BRANCH_WORK[@]}" | xargs -0 -r git add -A -- ||
    stop fix "git add failed (see above): stage and commit the fixer's edits by hand, then run fix $SLUG $PR $BRANCH, then describe $SLUG $PR"
  git diff --cached --quiet || git commit -q -m "Fix the review's findings$([ "$PUBLISH" = no ] || echo " on PR #$PR")"
  # A failed fetch skips the merge: the push owns that failure.
  if fetch_branch && ! merge_in "origin/$BRANCH"; then
    local why="merging origin/$BRANCH into $BRANCH conflicts in $MERGE_CONFLICTS"
    [ -n "$MERGE_CONFLICTS" ] || why="merging origin/$BRANCH into $BRANCH failed (see above)"
    stop fix "$why; merge it by hand in this checkout, commit, then run fix $SLUG $PR $BRANCH, then describe $SLUG $PR$fresh"
  fi
  bash "$CHECKS/run-checks.sh" --project-root "$ROOT" >"$clog" 2>&1 || rc=$?
  [ "$rc" != 3 ] || stop fix "no check commands known (DISCOVER): run /setup-coding-crew, then re-run" "$clog"
  [ "$rc" = 0 ] || stop fix "run-checks.sh exit $rc; once fixed and committed, run fix $SLUG $PR $BRANCH, then describe $SLUG $PR" "$clog"
  commit_rewrites || stop fix "committing the checks' rewrites failed (see above): commit them, then run fix $SLUG $PR $BRANCH, then describe $SLUG $PR" "$clog"
  [ "$PUBLISH" = no ] || push -u origin "$BRANCH" || stop fix "git push failed: $PUSH_WHY; once it can push, or once you have pushed it, run fix $SLUG $PR $BRANCH, then describe $SLUG $PR"
  git rev-parse HEAD >"$LOGS/review.base"
  post_notes "$PR" "$LOGS/pr-$PR.notes.md" "the fixer of $pr_name's review · $(date +%F)"

  # "Changed nothing" is no commit on the branch's own line past the round's head: what merge_in brought in sits
  # behind a merge's second parent, and a fix committed here and pushed by hand still counts. The checks' rewrites are
  # not the fixer's.
  [ -z "$(git rev-list --first-parent --no-merges --invert-grep --grep="^Apply the checks' rewrites\$" -n1 HEAD "^$head_oid")" ] || moved=yes
  # Needs a person: the reviewer's gaps, an unmet spec, each line the fixer left in unfixed.md, and a fixer that
  # changed nothing without saying why (it crashed or gave up).
  attention=$(jq -r '.gaps // [] | .[] | tostring' "$report")
  # The gaps already name what is unmet; the bare line is for an unmet spec with none named.
  [ "$spec" = met ] || [ -n "$(jq -r '.gaps // [] | .[]' "$report")" ] || attention+=$'\n'"the reviewer found the spec unmet"
  [ ! -f "$unfixed" ] || attention+=$'\n'"$(cat "$unfixed")"
  [ ! -f "$discarded" ] || attention+=$'\n'"the reviewer changed the tree; discarded: $(paste -sd' ' "$discarded")"
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

# unresolved_threads — sets UNRESOLVED to the count of $PR's unresolved review threads, every page, and PR_URL.
UNRESOLVED="" PR_URL=""
unresolved_threads() {
  local pages
  pages=$(gh api graphql --paginate -F owner='{owner}' -F repo='{repo}' -F pr="$PR" -f query='
    query($owner: String!, $repo: String!, $pr: Int!, $endCursor: String) {
      repository(owner: $owner, name: $repo) { pullRequest(number: $pr) { url
        reviewThreads(first: 100, after: $endCursor) { nodes { isResolved } pageInfo { hasNextPage endCursor } } } } }') ||
    die "counting PR $PR's unresolved review threads failed (see above)"
  UNRESOLVED=$(jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved | not)] | length' <<<"$pages") &&
    PR_URL=$(jq -rs '.[0].data.repository.pullRequest.url' <<<"$pages") ||
    die "unreadable review threads for PR $PR"
}

# The whole body, written once at the end. Readiness and the outcome come after it, so a failed write never leaves a
# ready PR with land's one-line body. A re-run rewrites all of it, text a person added included, but the notes
# section, kept as the PR shows it.
describe() {
  local f="$LOGS/pr-$PR.summary.md" att="$LOGS/pr-$PR.attention.md" body="$LOGS/pr-$PR.body.md" title="" refs draft result
  [ -f "$att" ] || die "no review result at $att: run fix $SLUG $PR <branch> first"
  BRANCH=$(git branch --show-current)
  # A review thread still open needs a person as much as fix's list does. Counted on every run, never written into
  # fix's file, so a re-run counts afresh. Without a PR there are none.
  UNRESOLVED=0; [ "$PUBLISH" = no ] || unresolved_threads
  local need; need=$(cat "$att")
  [ "$UNRESOLVED" = 0 ] || need=$(printf '%s\n%s unresolved review threads: %s' "$need" "$UNRESOLVED" "$PR_URL" | grep -v '^[[:space:]]*$')
  refs=$(node "$CLI" closing-refs --feature-slug "$SLUG") || die "closing-refs failed for '$SLUG' (see above)"
  # The spec is named, not copied: spec.md stays for the reviewer, and a person opens the PRD itself.
  local prd_head="" spec_line="Spec: feature \`$SLUG\`"
  [ ! -f "$LOGS/spec.md" ] || prd_head=$(head -n 1 "$LOGS/spec.md")
  [[ ! "$prd_head" =~ ^'<!-- PRD issue #'([0-9]+): ]] || spec_line="Spec: PRD #${BASH_REMATCH[1]}, feature \`$SLUG\`"
  [ ! -f "$f" ] || title=$(head -n 1 "$f" | sed -n 's/^# //p')
  # The notes section as the body holds it now, so a note a person deleted stays deleted; with no note left, none.
  local notes
  notes=$(pr_body_read "$PR") || die "reading PR $PR's body failed"
  notes=$(sed -n "\|^$NOTES_BEGIN\$|,\|^$NOTES_END\$|p" <<<"$notes")
  # Not piped into grep -q: its early exit could fail the first grep under pipefail and drop the notes.
  [ -n "$(grep -vxE "$NOTES_BEGIN|$NOTES_END|## Notes for a person|Delete a note here once it is handled\.|[[:space:]]*" <<<"$notes" || true)" ] || notes=""
  {
    echo "$BEGIN"
    # Written here, not by the writer subagent, so a reviewer always sees that agents wrote this PR.
    printf '> Written by solve-feature (`%s`): its coder, reviewer and fixer were agents; no person has read this body.\n\n' "$SLUG"
    # write-pr's summary minus its title line, which titles the PR instead.
    if [ -f "$f" ]; then if [ -n "$title" ]; then tail -n +2 "$f"; else cat "$f"; fi | sed '/./,$!d'; echo; fi
    if [ -n "$need" ]; then printf '## Needs attention\n\n'; sed '/^- /!s/^/- /' <<<"$need"; echo; fi
    [ -z "$notes" ] || printf '%s\n\n' "$notes"
    printf '%s\n\n' "$spec_line"
    [ -z "$refs" ] || printf '%s\n' "$refs"
    printf '%s\n' "<!-- solve-feature:slug $SLUG -->" "$END"
  } >"$body"
  pr_body_write "$PR" "$body" "$title" || die "writing PR $PR's body failed"
  if [ -n "$need" ]; then result=needs-attention
  elif [ "$PUBLISH" = no ]; then result=ready
  else
    result=ready draft=$(gh pr view "$PR" --json isDraft | jq -r '.isDraft') || die "gh pr view $PR failed"
    [ "$draft" != true ] || gh pr ready "$PR" >/dev/null || die "gh pr ready $PR failed; the body is written, so run gh pr ready $PR by hand"
  fi
  # Without a PR the branch names the result: the person opens the PR from it, with the body in local_body's file.
  [ "$PUBLISH" = yes ] || { outcome "$result branch=$BRANCH"; echo "$result branch=$BRANCH"; return 0; }
  outcome "$result pr=$PR"
  echo "$result pr=$PR"
}

"$CMD"
