#!/usr/bin/env bash
# solve-feature.sh start|next|land|sync|reviewed|fix|describe — the guards of solve-feature's loop. SKILL.md drives the
# loop and runs each issue's coder (between `next` and `land`), a conflicting merge's resolver (between `sync`'s exit 4
# and its re-run), the review's reviewer (before `reviewed`) and fixer
# (before `fix`) and the PR's writer (before `describe`) as subagents of the host agent; every guard is an exit code here.
#   start <slug> [--branch <name>] [--review-since <sha>] | start --spec <file> --issue <n> [--branch …] [--review-since …]
#   | next <slug> | land <slug> <ref> <branch> | sync <slug> <branch>
#   | reviewed <slug> <pr> <branch> | fix <slug> <pr> <branch> | describe <slug> <pr> — each function's comment states its contract.
# Exit: 0 ok; 1 a stop (its one-line result in .coding-crew/solve-feature/outcome); 2 a usage error; 3 from next
# when no ready issue is left; 4 from sync, or the sync next's exit 3 and land's next run, when its merge of the
# default branch conflicts, left in progress.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS=""
# default_branch — origin's default branch, as origin/HEAD names it, else main.
default_branch() {
  local d; d=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
  echo "${d:-main}"
}
# The run's one-line result, read by a host such as the Actions job; a missing file means it never finished.
# next only reads the tracker, so a stop it writes after another stop is that stop's consequence: it keeps the first.
outcome() {
  [ -n "$LOGS" ] || return 0
  [ "$CMD" = next ] && grep -q '^stopped:' "$LOGS/outcome" 2>/dev/null && return 0
  printf '%s\n' "$1" >"$LOGS/outcome"
  # result.json: the same ending with its evidence, for a host that writes the PR itself. Removed first, so a failed
  # render leaves none rather than an earlier ending's; the failure never changes this ending.
  rm -f "$LOGS/result.json"
  # A stop before its step looked the PR up (a re-run's land, say) still names the open PR; one on the default branch,
  # before start's checkout, has none to look up.
  if [ -z "${PR:-}${PR_N:-}" ] && [ "${PUBLISH:-}" = yes ] && declare -F pr_view >/dev/null; then
    local b; b=$(git branch --show-current 2>/dev/null || true)
    [ -z "$b" ] || [ "$b" = "$(default_branch)" ] || { BRANCH=${BRANCH:-$b}; pr_view; }
  fi
  node "$SELF/result.mjs" --logs "$LOGS" --slug "$SLUG" --cli "${CLI:-}" --default "$(default_branch)" --publish "${PUBLISH:-yes}" --pr "${PR:-${PR_N:-}}" --main-root "$MAIN_ROOT" ||
    echo "solve-feature: writing $LOGS/result.json failed (see above)" >&2
}
# notes_named — on a stop, where the run's notes for a person are: a stop writes no PR body, so only that file has them.
notes_named() {
  [ -n "$LOGS" ] && [ -n "$SLUG" ] && [ -s "$LOGS/notes-$SLUG.json" ] || return 0
  echo "solve-feature: the run's notes for a person are in $LOGS/notes-$SLUG.json" >&2
}
die() { echo "solve-feature: $*" >&2; notes_named; outcome "stopped: $CMD failed: $*"; exit 1; }
usage() {
  [ -z "${1:-}" ] || echo "solve-feature: $1" >&2
  echo "usage: solve-feature.sh start <slug> [--branch <name>] [--review-since <sha>] | next <slug> | land <slug> <ref> <branch> | sync <slug> <branch> | reviewed <slug> <pr> <branch> | fix <slug> <pr> <branch> | describe <slug> <pr> | start --spec <file> --issue <n> [--branch <name>] [--review-since <sha>]" >&2; exit 2
}

