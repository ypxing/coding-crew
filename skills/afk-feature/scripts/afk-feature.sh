#!/usr/bin/env bash
# afk-feature.sh <slug> [--branch <name>] [--budget <usd>] [--open-pr] — run one feature's ready-for-agent
# issues in order on one branch, each gated by the checks and a fresh read-only verifier. Env: AFK_SANDBOXED=1,
# AFK_HOST. Exit 0 once no ready issue is left (last stdout line: the PR URL or `gh pr create` command), else 1.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "afk-feature: $*" >&2; exit 1; }

SLUG="" BRANCH="" BUDGET=5 OPEN_PR=0
while [ $# -gt 0 ]; do case "$1" in
    --branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --budget) BUDGET="${2:?--budget needs a value}"; shift 2 ;;
    --open-pr) OPEN_PR=1; shift ;;
    -*) die "unknown flag: $1" ;;
    *) [ -z "$SLUG" ] || die "unexpected argument: $1"; SLUG="$1"; shift ;;
esac; done
for t in claude gh jq node git timeout; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
# The tracker's own SLUG rule: the slug reaches argv, so nothing else gets through.
[[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid feature slug: '$SLUG'"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"; cd "$ROOT"
COMMON="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" CLI=""
for c in "$ROOT" "$COMMON" "$HOME"; do [ -f "$c/.coding-crew/tracker/cli.mjs" ] && { CLI="$c/.coding-crew/tracker/cli.mjs"; break; }; done
[ -n "$CLI" ] || die "tracker CLI not found (.coding-crew/tracker/cli.mjs): run install.sh"
KIND="$(node "$CLI" config | grep '^tracker=' || true)"
[ "$KIND" = tracker=github ] || die "${KIND:-tracker=unknown}: feature-issues is a GitHub-only op"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean: commit or stash first"
[ "$(node "$CLI" feature-issues --feature-slug "$SLUG" | jq length)" -gt 0 ] || die "no feature '$SLUG' in the tracker"
# Installed beside this skill (.coding-crew/<skill>/scripts), else user-level, as solve-issue finds dep-install.
scripts_of() { local d; for d in "$SELF/../../$1/scripts" "$HOME/.coding-crew/$1/scripts"; do [ -d "$d" ] && { (cd "$d" && pwd); return; }; done
  die "$1 scripts not found: run install.sh --skill afk-feature"; }
CHECKS_DIR=$(scripts_of solve-issue) DEP_DIR=$(scripts_of dep-install)
ROLES="$(cd "$SELF/../roles" 2>/dev/null && pwd)" || die "reviewer role not found beside $SELF: run install.sh --skill afk-feature"
CFG="$ROOT/.coding-crew/config.json" DEV="$ROOT/.coding-crew/dev-commands.json"
model() { local m; m=$(jq -r --arg r "$1" '.afk.models.claude[$r] // empty' "$CFG" 2>/dev/null || true); echo "${m:-$2}"; }
CODER_MODEL=$(model coder sonnet) REVIEWER_MODEL=$(model reviewer opus)
unset CREW_ORCHESTRATED # solve-issue's Step 7 closes the issue itself: the loop sees the label go
# A bare host gets an allow-list (anything else is denied, not prompted); a sandbox gets everything.
PERM=(--permission-mode bypassPermissions)
if [ "${AFK_SANDBOXED:-}" != 1 ]; then
  PERM=(--permission-mode acceptEdits --permission-prompts none --allowedTools "Bash(git *)" "Bash(node *)" "Bash(gh *)" "Bash(bash *)")
  # The checks run-checks.sh runs: typecheck, lint, test, then every other key but its non-check ones.
  [ ! -f "$DEV" ] || while IFS= read -r c; do PERM+=("Bash($c)"); done < <(jq -r '[.typecheck, .lint, .test] + [to_entries[]
    | select(.key | IN("typecheck", "lint", "test", "install", "install_mode", "env", "credential_target", "docker_service") | not) | .value] | .[] | strings' "$DEV")
fi

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
LOGS="$ROOT/.afk-logs" PRD="" rc=0
mkdir -p "$LOGS" && echo '*' >"$LOGS/.gitignore" # ignored in any repo, so the tree stays clean
node "$CLI" prd --feature-slug "$SLUG" >"$LOGS/prd.md" || rc=$?
case $rc in 0) PRD="$LOGS/prd.md" ;; 3) rm -f "$LOGS/prd.md" ;; *) die "reading the feature's PRD failed (exit $rc)" ;; esac

