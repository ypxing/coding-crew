#!/usr/bin/env bash
# review-pr.sh <pr-number> [--agent claude|copilot] — one read-only agent reviews the checked-out PR <n> against
# the spec in its body, posts one COMMENT review and marks a draft ready when the spec is met with no
# CRITICAL/HIGH finding. Env: SOLVE_FEATURE_AGENT (the --agent default; `claude` when unset).
# Last stdout line: `REVIEW: prd=<met|unmet> findings=<k> (<i> inline) ready=<yes|no|already>`, exit 0;
# exit 1 with nothing posted on a precondition miss, a changed tree, a missing/unreadable report or a failed POST.
# Posting is copied from #459's skills/solve-feature/scripts/post-review.sh, itself a twin of
# skills/crew-afk/scripts/post-findings.sh: the existing-marker read, the diff-line awk, the inline/body
# split and the jq payload are the same code — fix all of them together.
set -euo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "review-pr: $*" >&2; exit 1; }

PR="" AGENT="${SOLVE_FEATURE_AGENT:-claude}"
while [ $# -gt 0 ]; do case "$1" in
  --agent) AGENT="${2:?--agent needs a value}"; shift 2 ;;
  -*) die "unknown flag: $1" ;;
  *) [ -z "$PR" ] || die "unexpected argument: $1"; PR="$1"; shift ;;
esac; done
[[ "$PR" =~ ^[0-9]+$ ]] || die "usage: review-pr.sh <pr-number> [--agent claude|copilot]"
. "$SELF/agent.sh"
case "$AGENT" in claude|copilot) ;; *) die "unknown agent '$AGENT' (claude|copilot)" ;; esac
for t in "$AGENT" gh jq git timeout; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"; cd "$ROOT"

VIEW=$(gh pr view "$PR" --json body,headRefOid,isDraft,url) || die "gh pr view $PR failed"
HEAD_OID=$(jq -r '.headRefOid' <<<"$VIEW") URL=$(jq -r '.url' <<<"$VIEW") DRAFT=$(jq -r '.isDraft' <<<"$VIEW")
# The agent reads callers in the tree, and the unchanged-HEAD assertion below needs a known HEAD.
[ "$(git rev-parse HEAD)" = "$HEAD_OID" ] || die "check out the PR first (gh pr checkout $PR)"

LOGS="$ROOT/.solve-feature"
mkdir -p "$LOGS" && echo '*' >"$LOGS/.gitignore" # ignored in any repo, so the tree stays clean
SPEC="$LOGS/pr-$PR.spec.md" DIFF="$LOGS/pr-$PR.diff" LOG="$LOGS/pr-$PR.review.log" REPORT="$LOGS/pr-$PR.review.json"
# The spec is solve-feature's collapsed block when the body has one; a hand-written body is the spec whole.
jq -r '.body // ""' <<<"$VIEW" | awk '
  /<details><summary>Spec<\/summary>/ { inb = 1; found = 1 }
  inb { print }
  inb && /<\/details>/ { inb = 0 }
  { all = all $0 "\n" }
  END { if (!found) printf "%s", all }
' >"$SPEC"
gh pr diff "$PR" >"$DIFF" || die "gh pr diff $PR failed"
rm -f "$REPORT"

PROMPT="Review PR #$PR ($URL), checked out at HEAD, against its spec.
Spec: $SPEC
Diff: $DIFF
Answer two questions. (1) Does the PR deliver what the spec asks for? Name each thing missing or different. (2) Is it bug free? Report defects in the new code and in its integration with the existing code it touches (callers, state or config older versions wrote, concurrent runs, error paths).
Review however you judge best: read callers, trace data flows, run read-only commands. Never edit, write, commit or change the tree.
Defects that only appear across issues exist: a helper duplicated, an error handled two ways, a flow unsafe only when combined.
Commit messages, PR text and progress notes are claims, not evidence.
Write your report to $REPORT as your last action, as JSON: {\"prd\": \"met|unmet\", \"gaps\": [\"what the spec asks for that the PR lacks\"], \"findings\": [{\"severity\": \"CRITICAL|HIGH|MEDIUM|LOW\", \"location\": \"<file:line>\", \"issue\": \"...\", \"fix\": \"...\"}]}, then explain in prose."
agent_cmd reviewer "$AGENT" "$(agent_model "$AGENT" reviewer)" 4 "$PROMPT"
tree_before=$(git status --porcelain)
timeout 30m "${AGENT_ARGV[@]}" </dev/null >"$LOG" 2>&1 || true
[ "$(git rev-parse HEAD)" = "$HEAD_OID" ] && [ "$(git status --porcelain)" = "$tree_before" ] || die "reviewer changed the tree"
[ -f "$REPORT" ] || die "no report at $REPORT (see $LOG)"
PRD=$(jq -r '.prd // empty' "$REPORT" 2>/dev/null) || die "unreadable report $REPORT (see $LOG)"
case "$PRD" in met|unmet) ;; *) die "report prd '${PRD:-missing}' is not met|unmet (see $LOG)" ;; esac