CMD="${1:-}"; [ $# -eq 0 ] || shift
SLUG="" BRANCH="" REF="" PR="" SINCE="" SPEC="" ISSUE=""
case "$CMD" in
  start) while [ $# -gt 0 ]; do case "$1" in
      --branch) [ $# -ge 2 ] || usage "--branch needs a value"; BRANCH="$2"; shift 2 ;;
      --review-since) [ $# -ge 2 ] && [ -n "$2" ] || usage "--review-since needs a value"; SINCE="$2"; shift 2 ;;
      --spec) [ $# -ge 2 ] && [ -n "$2" ] || usage "--spec needs a value"; SPEC="$2"; shift 2 ;;
      --issue) [ $# -ge 2 ] || usage "--issue needs a value"; ISSUE="$2"; shift 2 ;;
      -*) usage "unknown flag: $1" ;;
      *) [ -z "$SLUG" ] || usage "unexpected argument: $1"; SLUG="$1"; shift ;;
    esac; done
    if [ -n "$SPEC$ISSUE" ]; then
      [ -n "$SPEC" ] && [ -n "$ISSUE" ] || usage "--spec and --issue go together"
      [ -z "$SLUG" ] || usage "--spec takes no feature slug: the feature is issue-<n>"
      # <n> reaches a path and argv.
      [[ "$ISSUE" =~ ^[0-9]+$ ]] || usage "--issue '$ISSUE' is not a number"
      SLUG="issue-$ISSUE"
      case "$SPEC" in /*) ;; *) SPEC="$PWD/$SPEC" ;; esac # before the cd to the top level below
    fi ;;
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
# A spec kept in $LOGS itself: start and the later steps delete or rewrite its files, so it is refused. The stop
# writes its outcome and result.json unless the spec is one of them.
if [ -n "$SPEC" ] && [ -d "$(dirname "$SPEC")" ] && [ "$(cd "$(dirname "$SPEC")" && pwd -P)" = "$(cd "$LOGS" && pwd -P)" ]; then
  case "$(basename "$SPEC")" in outcome | result.json) LOGS="" ;; esac
  die "--spec $SPEC is in this run's own directory, whose files start deletes or a later step rewrites: keep the spec outside the checkout or in an ignored path elsewhere"
fi
# The setup files a user commits once satisfied: no tree check counts them, and no run commits them. A dev commands
# file this tree tracks is not one: it is the branch's own copy, the one its checks read, counted and committed.
BRANCH_WORK=(. ':!.coding-crew/config.json') SETUP_FILES=(.coding-crew/config.json)
git ls-files --error-unmatch -- .coding-crew/dev-commands.json >/dev/null 2>&1 ||
  { BRANCH_WORK+=(':!.coding-crew/dev-commands.json'); SETUP_FILES+=(.coding-crew/dev-commands.json); }
[ "$CMD" != start ] || rm -f "$LOGS/outcome" "$LOGS/result.json" "$LOGS/spec.md" "$LOGS"/pr-*.r[0-9]*.* "$LOGS"/*.checks.head "$LOGS"/pr-*.unfixed.json "$LOGS"/pr-*.review.json "$LOGS"/pr-*.summary.md "$LOGS"/pr-*.summary.json "$LOGS"/pr-*attention.json "$LOGS"/pr-*.head \
  "$LOGS"/pr-*.discarded.md "$LOGS"/pr-*.notes.md "$LOGS"/pr-*.coder-notes.json "$LOGS"/pr-*.prev-fixer-note.md "$LOGS/review.base" "$LOGS/review.since"
# solveFeature.publish: false keeps the run on this machine: no push, no PR, the body in local_body's file. Read from
# the user-level config only: an Actions runner has none, so it never keeps commits that vanish with the runner.
# CREW_PUBLISH=false does the same for a host that pushes the commits itself and has no user config to write.
PUBLISH=yes
[ "$(jq -r '.solveFeature.publish' "$HOME/.coding-crew/config.json" 2>/dev/null || true)" != false ] || PUBLISH=no
[ "${CREW_PUBLISH:-}" != false ] || PUBLISH=no
# Keyed by branch as `gh pr view "$BRANCH"` is; not pr-body.md, land's draft body in publish mode.
local_body() { echo "$LOGS/local-pr-${BRANCH//\//_}.md"; }
# The issue next handed out for this feature until its land records it: per feature, as runs share this directory.
landing() { echo "$LOGS/landing-$SLUG"; }
# The run's notes for a person, per feature for the same reason, written only here:
# [{author: coder|fixer, ref?, round?, text, settled?, why?, rendered?}]. describe renders the PR body's notes from it.
notes_file() { echo "$LOGS/notes-$SLUG.json"; }
# notes_edit <jq args…> <filter> — rewrites the notes file through <filter>, read as [] when absent; an empty result
# removes it.
notes_edit() {
  local f tmp; f=$(notes_file); tmp="$f.tmp"
  jq "$@" <(if [ -s "$f" ]; then cat "$f"; else echo '[]'; fi) >"$tmp" || { rm -f "$tmp"; return 1; }
  if [ "$(jq length "$tmp")" = 0 ]; then rm -f "$f" "$tmp"; else mv "$tmp" "$f"; fi
}
# The text a subagent's notes file holds, blank lines around it trimmed; empty for an absent or blank file.
NOTE_TEXT='$t | sub("^(\\s*\n)+"; "") | sub("\\s+$"; "")'
# The tracker and checks libraries, in the coding-crew-lib skill installed beside this one.
CLI="$SELF/../../coding-crew-lib/scripts/tracker/cli.mjs" CHECKS="$SELF/../../coding-crew-lib/scripts/checks"
[ -f "$CLI" ] || die "tracker CLI not found ($CLI): install the coding-crew-lib skill beside solve-feature, from the source you installed solve-feature from (npx skills add <that source> -s coding-crew-lib, adding -g at user level) or re-run install.sh"

# push <git push args> — `git push -q`; on failure sets PUSH_WHY to git's reason and returns 1. git's stderr still
# reaches the terminal. The reason: a rejected ref's parenthesised one (GitHub's workflow-permission refusal arrives
# there), else git's last fatal:/error: line, else its last non-empty one (a network failure ends in advice). With
# PUBLISH=no it pushes nothing and succeeds.
PUSH_WHY=""
push() {
  [ "$PUBLISH" = yes ] || return 0
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

# pr_open <rs> <body-file> — opens $REF's draft PR with <body-file>, or with PUBLISH=no writes the local body file;
# sets PR_N to the PR's number or `local`. A failure reopens $REF, as the issue is closed and a re-run would skip it.
pr_open() {
  local rc=0 url
  if [ "$PUBLISH" = no ]; then
    if ! pr_body_write local "$2" "$(pr_title "$1")"; then
      local why="cannot write $(local_body)"
      reopen_ref pr "$why" "Reopen $REF: writing its local PR body failed" "reopen $REF by hand, then fix the cause and re-run"
      stop pr "$why; $REF is ready again with its work committed on $BRANCH: fix the cause, then re-run"
    fi
    PR_N=local; return 0
  fi
  url=$(gh pr create --draft --title "$(pr_title "$1")" --body-file "$2" 2>"$LOGS/pr-create.err") || rc=$?
  cat "$LOGS/pr-create.err" >&2
  [ "$rc" = 0 ] || pr_create_failed
  PR_N="${url##*/}"; [[ "$PR_N" =~ ^[0-9]+$ ]] || die "gh pr create printed no PR URL: $url"
}

# pr_head <pr> — sets PR_HEAD to the head a fix round starts from: the PR's head, or with PUBLISH=no the one sync saved.
PR_HEAD=""
pr_head() {
  if [ "$PUBLISH" = no ]; then
    PR_HEAD=$(cat "$LOGS/review.base" 2>/dev/null) || die "no saved head at $LOGS/review.base: run sync $SLUG $BRANCH first"
  else
    PR_HEAD=$(gh pr view "$1" --json headRefOid | jq -r '.headRefOid // empty') || die "gh pr view $1 failed"
  fi
}

