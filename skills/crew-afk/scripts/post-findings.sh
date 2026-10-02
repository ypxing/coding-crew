#!/usr/bin/env bash
set -euo pipefail

# post-findings.sh — post the sprint's open review findings to the feature branch's open PR.
#
# Usage: post-findings.sh
#   FEATURE_BRANCH and FEATURE_SLUG come from the environment (the orchestrator's childEnv).
#
# The findings are `promote-findings.sh open`'s: those no fix issue covers. They go up as ONE
# PR review (event COMMENT). A finding whose location is `path:line` on a line the PR diff
# shows becomes an inline comment; the rest are listed in the review body, grouped by
# severity. Every finding carries a hidden marker, and one already on the PR (in a review
# body or an inline comment) is skipped, so a re-run posts only what is new.
#
# Prints `POSTED: <n> (<inline> inline)`.

: "${FEATURE_BRANCH:?FEATURE_BRANCH is not set}"
: "${FEATURE_SLUG:?FEATURE_SLUG is not set}"
MAIN_ROOT="${MAIN_ROOT:-$(git rev-parse --show-toplevel)}"
cd "$MAIN_ROOT"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null; return 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

hash_of() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum; else shasum -a 1; fi | cut -c1-12
}

findings=$(bash "$SCRIPT_DIR/promote-findings.sh" open --feature-slug "$FEATURE_SLUG")
if [ "$(jq 'length' <<< "$findings")" -eq 0 ]; then
  echo "POSTED: 0 (0 inline)"
  exit 0
fi

pr=$(gh pr view "$FEATURE_BRANCH" --json number,state)
[ "$(jq -r '.state' <<< "$pr")" = "OPEN" ] || { echo "post-findings.sh: no open PR for $FEATURE_BRANCH" >&2; exit 1; }
number=$(jq -r '.number' <<< "$pr")
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)

# Markers already on the PR.
{
  gh api "repos/$repo/pulls/$number/reviews" --paginate | jq -r '.[]?.body // empty'
  gh api "repos/$repo/pulls/$number/comments" --paginate | jq -r '.[]?.body // empty'
} > "$TMP/existing.txt"

# "path:line" for every line of the PR's right-hand side (added or context).
gh pr diff "$number" | awk '
  /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
  /^--- /    { next }
  /^@@/      { s = $3; sub(/^\+/, "", s); split(s, a, ","); n = a[1]; next }
  f == ""    { next }
  /^-/       { next }
  /^\\/      { next }
  /^[+ ]/    { print f ":" n; n++ }
' > "$TMP/diff-lines.txt"

# Annotate each finding: marker, and inline path/line when its location is in the diff.
: > "$TMP/annotated.jsonl"
while IFS= read -r row; do
  key=$(jq -r '[.branch, .severity, .location, .criterion] | join("|")' <<< "$row")
  marker="crew-finding:$(printf '%s' "$key" | hash_of)"
  grep -qF "$marker" "$TMP/existing.txt" && continue
  loc=$(jq -r '.location' <<< "$row")
  path=""; line=0
  verdict=$(jq -r '.verdict // ""' <<< "$row")
  if [ "$verdict" != "dismiss" ] && [[ "$loc" =~ ^(.+):([0-9]+)$ ]] && grep -qxF "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}" "$TMP/diff-lines.txt"; then
    path="${BASH_REMATCH[1]}"; line="${BASH_REMATCH[2]}"
  fi
  jq -c --arg m "$marker" --arg p "$path" --argjson l "$line" '. + {marker: $m, path: $p, line: $l}' <<< "$row" >> "$TMP/annotated.jsonl"
done < <(jq -c '.[]' <<< "$findings")

if [ ! -s "$TMP/annotated.jsonl" ]; then
  echo "POSTED: 0 (0 inline)"
  exit 0
fi

jq -s '
  def what: (if (.issue // "") != "" then .issue + " — Fix: " else "" end) + .criterion;
  . as $all
  | ($all | map(select(.path != ""))) as $inline
  | ($all | map(select(.path == "" and .verdict != "dismiss"))) as $rest
  | ($all | map(select(.verdict == "dismiss"))) as $dis
  | (($rest | if length == 0 then "" else
      "\n\n" + ([ "CRITICAL", "HIGH", "MEDIUM", "LOW" ]
        | map(. as $sev | $rest | map(select(.severity == $sev)) | select(length > 0)
            | "### \($sev)\n\n" + (map("- " + (if .location != "" then "`\(.location)` — " else "" end)
                + what + " (`\(.branch)`) <!-- \(.marker) -->") | join("\n")))
        | join("\n\n"))
    end)
    + ($dis | if length == 0 then "" else
        "\n\n### Dismissed by triage\n\n" + (map("- " + (if .location != "" then "`\(.location)` — " else "" end)
          + what + " (`\(.branch)`, \(.severity))"
          + (if (.rationale // "") != "" then " — why: " + .rationale else "" end)
          + " <!-- \(.marker) -->") | join("\n"))
      end)) as $list
  | {
      event: "COMMENT",
      body: ("crew-afk review findings. Nothing here is acted on until a human replies." + $list),
      comments: ($inline | map({path, line, side: "RIGHT",
        body: ("**\(.severity)** (`\(.branch)`) — \(what)\n\n<!-- \(.marker) -->")}))
    }
' "$TMP/annotated.jsonl" > "$TMP/payload.json"

gh api "repos/$repo/pulls/$number/reviews" --method POST --input "$TMP/payload.json" >/dev/null

n=$(jq -s 'length' "$TMP/annotated.jsonl")
inline=$(jq '.comments | length' "$TMP/payload.json")
_trace PR "branch=$FEATURE_BRANCH findings-posted=$n inline=$inline"
echo "POSTED: $n ($inline inline)"
