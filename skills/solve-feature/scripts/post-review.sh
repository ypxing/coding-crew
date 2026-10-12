#!/usr/bin/env bash
# post-review.sh <pr-number> <report.json> [--notes-file <f>] — post a whole-feature verify report on PR
# <n> as one COMMENT review; prints `POSTED: <n> (<inline> inline)`, exit 1 on a failed gh api.
# A finding at a `path:line` the diff shows goes inline, the rest in the body by severity; each carries a
# hidden marker, and one already on the PR is skipped. Twin of skills/crew-afk/scripts/post-findings.sh:
# the diff-line awk, the marker hash and the inline/body split are copied from it, so fix both.
set -euo pipefail
usage() { echo "usage: post-review.sh <pr-number> <report.json> [--notes-file <f>]" >&2; exit 2; }
PR="${1:-}" REPORT="${2:-}" NOTES=""
[[ "$PR" =~ ^[0-9]+$ ]] && [ -f "$REPORT" ] || usage
shift 2
while [ $# -gt 0 ]; do case "$1" in --notes-file) [ $# -ge 2 ] || usage; NOTES="$2"; shift 2 ;; *) usage ;; esac; done
jq -e '(.findings // []) | type == "array"' "$REPORT" >/dev/null 2>&1 || { echo "post-review.sh: $REPORT is not a report" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
hash_of() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum; else shasum -a 1; fi | cut -c1-12
}

{
  gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --paginate | jq -r '.[]?.body // empty'
  gh api "repos/{owner}/{repo}/pulls/$PR/comments" --paginate | jq -r '.[]?.body // empty'
} >"$TMP/existing.txt" || exit 1

# "path:line" for every line of the PR's right-hand side (added or context).
gh pr diff "$PR" >"$TMP/pr.diff" || exit 1
awk '
  /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
  /^--- /    { next }
  /^@@/      { s = $3; sub(/^\+/, "", s); split(s, a, ","); n = a[1]; next }
  f == ""    { next }
  /^-/       { next }
  /^\\/      { next }
  /^[+ ]/    { print f ":" n; n++ }
' "$TMP/pr.diff" >"$TMP/diff-lines.txt"

: >"$TMP/annotated.jsonl"
while IFS= read -r row; do
  key=$(jq -r '[.severity, .location, .criterion] | join("|")' <<<"$row")
  marker="crew-finding:$(printf '%s' "$key" | hash_of)"
  grep -qF "$marker" "$TMP/existing.txt" && continue
  loc=$(jq -r '.location' <<<"$row")
  path="" line=0
  if [[ "$loc" =~ ^(.+):([0-9]+)$ ]] && grep -qxF "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}" "$TMP/diff-lines.txt"; then
    path="${BASH_REMATCH[1]}" line="${BASH_REMATCH[2]}"
  fi
  jq -c --arg m "$marker" --arg p "$path" --argjson l "$line" '. + {marker: $m, path: $p, line: $l}' <<<"$row" >>"$TMP/annotated.jsonl"
done < <(jq -c 'def s(f): f // "" | tostring; .findings // [] | .[]
  | {severity: s(.severity) | ascii_upcase, location: s(.location), issue: s(.issue), criterion: s(.criterion)}' "$REPORT")

# A re-run with nothing new adds no second review; the first post always lands, so the PR shows the verify ran.
if [ ! -s "$TMP/annotated.jsonl" ] && grep -q '^solve-feature whole-feature verify:' "$TMP/existing.txt"; then
  echo "POSTED: 0 (0 inline)"
  exit 0
fi

notes=""; [ -z "$NOTES" ] || [ ! -f "$NOTES" ] || notes=$(cat "$NOTES")
jq -s --slurpfile rep "$REPORT" --arg notes "$notes" '
  def what: (if .issue != "" then .issue + " — Fix: " else "" end) + .criterion;
  def sevs: ["CRITICAL", "HIGH", "MEDIUM", "LOW"];
  ($rep[0].findings // [] | map((.severity // "") | tostring | ascii_upcase)) as $all
  | (if ($all | length) == 0 then "no findings" else
      "\($all | length) finding(s): " + ((sevs + ($all - sevs | unique))
        | map(. as $s | ($all | map(select(. == $s)) | length) as $c | select($c > 0) | "\($c) \($s | ascii_downcase)")
        | join(", "))
    end) as $summary
  | map(select(.path == "")) as $rest
  | ($rest | if length == 0 then "" else
      "\n\n" + ((sevs + (map(.severity) - sevs | unique))
        | map(. as $sev | $rest | map(select(.severity == $sev)) | select(length > 0)
            | "### \($sev)\n\n" + (map("- " + (if .location != "" then "`\(.location)` — " else "" end)
                + what + " <!-- \(.marker) -->") | join("\n")))
        | join("\n\n"))
    end) as $list
  | {
      event: "COMMENT",
      body: ("solve-feature whole-feature verify: " + $summary + $list
        + "\n\n### Per-issue verifier notes\n\n" + (if ($notes | test("\\S")) then $notes else "none" end)),
      comments: (map(select(.path != "")) | map({path, line, side: "RIGHT",
        body: ("**\(.severity)** — \(what)\n\n<!-- \(.marker) -->")}))
    }
' "$TMP/annotated.jsonl" >"$TMP/payload.json"

gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --method POST --input "$TMP/payload.json" >/dev/null || exit 1
echo "POSTED: $(jq -s 'length' "$TMP/annotated.jsonl") ($(jq '.comments | length' "$TMP/payload.json") inline)"