# pr_ready <pr> — marks the PR ready for review when it is a draft; with PUBLISH=no there is no PR, so nothing.
pr_ready() {
  [ "$PUBLISH" = yes ] || return 0
  local draft
  draft=$(gh pr view "$1" --json isDraft | jq -r '.isDraft') || die "gh pr view $1 failed"
  [ "$draft" != true ] || gh pr ready "$1" >/dev/null || die "gh pr ready $1 failed; the body is written, so run gh pr ready $1 by hand"
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

# publish_spec — --spec's file as the one-issue local feature $SLUG (publish-spec.sh). An earlier run's landing record
# goes with the feature it rebuilds, or next would read the rebuilt issue as closed but never landed.
publish_spec() {
  local why drafts rc=0
  # A fresh directory, so clearing it can never delete the spec a host keeps under $LOGS.
  drafts=$(mktemp -d "$LOGS/spec-drafts.XXXXXX") || die "cannot create a drafts directory in $LOGS (see above)"
  why=$(bash "$SELF/publish-spec.sh" --cli "$CLI" --main-root "$MAIN_ROOT" --drafts "$drafts" --slug "$SLUG" --spec "$SPEC") || rc=$?
  rm -rf "$drafts"
  [ "$rc" = 0 ] || die "${why:-publishing $SPEC failed (see above)}"
  rm -f "$(landing)"
}

# earlier_notes — the text of the open PR's (or local body's) notes, settled and earlier sections, verbatim but for their
# markers and headings, into earlier-<slug>.md, which describe renders as one flat section: a note a person deleted
# stays deleted, and no heading nests per run. With PUBLISH=no only the local body file is read, never a host's PR.
earlier_notes() {
  local e="$LOGS/earlier-$SLUG.md" body
  rm -f "$e"
  [ -n "$PR_N" ] || return 0
  body=$(pr_body_read "$PR_N") || die "reading the body of $([ "$PUBLISH" = yes ] && echo "PR #$PR_N" || local_body) for its earlier notes failed (see above)"
  # Any solve-feature marker ends a section, so a section a person stripped of its end marker stops at the next one.
  awk -v nb="$NOTES_BEGIN" -v sb="$SETTLED_BEGIN" -v eb="$EARLIER_BEGIN" '
    index($0, "<!-- solve-feature:") == 1 { on = ($0 == nb || $0 == sb || $0 == eb); next }
    on && $0 != "## Notes for a person" && $0 != "## Settled by the review" && $0 != "## Earlier runs'"'"' notes" &&
      $0 != "Delete a note here once it is handled." { print }' <<<"$body" | cat -s >"$e"
  grep -q '[^[:space:]]' "$e" || rm -f "$e"
}

# start — preconditions, --spec's feature, the branch (--branch, else feature/<slug>), spec.md, --review-since's
# commit for sync; prints slug= (with --spec), branch=, coder-model=, reviewer-model= and pr= (empty with no open PR).
start() {
  # What an earlier describe rendered is in the body now, which earlier_notes copies; the rest a stop left unrendered.
  # First, so a stop of this start lists none of them in its result.json.
  notes_edit 'map(select(.rendered != true))' || die "dropping the rendered notes from $(notes_file) failed (see above)"
  [ -z "$(git status --porcelain -- "${BRANCH_WORK[@]}")" ] || die "working tree is not clean: commit or stash first"
  [ -z "$SPEC" ] || publish_spec
  local features; features=$(node "$CLI" features | cut -f1) || die "features failed (see above)"
  grep -qxF "$SLUG" <<<"$features" || die "no feature '$SLUG'; features: $(paste -sd' ' - <<<"$features")"
  # preflight.sh blocks a coder on the default branch, so the branch comes first. Never reset or rebase
  # an existing one: a re-run lands on it as the last run left it, with the default branch merged in (and land and
  # fix merge in origin's copy of the branch, so a commit someone else pushed there never refuses their push).
  git fetch -q origin || die "git fetch origin failed (see above)"
  if [ -n "$SINCE" ]; then
    local since; since=$(git rev-parse -q --verify "$SINCE^{commit}") || die "--review-since '$SINCE' is not a commit here or on origin"
    echo "$since" >"$LOGS/review.since"
  fi
  local default; default=$(default_branch)
  [ "$BRANCH" != "$default" ] || die "--branch '$BRANCH': '$default' is the default branch; name a feature branch"
  BRANCH=${BRANCH:-feature/$SLUG}
  if git show-ref --verify -q "refs/heads/$BRANCH"; then git checkout -q "$BRANCH"
  elif git show-ref --verify -q "refs/remotes/origin/$BRANCH"; then git checkout -q -t "origin/$BRANCH"
  else git checkout -q -b "$BRANCH" "origin/$default"
  fi || { die_setup_clash "$default"; die "cannot check out $BRANCH (see above)"; }
  # A branch origin lacks is new, or one whose first push was refused: a re-run pushes it before any coder runs.
  git show-ref --verify -q "refs/remotes/origin/$BRANCH" || push -u origin "$BRANCH" || die "cannot push $BRANCH: $PUSH_WHY"
  # The checks run the branch's own files, so a branch an earlier run left takes the default branch's fixes first.
  local before; before=$(git rev-parse HEAD)
  if ! merge_in "origin/$default"; then
    [ -n "$MERGE_CONFLICTS" ] || die_setup_clash "$default"
    [ -n "$MERGE_CONFLICTS" ] || die "merging origin/$default into $BRANCH failed (see above)"
    die "merging origin/$default into $BRANCH conflicts in $MERGE_CONFLICTS: merge it by hand, $([ "$PUBLISH" = no ] && echo commit || echo "push $BRANCH"), then re-run"
  fi
  [ "$(git rev-parse HEAD)" = "$before" ] || push origin "$BRANCH" || die "cannot push $BRANCH after merging origin/$default into it: $PUSH_WHY"
  write_spec
  pr_view
  earlier_notes
  # A ready PR would read as reviewed while coders and the review change it; describe marks it ready again.
  [ -z "$PR_N" ] || [ "$PR_IS_DRAFT" != false ] || gh pr ready "$PR_N" --undo >/dev/null ||
    die "gh pr ready $PR_N --undo failed: run gh pr ready $PR_N --undo by hand, then re-run"
  [ -z "$SPEC" ] || echo "slug=$SLUG"
  echo "branch=$BRANCH"
  echo "coder-model=$(model coder)"
  echo "reviewer-model=$(model reviewer)"
  echo "pr=$PR_N"
}

# nothing_left — exit 3 (land: next-exit=3, exit 0); with no open PR on the branch, the run has nothing to review and
# stops here; with one, it syncs the branch for the review, as sync does.
nothing_left() {
  BRANCH=$(git branch --show-current); pr_view
  if [ -z "$PR_N" ]; then
    echo "solve-feature: nothing landed: no ready issue for $SLUG and no open PR" >&2
    outcome "stopped: next failed: nothing landed: no ready issue for $SLUG and no open PR"
  else
    # For the reviewer's prompt: the red files of this feature's issues, never another feature's in this directory.
    local red; red=$(node "$SELF/result.mjs" --logs "$LOGS" --slug "$SLUG" --main-root "$MAIN_ROOT" --red-files yes) ||
      die "listing the red-evidence files failed (see above)"
    echo "red-files=$(paste -sd, - <<<"$red" | sed 's/,/, /g')"
    # Again here, beside the review step: start's line is issues behind by now, and a run lost it once (PR 343).
    echo "reviewer-model=$(model reviewer)"
    # As sync: its stops and its exit 4 read as sync's.
    CMD=sync; sync; CMD=next
  fi
  [ "$IN_LAND" = yes ] || exit 3
  echo "next-exit=3"; exit 0
}

# next — the next ready issue, saved for land; prints its ref (land: next=<ref>), or exits 3 when none is left
# (printing reviewer-model= and sync's review-base= when there is a PR to review).
IN_LAND=no
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
  # Its notes go with it, unless this is the same issue again, whose coder keeps, edits or drops them.
  # Its red lines are this dispatch's coder's, and the ref is kept for result.json, which knows issues by spec id.
  rm -f "$LOGS/coder.report.md" "$LOGS/${ref//\//_}.red.md"
  [ "$ref" = "$REF" ] || rm -f "$LOGS/coder.notes.md"
  printf '%s\n' "$ref" >"$LOGS/${ref//\//_}.ref"
  printf '%s\t%s\n' "$ref" "$(git branch --show-current)" >"$(landing)"
  if [ "$IN_LAND" = yes ]; then echo "next=$ref"; else echo "$ref"; fi
}

