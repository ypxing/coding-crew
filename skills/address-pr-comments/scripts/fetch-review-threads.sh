#!/usr/bin/env bash
# fetch-review-threads.sh — print, as JSON, the PR review threads that need a response.
#
# Usage: fetch-review-threads.sh [<pr-number>]
#
# A thread is included only if it is unresolved AND its latest comment is from a trusted
# author (write/maintain/admin permission on the repo). Comments by anyone else are removed
# from the output, so the caller only ever sees trusted text. A thread whose latest comment
# is a bot's or an outsider's reply is excluded — "waiting for a human" needs no stored state.
# Top-level review bodies from trusted authors appear as path-less threads.
#
# Output: [{id, path, line, isOutdated, comments: [{author, body, createdAt}]}]
# Permission lookups happen at most once per login per invocation. All GitHub data via `gh`.

set -euo pipefail

PR="${1:-}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -z "$PR" ]; then PR=$(gh pr view --json number -q .number); fi
NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
OWNER=${NWO%%/*}; REPO=${NWO#*/}

# shellcheck disable=SC2016
QUERY='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){
reviews(first:100){nodes{id body createdAt author{login}}}
reviewThreads(first:100){nodes{id isResolved isOutdated path line comments(first:100){nodes{body createdAt author{login}}}}}}}}'
gh api graphql -f query="$QUERY" -F owner="$OWNER" -F repo="$REPO" -F number="$PR" > "$TMP/data.json"

# One lookup per distinct login; failure (404, bot, no access) means untrusted. \r is
# stripped because Windows' jq ends text lines with CRLF, and "alice\r" is no collaborator.
: > "$TMP/trust.ndjson"
jq -r '.data.repository.pullRequest | ([.reviewThreads.nodes[].comments.nodes[].author.login?] + [.reviews.nodes[].author.login?]) | map(select(. != null)) | unique[]' "$TMP/data.json" |
tr -d '\r' |
while IFS= read -r login; do
  perm=$(gh api "repos/$OWNER/$REPO/collaborators/$login/permission" --jq .permission 2>/dev/null | tr -d '\r' || true)
  case "$perm" in write|maintain|admin) t=true ;; *) t=false ;; esac
  jq -n --arg l "$login" --argjson t "$t" '{($l): $t}' >> "$TMP/trust.ndjson"
done

jq -s '
  def trusted($t): (.author.login // "") as $l | ($t[$l] // false);
  def clean: {author: (.author.login // ""), body, createdAt};
  . as [$data] | (.[1:] | add // {}) as $t
  | $data.data.repository.pullRequest as $pr
  | [ $pr.reviewThreads.nodes[]
      | select(.isResolved | not)
      | select((.comments.nodes | last) as $c | $c != null and ($c | trusted($t)))
      | {id, path, line, isOutdated,
         comments: [.comments.nodes[] | select(trusted($t)) | clean]} ]
    + [ $pr.reviews.nodes[]
        | select(trusted($t) and ((.body // "") != ""))
        | {id, path: null, line: null, isOutdated: false, comments: [clean]} ]
' "$TMP/data.json" "$TMP/trust.ndjson"
