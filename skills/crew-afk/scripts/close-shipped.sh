#!/usr/bin/env bash
set -uo pipefail

# close-shipped.sh — close a feature's issues whose pull request has merged, under `tracker: github`.
#
# Usage: close-shipped.sh <feature-slug> <feature-branch>
#
# GitHub closes an issue on merge only if it linked the PR's `Closes #n` line when the PR was
# opened, and it can fail to (a real PR merged with all five of its lines unlinked, leaving the
# issues open). This reads those lines itself instead:
#   1. Every merged PR from <feature-branch> into the repo's default branch, and the issue numbers
#      its body names with a closing keyword (close/closes/closed, fix/…, resolve/…).
#   2. Each open `awaiting-merge` issue in the milestone <feature-slug> that such a body names is
#      closed as completed, with a comment naming the PR. An issue no merged PR names stays open:
#      its work has not reached the default branch.
#   3. Once no open work issue is left in the milestone, its PRD issue (title `PRD: …`) is closed
#      too — only after at least one merged PR, so a PRD whose feature has not shipped stays open.
# The milestone itself is left open (closing it is a human's call; the tracker reopens a closed
# one when the next issue is created for the feature).
#
# Runs once per crew-afk run, right after the feature lease is taken, and by hand after a merge.
# Prints `CLOSED: #<n> (PR #<p>)` per issue, `CLOSED: PRD #<n>`, then `SHIPPED: <count>`.
# Under `tracker: local` prints nothing. Exit 0 on success or when nothing applies; 1 when a gh
# call fails (the caller warns, the run goes on).

MAIN_ROOT="${MAIN_ROOT:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tracker-cli.sh
. "$SCRIPT_DIR/tracker-cli.sh"
resolve_tracker_cli "$MAIN_ROOT" || exit 1

SLUG="${1:-}"
BRANCH="${2:-}"
if [ -z "$SLUG" ] || [ -z "$BRANCH" ]; then
  echo "Usage: close-shipped.sh <feature-slug> <feature-branch>" >&2
  exit 1
fi

[ "$TRACKER_KIND" = "github" ] || exit 0

fail() { echo "close-shipped.sh: $1" >&2; exit 1; }

if ! REPO_INFO="$(gh repo view --json nameWithOwner,defaultBranchRef \
    --jq '"\(.nameWithOwner) \(.defaultBranchRef.name)"' 2>&1)"; then
  fail "gh repo view failed: $REPO_INFO"
fi
read -r REPO_NAME DEFAULT_BRANCH <<< "$REPO_INFO"

if ! PRS="$(gh pr list --head "$BRANCH" --state merged --limit 100 \
    --json number,baseRefName,body 2>&1)"; then
  fail "gh pr list failed: $PRS"
fi
[ -n "$PRS" ] || PRS="[]"

# "<issue> <pr>" per closing keyword, in a PR merged into the default branch — the only base
# GitHub itself honours the keywords for. A reference is `#n`, `owner/repo#n` or the issue's
# URL, as GitHub accepts; one naming another repo is not this feature's to close.
if ! SHIPPED="$(printf '%s' "$PRS" | jq -r --arg base "$DEFAULT_BRANCH" --arg repo "$REPO_NAME" '
    .[] | select(.baseRefName == $base) | .number as $pr
    | (.body // "")
    | scan("(?i)\\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?):?[ \\t]+(?:https://github\\.com/([\\w.-]+/[\\w.-]+)/issues/|([\\w.-]+/[\\w.-]+)?#)([0-9]+)\\b")
    | select(((.[0] // .[1]) // $repo | ascii_downcase) == ($repo | ascii_downcase))
    | "\(.[2]) \($pr)"' 2>&1)"; then
  fail "could not read the merged PRs: $SHIPPED"
fi
MERGED_ANY="$(printf '%s' "$PRS" | jq -r --arg base "$DEFAULT_BRANCH" \
  '[.[] | select(.baseRefName == $base)] | length')"

MERGED_PR="$(printf '%s' "$PRS" | jq -r --arg base "$DEFAULT_BRANCH" '[.[] | select(.baseRefName == $base)][0].number // ""')"

if ! ISSUES="$(gh issue list --milestone "$SLUG" --state open --limit 500 \
    --json number,title,labels 2>&1)"; then
  # A milestone not created yet has no issues, and so nothing to close.
  if printf '%s' "$ISSUES" | grep -qi milestone; then echo "SHIPPED: 0"; exit 0; fi
  fail "gh issue list failed: $ISSUES"
fi

COUNT=0
FAILED=0
REMAINING=0
PRDS=()
while IFS=$'\t' read -r N TITLE AWAITING; do
  [ -n "$N" ] || continue
  case "$TITLE" in PRD:*) PRDS+=("$N"); continue ;; esac
  PR=""
  [ "$AWAITING" = "true" ] && PR="$(printf '%s\n' "$SHIPPED" | awk -v n="$N" '$1 == n { print $2; exit }')"
  if [ -z "$PR" ]; then
    REMAINING=$((REMAINING + 1))
    continue
  fi
  if OUT="$(gh issue close "$N" --reason completed \
      --comment "Shipped in #$PR, merged into \`$DEFAULT_BRANCH\`." 2>&1)"; then
    echo "CLOSED: #$N (PR #$PR)"
    COUNT=$((COUNT + 1))
  else
    echo "close-shipped.sh: gh issue close failed for #$N: $OUT" >&2
    FAILED=1
    REMAINING=$((REMAINING + 1))
  fi
done < <(printf '%s' "$ISSUES" | jq -r \
  '.[] | [.number, .title, ([.labels[]?.name] | index("awaiting-merge") != null)] | @tsv')

if [ "$MERGED_ANY" -gt 0 ] && [ "$REMAINING" -eq 0 ]; then
  for N in "${PRDS[@]}"; do
    BODY=""
    if ! BODY="$(gh issue view "$N" --json body --jq '.body // ""' 2>&1)"; then
      echo "close-shipped.sh: gh issue view failed for PRD #$N: $BODY" >&2
      FAILED=1
      BODY=""
    fi
    # `Origin: #n[, #n…]` — tracker issues the PRD's design started from; they close with it.
    while read -r O; do
      [ -n "$O" ] || continue
      STATE="$(gh issue view "$O" --json state --jq .state 2>/dev/null)" || STATE="OPEN"
      [ "$STATE" = "CLOSED" ] && continue
      if OUT="$(gh issue close "$O" --reason completed \
          --comment "Closed with PRD #$N, shipped in PR #$MERGED_PR, merged into \`$DEFAULT_BRANCH\`." 2>&1)"; then
        echo "CLOSED: origin #$O (PRD #$N)"
      else
        echo "close-shipped.sh: gh issue close failed for origin #$O: $OUT" >&2
        FAILED=1
      fi
    done < <(printf '%s\n' "$BODY" | sed -n 's/^Origin:[[:space:]]*//p' | head -1 | grep -o '#[0-9]*' | tr -d '#')
    if OUT="$(gh issue close "$N" --reason completed \
        --comment "Every issue in this feature has shipped." 2>&1)"; then
      echo "CLOSED: PRD #$N"
    else
      echo "close-shipped.sh: gh issue close failed for PRD #$N: $OUT" >&2
      FAILED=1
    fi
  done
fi

echo "SHIPPED: $COUNT"
[ "$FAILED" -eq 0 ] || exit 1