stop() { # <step> <reason> [<log>]; exit 1
  echo "solve-feature: $REF $1 failed: $2${3:+ — log: $3}"
  notes_named
  outcome "stopped: $REF $1 failed: $2"; exit 1
}

# address-pr-comments finds a solve-feature PR by the begin line and reads its slug from the slug line.
BEGIN='<!-- solve-feature:begin -->' END='<!-- solve-feature:end -->'
# describe's sections for a person, inside begin/end, each rendered from the notes file (the earlier one from
# earlier-<slug>.md): this run's standing notes, the ones the review settled, and earlier runs' notes, a record only.
NOTES_BEGIN='<!-- solve-feature:notes:begin -->' NOTES_END='<!-- solve-feature:notes:end -->'
SETTLED_BEGIN='<!-- solve-feature:settled:begin -->' SETTLED_END='<!-- solve-feature:settled:end -->'
EARLIER_BEGIN='<!-- solve-feature:earlier:begin -->' EARLIER_END='<!-- solve-feature:earlier:end -->'
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
  redo="fix the cause (on GitHub Actions, the setting coding-crew's guide names under \"solve-feature on GitHub Actions\"), then re-run"
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

# discard_rewrites — after a failed run-checks.sh on the same clean tree, what is left is the checks' own output,
# which a re-run makes again: dropped, so the stop leaves the clean tree a re-run starts from. Named in the checks'
# log ($clog, the caller's), which the stop names. reset first: checkout restores from the index, where a check that
# stages (lint-staged) leaves its output for the reopen commit to take. -ff: a nested repository a check made is its
# output too, and one -f skips it. A failed discard is noted there and never skips that stop.
discard_rewrites() {
  local left; left=$(git status --porcelain -uall -- "${BRANCH_WORK[@]}" | cut -c4-)
  [ -n "$left" ] || return 0
  printf "solve-feature: discarded what the failed checks left, which a re-run makes again:\n%s\n" "$left" >>"$clog"
  git reset -q -- "${BRANCH_WORK[@]}" && git checkout -q -- "${BRANCH_WORK[@]}" && git clean -ffdq -- "${BRANCH_WORK[@]}" ||
    echo "solve-feature: discarding them failed (see above): clean the tree by hand before a re-run" >>"$clog"
}

# gate <fail> <log> [<ungated>] — merge origin's copy of the branch in, run the checks into <log>, commit their
# rewrites, push. A failure calls `<fail> <stage> <why>`, stage merge|discover|checks|rewrites|push, which stops; the
# caller's stops are its own. <ungated>, run after the merge, returning non-zero skips the rest: nothing new to gate.
# A failed fetch skips the merge: the push owns that failure.
gate() {
  local fail=$1 clog=$2 rc=0 why
  if fetch_branch && ! merge_in "origin/$BRANCH"; then
    why="merging origin/$BRANCH into $BRANCH conflicts in $MERGE_CONFLICTS"
    [ -n "$MERGE_CONFLICTS" ] || why="merging origin/$BRANCH into $BRANCH failed (see above)"
    "$fail" merge "$why"
  fi
  [ -z "${3:-}" ] || "$3" || return 0
  checks_lib
  bash "$CHECKS/run-checks.sh" --project-root "$ROOT" >"$clog" 2>&1 || rc=$?
  [ "$rc" = 0 ] || discard_rewrites
  [ "$rc" != 3 ] || "$fail" discover "no check commands known (DISCOVER)"
  [ "$rc" = 0 ] || "$fail" checks "run-checks.sh exit $rc"
  commit_rewrites || "$fail" rewrites "committing the checks' rewrites failed (see above)"
  push -u origin "$BRANCH" || "$fail" push "git push failed: $PUSH_WHY"
}

