#!/usr/bin/env bash
# afk-feature.sh — run one feature's ready-for-agent issues in order on one branch; after each coder
# run, the project's checks and a fresh read-only verifier gate it. State lives in git and the tracker.
#
# Usage: afk-feature.sh <slug> [--branch <name>] [--budget <usd>] [--open-pr]
# Env: AFK_SANDBOXED=1 (bypassPermissions, for a runner or container), AFK_HOST (progress label).
# Exits 0 when no ready issue is left (last stdout line: the PR URL or the `gh pr create` command),
# 1 on a failed precondition or the first failing step (stdout names its log).

set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "afk-feature: $*" >&2; exit 1; }

SLUG="" BRANCH="" BUDGET=5 OPEN_PR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --budget) BUDGET="${2:?--budget needs a value}"; shift 2 ;;
    --open-pr) OPEN_PR=1; shift ;;
    -*) die "unknown flag: $1" ;;
    *) [ -z "$SLUG" ] || die "unexpected argument: $1"; SLUG="$1"; shift ;;
  esac
done

for t in claude gh jq node git timeout; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
# The tracker's own SLUG rule: the slug reaches argv, so nothing else gets through.
[[ "$SLUG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid feature slug: '$SLUG'"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
cd "$ROOT"
COMMON="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
CLI=""
for c in "$ROOT/.coding-crew/tracker/cli.mjs" "$COMMON/.coding-crew/tracker/cli.mjs" "$HOME/.coding-crew/tracker/cli.mjs"; do
  [ -f "$c" ] && { CLI="$c"; break; }
done
[ -n "$CLI" ] || die "tracker CLI not found (.coding-crew/tracker/cli.mjs): run install.sh"
KIND="$(node "$CLI" config | grep '^tracker=' || true)"
[ "$KIND" = tracker=github ] || die "${KIND:-tracker=unknown}: feature-issues is a GitHub-only op"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean: commit or stash first"
CFG="$ROOT/.coding-crew/config.json" DEV="$ROOT/.coding-crew/dev-commands.json"
model() { local m; m=$(jq -r --arg r "$1" '.afk.models.claude[$r] // empty' "$CFG" 2>/dev/null || true); echo "${m:-$2}"; }
CODER_MODEL=$(model coder sonnet) REVIEWER_MODEL=$(model reviewer opus)
unset CREW_ORCHESTRATED # solve-issue's Step 7 closes the issue itself: the loop sees the label go

# preflight.sh blocks a coder on the default branch, so the branch comes first. Never reset or rebase
# an existing one: a re-run lands on it as the last run left it.
git fetch -q origin
DEFAULT=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)
DEFAULT=${DEFAULT:-main}
CUR=$(git branch --show-current)
[ -n "$CUR" ] || die "HEAD is detached: check out a branch first"
if [ "$CUR" = "$DEFAULT" ]; then
  BRANCH=${BRANCH:-feature/$SLUG}
  if git show-ref --verify -q "refs/heads/$BRANCH"; then git checkout -q "$BRANCH"
  elif git show-ref --verify -q "refs/remotes/origin/$BRANCH"; then git checkout -q -t "origin/$BRANCH"
  else git checkout -q -b "$BRANCH" "origin/$DEFAULT" && git push -q -u origin "$BRANCH"; fi
else
  BRANCH=$CUR
fi

LOGS="$ROOT/.afk-logs"
mkdir -p "$LOGS" && echo '*' > "$LOGS/.gitignore" # ignored in any repo, so the tree stays clean

PREV=""
while :; do
  FI=$(node "$CLI" feature-issues --feature-slug "$SLUG" --state all)
  CLOSED=" $(jq -r '[.[] | select(.state == "CLOSED") | .number] | join(" ")' <<<"$FI") "
  N=""
  for c in $(jq -r '[.[] | select(.state == "OPEN" and (.root | not) and any(.labels[]; .name == "ready-for-agent")) | .number] | sort | .[]' <<<"$FI"); do
    node "$CLI" fetch "$c" >"$LOGS/$c.issue.md"
    ok=1
    for b in $(awk '/^## Blocked by/{f=1;next} /^## /{f=0} f' "$LOGS/$c.issue.md" | grep -oE '#[0-9]+' | tr -d '#'); do
      [[ "$CLOSED" == *" $b "* ]] || ok=0
    done
    [ "$ok" = 1 ] && { N=$c; break; }
  done
  [ -n "$N" ] || break
  [ "$N" != "$PREV" ] || die "coder ran but did not close #$N"
  LOG="$LOGS/$N.log"
  timeout 60m claude -p "/solve-issue $N" --output-format json --max-budget-usd "$BUDGET" --model "$CODER_MODEL" >"$LOG" 2>&1 || die "coder exited non-zero"
  PREV=$N
done
