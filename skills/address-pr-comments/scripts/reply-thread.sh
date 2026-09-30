#!/usr/bin/env bash
# reply-thread.sh — post a reply to a PR review thread, by thread id. Never resolves it.
#
# Usage: reply-thread.sh <thread-id> <body>
#   <thread-id> is the `id` fetch-review-threads.sh prints (a GraphQL node id).
# Prints nothing on success. All GitHub access via `gh`.

set -euo pipefail

THREAD="${1:-}"; BODY="${2:-}"
[ -n "$THREAD" ] && [ -n "$BODY" ] || { echo "Usage: reply-thread.sh <thread-id> <body>" >&2; exit 2; }

# shellcheck disable=SC2016
MUTATION='mutation($thread:ID!,$body:String!){addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$thread,body:$body}){comment{id}}}'
gh api graphql -f query="$MUTATION" -F thread="$THREAD" -F body="$BODY" >/dev/null