# land_failed <stage> <why> — gate's stops for land: the closed $REF is reopened, so it never counts as landed.
land_failed() {
  local redo
  case $1 in
    merge)
      redo="re-run in a fresh clone, which redoes it on origin's branch, or merge it by hand in this checkout, commit, then re-run"
      # PUBLISH=no: earlier issues' commits exist only here, so a fresh clone would build without them.
      [ "$PUBLISH" = yes ] || redo="merge it by hand in this checkout, commit, then re-run"
      reopen_ref merge "$2" "Reopen $REF: its merge failed" "reopen $REF by hand, then $redo"
      stop merge "$2; $REF is ready again: $redo" ;;
    discover) hand_back "$2: the coder discovered none" "run /setup-coding-crew, then re-run" "$clog" ;;
    checks) hand_back "$2" "fix the cause, then re-run" "$clog" ;;
    rewrites) hand_back "$2" "commit them, then re-run" "$clog" ;;
    push)
      # Any failed push reopens the issue, unretried: an Actions runner's commits go with its job, so a closed issue
      # would count as landed work that exists nowhere. Here a re-run finds the commits, since start never resets a branch.
      reopen_ref push "$2" "Reopen $REF: its push failed" "reopen $REF by hand, then re-run where git can push"
      stop push "$2; $REF is ready again: re-run where git can push (a re-run in this checkout starts from its unpushed commits)" ;;
  esac
}

# land — the coder left <branch> clean with <ref> closed: merge in origin's branch, gate with the checks, push,
# open the draft PR if there is none; prints pr=<n>, then runs next as next alone does, its stops and exits included.
land() {
  local rs="${REF//\//_}" rc=0 again clog="$LOGS/${REF//\//_}.checks.log" f checked
  [ -f "$LOGS/$rs.issue.md" ] || die "no saved issue for $REF: run next first"
  checks_lib
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop solve "branch changed to '$(git branch --show-current)'"
  # Recorded before any stop below, so the stop's result.json has it. The file stays: a re-run's land for the same
  # issue replaces the entry with what its coder left there, and drops it when the coder left none.
  notes_edit --arg ref "$REF" --rawfile t <([ ! -f "$LOGS/coder.notes.md" ] || cat "$LOGS/coder.notes.md") "($NOTE_TEXT) as \$x"'
    | map(select(.author != "coder" or .ref != $ref)) as $rest
    | if $x == "" then $rest
      elif any(.[]; .author == "coder" and .ref == $ref) then map(if .author == "coder" and .ref == $ref then {author, ref, text: $x} else . end)
      else . + [{author: "coder", ref: $ref, text: $x}] end' || die "recording $LOGS/coder.notes.md in $(notes_file) failed (see above)"
  [ -z "$(git status --porcelain -- "${BRANCH_WORK[@]}")" ] || stop solve "working tree left dirty$([ ! -s "$LOGS/coder.report.md" ] || echo "; why: $LOGS/coder.report.md")"
  # solve-issue's close moves the issue out of `next`; still first means it stopped short (partial, blocked).
  again=$(node "$CLI" next --feature-slug "$SLUG") || rc=$?
  case $rc in 0|3) ;; *) die "next failed for '$SLUG' (exit $rc, see above)" ;; esac
  if [ "$again" = "$REF" ]; then
    [ -s "$LOGS/coder.report.md" ] || stop solve "coder ran but did not close $REF and left no report at $LOGS/coder.report.md"
    stop solve "coder ran but did not close $REF; why: $LOGS/coder.report.md"
  fi
  # The commit the checks passed on is recorded once the issue has landed: a stop below reopens it, unlanded.
  rm -f "$LOGS/$rs.checks.head"
  # A commit someone else pushed to the branch (a bot, a teammate) is merged before the checks, so the gated tree is
  # the pushed one.
  gate land_failed "$clog"
  checked=$(git rev-parse HEAD)
  pr_view
  if [ -z "$PR_N" ]; then
    # describe writes the whole body at the end; until then it carries the markers address-pr-comments reads.
    f="$LOGS/pr-body.md"
    printf '%s\n' "$BEGIN" "Implemented by solve-feature (\`$SLUG\`) — in progress." "<!-- solve-feature:slug $SLUG -->" "$END" >"$f"
    pr_open "$rs" "$f"
  fi
  # Pushed and on a PR, the issue has landed.
  rm -f "$(landing)"
  printf '%s\n' "$checked" >"$LOGS/$rs.checks.head"
  echo "pr=$PR_N"
  # next's REF is the issue its landing file names, which land just removed.
  CMD=next REF="" IN_LAND=yes; next
}

# sync_failed <stage> <why> — gate's stops for sync.
sync_failed() {
  case $1 in
    merge) [ -z "$MERGE_CONFLICTS" ] || die "$2: merge it by hand, commit, then re-run"; die "$2" ;;
    discover) die "$2: run /setup-coding-crew, then re-run" ;;
    checks) die "$2 on $BRANCH merged with origin/$default — log: $clog; once fixed and committed, re-run" ;;
    rewrites) die "$2: commit them, then re-run" ;;
    push) die "$2; once it can push, or once you have pushed it, re-run" ;;
  esac
}
# sync_ungated — whether the branch holds work no check has gated: what origin lacks; with nothing pushed, what
# sync's merges brought in, or what an earlier sync that stopped left. sync_failed and it read sync's locals.
sync_ungated() {
  if [ "$PUBLISH" = no ]; then ! { [ "$(git rev-parse HEAD)" = "$before" ] && [[ "$prev" != "stopped: sync failed:"* ]]; }
  else ! git merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null
  fi
}

# sync — before the first review: merge origin's default branch (then origin's <branch>) into <branch>, gate a merge with the checks, push it,
# and save HEAD as the head the reviewer starts from. Prints review-base=: start's --review-since commit when origin's
# default branch is in it and it is in HEAD, else empty — an older base would put the merged-in default branch's
# commits under review, for the fixer to change. A conflict exits 4 with the merge left in progress, printing
# conflicts=<files>; once someone finishes it, a re-run gates and pushes it. Success is judged here, never from
# whoever resolved it: no merge in progress, a clean tree, the default branch in HEAD.
sync() {
  local default clog="$LOGS/sync.checks.log" files before prev
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
  rm -f "$LOGS/outcome" "$LOGS/result.json"
  # As in land: a commit someone else pushed to the branch would refuse the push, on every re-run.
  gate sync_failed "$clog" sync_ungated
  git rev-parse HEAD >"$LOGS/review.base"
  # This run's coder notes still standing, for the reviewer to judge; fix reads its report's indices against this list.
  pr_view
  [ -z "$PR_N" ] || coder_notes "$LOGS/pr-$PR_N.coder-notes.json" || die "listing the coder notes of $(notes_file) failed (see above)"
  local since; since=$(cat "$LOGS/review.since" 2>/dev/null || true)
  if [ -n "$since" ] && git merge-base --is-ancestor "origin/$default" "$since" 2>/dev/null &&
    git merge-base --is-ancestor "$since" HEAD 2>/dev/null; then echo "review-base=$since"
  else echo "review-base="
  fi
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
  # When a fixer note stands (an earlier round's, or one a stopped fix left for this re-run), for this round's fixer
  # to keep, edit or drop: its fix replaces every fixer entry.
  local prev="$LOGS/pr-$PR.prev-fixer-note.md"
  rm -f "$prev"
  if [ -s "$(notes_file)" ]; then
    jq -j '[.[] | select(.author == "fixer")][0].text // empty' "$(notes_file)" >"$prev" || stop reviewer "reading $(notes_file) failed (see above)"
    if [ -s "$prev" ]; then echo "fixer-note=$prev"; else rm -f "$prev"; fi
  fi
  echo "findings=$(jq '.findings // [] | length' "$report")"
}