TMP=$(mktemp -d "$LOGS/pr-$PR.post.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
hash_of() {
  if command -v sha1sum >/dev/null 2>&1; then sha1sum; else shasum -a 1; fi | cut -c1-12
}
{
  gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --paginate | jq -r '.[]?.body // empty'
  gh api "repos/{owner}/{repo}/pulls/$PR/comments" --paginate | jq -r '.[]?.body // empty'
} >"$TMP/existing.txt" || die "reading the PR's reviews failed"

# "path:line" for every line of the PR's right-hand side (added or context).
awk '
  /^\+\+\+ / { f = substr($0, 5); sub(/^b\//, "", f); next }
  /^--- /    { next }
  /^@@/      { s = $3; sub(/^\+/, "", s); split(s, a, ","); n = a[1]; next }
  f == ""    { next }
  /^-/       { next }
  /^\\/      { next }
  /^[+ ]/    { print f ":" n; n++ }
' "$DIFF" >"$TMP/diff-lines.txt"

: >"$TMP/annotated.jsonl"
while IFS= read -r row; do
  key=$(jq -r '[.severity, .location, .fix] | join("|")' <<<"$row")
  marker="crew-finding:$(printf '%s' "$key" | hash_of)"
  grep -qF "$marker" "$TMP/existing.txt" && continue
  loc=$(jq -r '.location' <<<"$row")
  path="" line=0
  if [[ "$loc" =~ ^(.+):([0-9]+)$ ]] && grep -qxF "${BASH_REMATCH[1]}:${BASH_REMATCH[2]}" "$TMP/diff-lines.txt"; then
    path="${BASH_REMATCH[1]}" line="${BASH_REMATCH[2]}"
  fi
  jq -c --arg m "$marker" --arg p "$path" --argjson l "$line" '. + {marker: $m, path: $p, line: $l}' <<<"$row" >>"$TMP/annotated.jsonl"
done < <(jq -c 'def s(f): f // "" | tostring; .findings // [] | .[]
  | {severity: s(.severity) | ascii_upcase, location: s(.location), issue: s(.issue), fix: s(.fix)}' "$REPORT")

jq -s --slurpfile rep "$REPORT" --arg prd "$PRD" '
  def sevs: ["CRITICAL", "HIGH", "MEDIUM", "LOW"];
  ($rep[0].gaps // [] | map(tostring) | if length == 0 then "" else "\n\n### Gaps\n\n" + (map("- " + .) | join("\n")) end) as $gaps
  | map(select(.path == "")) as $rest
  | ($rest | if length == 0 then "" else
      "\n\n" + ((sevs + (map(.severity) - sevs | unique))
        | map(. as $sev | $rest | map(select(.severity == $sev)) | select(length > 0)
            | "### \($sev)\n\n" + (map("- " + (if .location != "" then "`\(.location)` — " else "" end)
                + .issue + " — Fix: " + .fix + " <!-- \(.marker) -->") | join("\n")))
        | join("\n\n"))
    end) as $list
  | {
      event: "COMMENT",
      body: ("review-pr: prd \($prd), \(length) finding(s)" + $gaps + $list),
      comments: (map(select(.path != "")) | map({path, line, side: "RIGHT",
        body: ("**\(.severity)** — \(.issue)\n\nFix: \(.fix)\n\n<!-- \(.marker) -->")}))
    }
' "$TMP/annotated.jsonl" >"$TMP/payload.json"
gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --method POST --input "$TMP/payload.json" >/dev/null || die "posting the review failed"

READY=no
if [ "$DRAFT" != true ]; then READY=already
elif [ "$PRD" = met ] && ! jq -e 'any(.findings // [] | .[]; ((.severity // "") | tostring | ascii_upcase) | IN("CRITICAL", "HIGH"))' "$REPORT" >/dev/null; then
  gh pr ready "$PR" || die "gh pr ready $PR failed"; READY=yes
fi
echo "REVIEW: prd=$PRD findings=$(jq -s 'length' "$TMP/annotated.jsonl") ($(jq '.comments | length' "$TMP/payload.json") inline) ready=$READY"