ROOT_N="" CID="" ROWS="" ROW="" NOTE="" N="" PREV=""
row() { ROW="#$N  solve $1  checks $2  verify $3"; progress; }
progress() { # the root issue's one afk-progress comment, rewritten whole; a failed write never stops the loop
  [ -n "$ROOT_N" ] || return 0
  local body list
  body="<!-- afk-progress -->"$'\n'"afk — feature $SLUG — host ${AFK_HOST:-$(hostname 2>/dev/null || uname -n)} — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  body+=$'\n'"$ROWS$ROW${NOTE:+$'\n\n'$NOTE}"
  if [ -z "$CID" ]; then
    list=$(gh api "repos/{owner}/{repo}/issues/$ROOT_N/comments" --paginate 2>/dev/null) || { echo "afk-feature: warning: progress comment not read" >&2; return 0; }
    CID=$(jq -r '.[] | select(.body | contains("<!-- afk-progress -->")) | .id' <<<"$list" 2>/dev/null | head -1) || CID=""
  fi
  if [ -n "$CID" ]; then gh api -X PATCH "repos/{owner}/{repo}/issues/comments/$CID" -f body="$body" >/dev/null 2>&1
  else CID=$(gh api "repos/{owner}/{repo}/issues/$ROOT_N/comments" -f body="$body" 2>/dev/null | jq -r '.id // empty'); [ -n "$CID" ]
  fi || echo "afk-feature: warning: progress comment on #$ROOT_N not written" >&2
}
stop() { # <step> <reason> <log>
  NOTE="Stopped at $1: $2"$'\n```\n'"$(tail -n 20 "$3" 2>/dev/null)"$'\n```'
  case $1 in solve) row ✗ · · ;; checks) row ✓ ✗ · ;; verify) row ✓ ✓ ✗ ;; esac
  echo "afk-feature: #$N $1 failed: $2 — log: $3"; exit 1
}
assert_tree() { # <step> <log> [<head>] — the branch, a clean tree and, when given, an unchanged HEAD
  [ "$(git branch --show-current)" = "$BRANCH" ] || stop "$1" "branch changed to '$(git branch --show-current)'" "$2"
  [ -z "$(git status --porcelain)" ] || stop "$1" "working tree left dirty" "$2"
  [ -z "${3:-}" ] || [ "$(git rev-parse HEAD)" = "$3" ] || stop "$1" "HEAD moved" "$2"
}
shopt -u patsub_replacement 2>/dev/null || true # else `&` in issue text reads as the matched placeholder
verify_prompt() { # <before> <checks>; criteria go in last, so a placeholder named inside them stays literal
  local t crit
  t=$(cat "$SELF/verify-prompt.md")
  [ -n "$PRD" ] || t=$(grep -vx 'PRD: <prd>' <<<"$t")
  crit=$(awk 'tolower($0) ~ /^## acceptance criteria/{f=1;next} /^## /{f=0} f' "$LOGS/$N.issue.md" | sed -e '/./,$!d')
  t=${t//<review-assets>/$ROLES/reviewer}; t=${t//<branch>/$BRANCH}; t=${t//<slug>/$SLUG}; t=${t//<before>/$1}
  t=${t//<issue-file>/$LOGS/$N.issue.md}; t=${t//<prd>/$PRD}; t=${t//<checks>/$2}; t=${t//<report>/$LOGS/$N.verify.json}
  printf '%s\n' "${t//<criteria>/$crit}"
}

while :; do
  FI=$(node "$CLI" feature-issues --feature-slug "$SLUG" --state all)
  ROOT_N=$(jq -r '.[] | select(.root) | .number' <<<"$FI")
  # The tracker's `done`: an awaiting-merge blocker's work is already on this branch.
  DONE=" $(jq -r '[.[] | select(.state == "CLOSED" or any(.labels[]; .name == "awaiting-merge")) | .number] | join(" ")' <<<"$FI") "
  N=""
  for c in $(jq -r '[.[] | select(.state == "OPEN" and (.root | not) and any(.labels[]; .name == "ready-for-agent")) | .number] | sort | .[]' <<<"$FI"); do
    node "$CLI" fetch "$c" >"$LOGS/$c.issue.md"
    ok=1; for b in $(awk '/^## Blocked by/{f=1;next} /^## /{f=0} f' "$LOGS/$c.issue.md" | grep -oE '#[0-9]+' | tr -d '#'); do
      [[ "$DONE" == *" $b "* ]] || ok=0; done
    [ "$ok" = 1 ] && { N=$c; break; }
  done
  [ -n "$N" ] || { N=$PREV; break; }
  [ "$N" != "$PREV" ] || stop solve "coder ran but did not close #$N" "$LOGS/$N.log"
  [ -z "$ROW" ] || ROWS+="$ROW"$'\n'
  LOG="$LOGS/$N.log" CLOG="$LOGS/$N.checks.log" VLOG="$LOGS/$N.verify.log" REPORT="$LOGS/$N.verify.json"
  before=$(git rev-parse HEAD); row · · ·
  timeout 60m claude -p "/solve-issue $N" --output-format json --max-budget-usd "$BUDGET" --model "$CODER_MODEL" \
    "${PERM[@]}" >"$LOG" 2>&1 || stop solve "coder exited non-zero" "$LOG"
  assert_tree solve "$LOG"; row ✓ · ·
  rc=0; bash "$CHECKS_DIR/run-checks.sh" --project-root "$ROOT" --main-root "$ROOT" --dep-scripts "$DEP_DIR" >"$CLOG" 2>&1 || rc=$?
  [ "$rc" != 3 ] || stop checks "no check commands known (DISCOVER): run /solve-issue or dep-install once by hand first" "$CLOG"
  [ "$rc" = 0 ] || stop checks "run-checks.sh exit $rc" "$CLOG"; row ✓ ✓ ·

  evidence=$(sed -nE 's/^([a-z][a-z0-9_]*): pass.*/\1=pass/p; s/^([a-z][a-z0-9_]*): fail.*/\1=fail/p; s/^([a-z][a-z0-9_]*): (NOT RUN|deferred).*/\1=not_run/p' "$CLOG" | paste -sd, - | sed 's/,/, /g')
  rm -f "$REPORT"; head=$(git rev-parse HEAD)
  timeout 20m claude -p "$(verify_prompt "$before" "$evidence")" --append-system-prompt-file "$ROLES/reviewer.md" \
    --tools Bash Read ToolSearch --settings '{"disableClaudeAiConnectors":true,"disableBundledSkills":true}' \
    --output-format json --max-budget-usd 2 --model "$REVIEWER_MODEL" "${PERM[@]}" >"$VLOG" 2>&1 || true
  assert_tree verify "$VLOG" "$head"
  [ -f "$REPORT" ] || stop verify "no report at $REPORT" "$VLOG"
  verdict=$(jq -r '.verdict // empty' "$REPORT" 2>/dev/null || true)
  [ "$verdict" = all-met ] || stop verify "verdict '${verdict:-unreadable}': $(jq -r '.detail // empty' "$REPORT" 2>/dev/null || true)" "$VLOG"
  row ✓ ✓ ✓; PREV=$N
done

git push -q -u origin "$BRANCH"
# Shared with crew-afk's PR: every awaiting-merge issue, and the PRD once no work issue is left open.
REFS=$(node "$CLI" closing-refs --feature-slug "$SLUG")
if [ "$OPEN_PR" = 1 ]; then
  if gh pr view --json number >/dev/null 2>&1; then URL=$(gh pr view --json url -q .url); else URL=$(gh pr create --fill --body "$REFS"); fi
  NOTE="PR: $URL"; progress; echo "$URL"
else
  CMD="gh pr create --fill --body $(printf %q "$REFS")"
  NOTE="Open the PR: \`$CMD\`"; progress; echo "$CMD"
fi