# coder_notes <file> — the standing coder notes' texts as a JSON list, crew-review's notes input; none, no file.
coder_notes() {
  jq '[.[] | select(.author == "coder" and .settled != true) | .text]' <(if [ -s "$(notes_file)" ]; then cat "$(notes_file)"; else echo '[]'; fi) >"$1.tmp" || return 1
  if [ "$(jq length "$1.tmp")" = 0 ]; then rm -f "$1" "$1.tmp"; else mv "$1.tmp" "$1"; fi
}

# settle_notes <report> <recovery> — each entry {note: k, settled: true, why} of the report marks the standing coder
# note whose text is the k-th of pr-<n>.coder-notes.json, the list this round's reviewer saw, settled with that why;
# then that file keeps only the coder notes still standing, for a second round, which runs no sync. Fix calls it after
# its last stop and before the report moves, so a re-run reads the report against the file as its reviewer saw it.
# Anything off its shape settles nothing: the note stands and holds the draft.
settle_notes() {
  local cn="$LOGS/pr-$PR.coder-notes.json"
  [ -f "$cn" ] || return 0
  notes_edit --rawfile c "$cn" --slurpfile rep "$1" '
    def whole: type == "number" and . >= 0 and . == floor;
    ($c | try fromjson catch null | if type == "array" and all(.[]; type == "string") then . else [] end) as $list
    | [ $rep[0].notes | if type == "array" then .[] else empty end
        | select(type == "object" and .settled == true and (.why | type) == "string"
                 and (.note | whole) and .note < ($list | length)) ] as $S
    | reduce ($S | unique_by(.note))[] as $s (.;
        ([to_entries[] | select(.value.author == "coder" and .value.settled != true and .value.text == $list[$s.note]) | .key][0]) as $i
        | if $i == null then . else .[$i] += {settled: true, why: $s.why} end)' ||
    stop fix "settling the review's notes in $(notes_file) failed (see above): $2"
  coder_notes "$cn" || stop fix "listing the coder notes of $(notes_file) failed (see above): $2"
}

# The fixer's edits are committed, then what others pushed to the branch merged in (git refuses a merge over staged
# changes), then the checks run on that clean tree, so the push carries exactly what was gated.
# fix — last stdout line `FIX: findings=<k> needs-attention=<a> review-again=yes|no`.
# fix_failed <stage> <why> — gate's stops for fix, each naming the fix and describe re-runs.
fix_failed() {
  local redo="run fix $SLUG $PR $BRANCH, then describe $SLUG $PR" fresh="; or re-run in a fresh clone"
  [ "$PUBLISH" = yes ] || fresh=""
  case $1 in
    merge) stop fix "$2; merge it by hand in this checkout, commit, then $redo$fresh" ;;
    discover) stop fix "$2: run /setup-coding-crew, then re-run" "$clog" ;;
    checks) stop fix "$2; once fixed and committed, $redo" "$clog" ;;
    rewrites) stop fix "$2: commit them, then $redo" "$clog" ;;
    push) stop fix "$2; once it can push, or once you have pushed it, $redo" ;;
  esac
}

fix() {
  local report="$LOGS/pr-$PR.review.json" unfixed="$LOGS/pr-$PR.unfixed.json" clog="$LOGS/pr-$PR.checks.log"
  local discarded="$LOGS/pr-$PR.discarded.md" headf="$LOGS/pr-$PR.head" head_oid spec total severe moved=no again=no
  local fixer_notes="$LOGS/pr-$PR.notes.md"
  # The fixer's list in the one shape every reader takes as written, [{finding?, why}], rewritten before any stop below
  # so a stopped fix's result.json renders it as a finished one's; a file off that shape is kept whole as one why.
  if [ -f "$unfixed" ]; then
    jq -nc --rawfile u "$unfixed" '
      def whole: type == "number" and . >= 0 and . == floor;
      ($u | try fromjson catch null) as $p
      | if ($p | type) == "array" and all($p[]; type == "object" and (.why | type) == "string" and ((has("finding") | not) or (.finding | whole)))
        then [$p[] | if has("finding") then {finding, why} else {why} end]
        else [{why: $u}] end' >"$unfixed.tmp" && mv "$unfixed.tmp" "$unfixed" ||
      stop fix "rewriting $unfixed failed (see above): run fix $SLUG $PR $BRANCH, then describe $SLUG $PR"
  fi
  checks_lib
  # The round's first run keeps the PR's head, so a re-run after a person pushed the fix by hand still sees it moved.
  if [ -s "$headf" ]; then head_oid=$(head -n1 "$headf")
  else
    pr_head "$PR"; head_oid=$PR_HEAD
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
  # The round's 0-based index into result.json's rounds is the number of rounds kept: start deletes every round, and
  # each fix adds the next.
  local k=0 f n
  for f in "$LOGS/pr-$PR".r[0-9]*.review.json; do
    [[ "$f" =~ \.r([0-9]+)\.review\.json$ ]] && n=${BASH_REMATCH[1]} && [ "$n" -gt "$k" ] && k=$n || true
  done
  # The fixer's note replaces the run's earlier one, which its prompt offered it to keep, edit or drop: an absent file
  # drops it. With no finding no fixer ran, so the earlier note stands. Recorded before any stop below, for its
  # result.json.
  if [ "$total" != 0 ] || [ -f "$fixer_notes" ]; then
    notes_edit --argjson round "$k" --rawfile t <([ ! -f "$fixer_notes" ] || cat "$fixer_notes") "($NOTE_TEXT) as \$x"'
      | map(select(.author != "fixer")) + (if $x == "" then [] else [{author: "fixer", round: $round, text: $x}] end)' ||
      stop fix "recording $fixer_notes in $(notes_file) failed (see above): run fix $SLUG $PR $BRANCH, then describe $SLUG $PR"
  fi
  gate fix_failed "$clog"
  git rev-parse HEAD >"$LOGS/review.base"

  # "Changed nothing" is no commit on the branch's own line past the round's head: what merge_in brought in sits
  # behind a merge's second parent, and a fix committed here and pushed by hand still counts. The checks' rewrites are
  # not the fixer's.
  [ -z "$(git rev-list --first-parent --no-merges --invert-grep --grep="^Apply the checks' rewrites\$" -n1 HEAD "^$head_oid")" ] || moved=yes
  # Needs a person, one typed item each (result.schema.json's needs_attention): a spec not met (or gaps named), each
  # finding the fixer left in unfixed.json, what the reviewer changed in the tree, and a fixer that changed nothing
  # without saying why (it crashed or gave up).
  local items
  items=$(jq -n --slurpfile rep "$report" --argjson round "$k" --arg moved "$moved" \
    --slurpfile u <(if [ -f "$unfixed" ]; then cat "$unfixed"; else echo '[]'; fi) \
    --rawfile d <([ ! -f "$discarded" ] || cat "$discarded") --arg has_d "$([ -f "$discarded" ] && echo yes || echo no)" '
    ($rep[0]) as $r | ($r.findings // []) as $f | ($r.gaps // []) as $g
    | [$u[0][] | {type: "unfixed", round: $round}
        + (if has("finding") then {finding, severity: ($f[.finding] | if type == "object" and (.severity | type) == "string" then .severity else null end)} else {severity: null} end)
        + {why}] as $un
    | [ if $r.spec != "met" or ($g | length) > 0 then {type: "spec_unmet", round: $round, gaps: [range($g | length)]} else empty end ]
      + $un
      + [ if $has_d == "yes" then {type: "reviewer_changed_tree", paths: ($d | split("\n") | map(select(test("\\S"))))} else empty end ]
      + [ if ($f | length) > 0 and $moved == "no" and ($un | length) == 0 then {type: "fixer_changed_nothing", round: $round} else empty end ]') || stop fix "building the round's needs-attention list failed (see above)"
  settle_notes "$report" "run fix $SLUG $PR $BRANCH, then describe $SLUG $PR"
  # Fixes to a CRITICAL/HIGH/MEDIUM finding are worth reviewing again; SKILL.md caps that at one re-review.
  [ "$severe" = 0 ] || [ "$moved" = no ] || again=yes
  # The round is kept for result.json, and the live paths emptied, so the next round's reviewer and fixer start from
  # none. The checks log is copied: the PR writer reads the live one.
  k="$LOGS/pr-$PR.r$((k + 1))"
  jq -n --argjson c "$([ "$moved" = yes ] && echo true || echo false)" --arg h "$(cat "$LOGS/review.base")" \
    '{fixer_changed_code: $c, checks_commit: $h}' >"$k.fix"
  cp "$clog" "$k.checks.log"
  [ ! -f "$unfixed" ] || mv "$unfixed" "$k.unfixed.json"
  [ ! -f "$fixer_notes" ] || mv "$fixer_notes" "$k.notes.md"
  mv "$report" "$k.review.json"
  # describe reads it: an empty list is a review with nothing needing a person.
  printf '%s\n' "$items" >"$LOGS/pr-$PR.attention.json"
  # A second review round starts from the head its reviewer saw.
  rm -f "$headf"
  echo "FIX: findings=$total needs-attention=$(jq length <<<"$items") review-again=$again"
}

# unresolved_threads — sets UNRESOLVED to the count of $PR's unresolved review threads, every page, and PR_URL. With
# PUBLISH=no there is no PR, so none.
UNRESOLVED="" PR_URL=""
unresolved_threads() {
  UNRESOLVED=0; [ "$PUBLISH" = yes ] || return 0
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

# The whole body, written once at the end, its notes from the run file and earlier-<slug>.md alone. Readiness and the
# outcome come after it, so a failed write never leaves a ready PR with land's one-line body. A re-run rewrites all of
# it, text a person added included.
describe() {
  local summary att="$LOGS/pr-$PR.attention.json" datt="$LOGS/pr-$PR.describe-attention.json"
  local body="$LOGS/pr-$PR.body.md" title="" refs result nf earlier="$LOGS/earlier-$SLUG.md"
  [ -f "$att" ] || die "no review result at $att: run fix $SLUG $PR <branch> first"
  BRANCH=$(git branch --show-current)
  nf=$(notes_file)
  # A review thread still open needs a person as much as fix's list does. Counted on every run, never written into
  # fix's file, so a re-run counts afresh.
  unresolved_threads
  refs=$(node "$CLI" closing-refs --feature-slug "$SLUG") || die "closing-refs failed for '$SLUG' (see above)"
  # The spec is named, not copied: spec.md stays for the reviewer, and a person opens the PRD itself.
  local prd_head="" spec_line="Spec: feature \`$SLUG\`"
  [ ! -f "$LOGS/spec.md" ] || prd_head=$(head -n 1 "$LOGS/spec.md")
  [[ ! "$prd_head" =~ ^'<!-- PRD issue #'([0-9]+): ]] || spec_line="Spec: PRD #${BASH_REMATCH[1]}, feature \`$SLUG\`"
  # The PR writer's summary as result.json renders it: from its summary.json, else its summary.md.
  summary=$(node "$SELF/result.mjs" --logs "$LOGS" --summary "$PR") || die "reading the PR writer's summary in $LOGS failed (see above)"
  title=$(head -n 1 <<<"$summary" | sed -n 's/^# //p')
  # describe's own item, in its own file so a re-run replaces it: the open review threads.
  jq -n --argjson count "$UNRESOLVED" --arg url "$PR_URL" \
    '[ if $count > 0 then {type: "unresolved_threads", count: $count, url: $url} else empty end ]' >"$datt" ||
    die "building describe's needs-attention list failed (see above)"
  # This run's standing notes, what a coder or fixer says a person must do or decide: they hold the draft. The settled
  # ones and earlier runs' notes are a record, never a hold.
  local standing sections fixer="PR #$PR"
  [ "$PUBLISH" = yes ] || fixer=$BRANCH
  standing=$(jq '[.[] | select(.settled != true)] | length' <(if [ -s "$nf" ]; then cat "$nf"; else echo '[]'; fi)) ||
    die "reading $nf failed (see above)"
  sections=$(jq -r --arg fixer "$fixer" --rawfile e <([ ! -f "$earlier" ] || cat "$earlier") \
    --arg nb "$NOTES_BEGIN" --arg ne "$NOTES_END" --arg sb "$SETTLED_BEGIN" --arg se "$SETTLED_END" \
    --arg eb "$EARLIER_BEGIN" --arg ee "$EARLIER_END" '
    def block: "### the \(.author) of \(if .author == "coder" then .ref else "\($fixer)'"'"'s review" end)", "", .text, "";
    [.[] | select(.settled != true)] as $n | [.[] | select(.settled == true)] as $s
    | ($e | sub("^(\\s*\n)+"; "") | sub("\\s+$"; "")) as $x
    | ( if ($n | length) > 0 then $nb, "## Notes for a person", "", "Delete a note here once it is handled.", "", ($n[] | block), $ne, "" else empty end ),
      ( if ($s | length) > 0 then $sb, "## Settled by the review", "",
          ($s[] | block, "Settled by the review: \(.why | gsub("\\s*\n\\s*"; " "))", ""), $se, "" else empty end ),
      ( if $x != "" then $eb, "## Earlier runs'"'"' notes", "", $x, $ee, "" else empty end )' \
    <(if [ -s "$nf" ]; then cat "$nf"; else echo '[]'; fi)) || die "rendering the notes of $nf failed (see above)"
  # The Needs attention lines, one owner with the draft hold and result.json: fix's items and describe's, a gap or an
  # unfixed finding read from the report of the round it names, and one pointer line for the notes.
  local need rep round
  round=$(jq '[.[].round | numbers][0] // empty' "$att")
  rep="$LOGS/pr-$PR.r$((${round:-0} + 1)).review.json"
  need=$(jq -rs --argjson notes "$standing" --slurpfile rep <(if [ -n "$round" ] && jq -e . "$rep" >/dev/null 2>&1; then cat "$rep"; else echo '{}'; fi) '
    def line: tostring | gsub("\\s*\n\\s*"; " ");
    ($rep[0] | if type == "object" then . else {} end) as $r | ($r.gaps // []) as $g | ($r.findings // []) as $f
    | (.[0] + .[1]) as $items
    | ( $items[]
        | if .type == "spec_unmet" then (if (.gaps | length) > 0 then $g[.gaps[]] | line else "the reviewer found the spec unmet" end)
          elif .type == "unfixed" then
            if has("finding") then
              ($f[.finding] | if type == "object" and (.location | type) == "string" then ", \(.location)" else "" end) as $loc
              | "the fixer left finding #\(.finding) (\(.severity // "no severity")\($loc)) unfixed: \(.why | line)"
            else "the fixer left a finding unfixed: \(.why | line)" end
          elif .type == "reviewer_changed_tree" then "the reviewer changed the tree; discarded: \(.paths | join(" "))"
          elif .type == "fixer_changed_nothing" then "the fixer changed nothing"
          elif .type == "unresolved_threads" then "\(.count) unresolved review threads: \(.url)"
          else empty end ),
      ( if $notes > 0 then "notes for a person, in the section below: delete each once it is handled" else empty end )' \
    "$att" "$datt") || die "rendering the needs-attention list failed (see above)"
  # The Tested line's one writer: the last gate's own verdict lines, never the writer's prose.
  local tested
  tested=$(node "$SELF/result.mjs" --logs "$LOGS" --tested-line "pr-$PR.checks.log") || die "reading the checks log $LOGS/pr-$PR.checks.log failed (see above)"
  {
    echo "$BEGIN"
    # Written here, not by the writer subagent, so a reviewer always sees that agents wrote this PR.
    printf '> Written by solve-feature (`%s`): its coder, reviewer and fixer were agents; no person has read this body.\n\n' "$SLUG"
    # write-pr's summary minus its title line, which titles the PR instead.
    if [ -n "$summary" ]; then if [ -n "$title" ]; then tail -n +2 <<<"$summary"; else cat <<<"$summary"; fi | sed '/./,$!d'; echo; fi
    printf '%s\n\n' "$tested"
    if [ -n "$need" ]; then printf '## Needs attention\n\n'; sed '/^- /!s/^/- /' <<<"$need"; echo; fi
    [ -z "$sections" ] || printf '%s\n\n' "$sections"
    printf '%s\n\n' "$spec_line"
    [ -z "$refs" ] || printf '%s\n' "$refs"
    printf '%s\n' "<!-- solve-feature:slug $SLUG -->" "$END"
  } >"$body"
  pr_body_write "$PR" "$body" "$title" || die "writing PR $PR's body failed"
  # Kept, not emptied: a re-run of describe writes the same body and its result.json still carries the notes; the next
  # run's start drops them, as the body holds them now.
  [ ! -s "$nf" ] || notes_edit 'map(. + {rendered: true})' || die "marking the notes of $nf rendered failed (see above)"
  if [ "$(jq -s 'add | length' "$att" "$datt")" != 0 ] || [ "$standing" != 0 ]; then result=needs-attention
  else result=ready; pr_ready "$PR"
  fi
  # Without a PR the branch names the result: the person opens the PR from it, with the body in local_body's file.
  [ "$PUBLISH" = yes ] || { outcome "$result branch=$BRANCH"; echo "$result branch=$BRANCH"; return 0; }
  outcome "$result pr=$PR"
  echo "$result pr=$PR"
}

"$CMD"
