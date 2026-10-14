#!/usr/bin/env bash
# review-pr.sh prepare|post <pr-number> — the guards around review-pr's reviewer, which SKILL.md runs as a
# read-only subagent of the host agent between the two.
#   prepare <n>  HEAD is the PR's head and the tree is clean; writes the spec, the diff, the reviewed head
#                (pr-<n>.reviewed-head, what solve-feature's fix counts fixes from) and the reviewer's prompt under
#                .solve-feature/; prints prompt=<file> and reviewer-model= (.coding-crew/config.json
#                solveFeature.models.reviewer, empty when unset)
#   post <n>     HEAD and the tree are unchanged and the reviewer's report is valid: posts one COMMENT review,
#                marks a draft ready when the spec is met with no CRITICAL/HIGH finding, and writes
#                .solve-feature/reviewed. solve-feature runs only prepare: its own fix step writes reviewed.
# post's last stdout line: `REVIEW: prd=<met|unmet> findings=<k> (<i> inline) ready=<yes|no|already>`.
# Exit: 0 ok; 1 with nothing posted on a precondition miss, a changed HEAD or tree, a missing/unreadable report
# or a failed POST, its reason also in .solve-feature/stopped (an Actions job's last step fails on it); 2 usage.
# Posting is copied from #459's skills/solve-feature/scripts/post-review.sh, itself a twin of
# skills/crew-afk/scripts/post-findings.sh: the existing-marker read, the diff-line awk, the inline/body
# split and the jq payload are the same code — fix all of them together.
set -euo pipefail
LOGS=""
mark_stopped() { [ -n "$LOGS" ] || return 0; { mkdir -p "$LOGS" && echo '*' >"$LOGS/.gitignore" && printf '%s\n' "$*" >"$LOGS/stopped"; } 2>/dev/null || true; }
die() { echo "review-pr: $*" >&2; mark_stopped "review-pr: $*"; exit 1; }
# Any other failure (set -e) also exits 1 with a reason, so an Actions job sees it; post's temp dir goes either way.
TMP=""
trap 'rc=$?; [ -z "$TMP" ] || rm -rf "$TMP"; case $rc in 0|2) ;; *) [ -f "$LOGS/stopped" ] || mark_stopped "review-pr: $CMD failed (exit $rc)"; exit 1 ;; esac' EXIT

CMD="${1:-}" PR="${2:-}"
case "$CMD" in prepare|post) ;; *) CMD="" ;; esac
[ -n "$CMD" ] && [ $# -eq 2 ] && [[ "$PR" =~ ^[0-9]+$ ]] || { echo "usage: review-pr.sh prepare|post <pr-number>" >&2; exit 2; }
for t in gh jq git; do command -v "$t" >/dev/null || die "$t not found on PATH"; done
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"; cd "$ROOT"
LOGS="$ROOT/.solve-feature"
mkdir -p "$LOGS" && echo '*' >"$LOGS/.gitignore" # ignored in any repo, so the tree stays clean
SPEC="$LOGS/pr-$PR.spec.md" DIFF="$LOGS/pr-$PR.diff" PROMPT="$LOGS/pr-$PR.prompt.md" REPORT="$LOGS/pr-$PR.review.json"

VIEW=$(gh pr view "$PR" --json body,headRefOid,isDraft,url) || die "gh pr view $PR failed"
HEAD_OID=$(jq -r '.headRefOid' <<<"$VIEW") URL=$(jq -r '.url' <<<"$VIEW") DRAFT=$(jq -r '.isDraft' <<<"$VIEW")
# The reviewer reads callers in the tree, and post's unchanged-tree assertion needs a known, clean start.
if [ "$CMD" = prepare ]; then
  if [ "$(git rev-parse HEAD)" != "$HEAD_OID" ]; then
    # Ahead of the PR: commits a stopped push left behind, not a wrong checkout.
    ! git merge-base --is-ancestor "$HEAD_OID" HEAD 2>/dev/null || die "HEAD has commits PR #$PR lacks: push them first"
    die "check out the PR first (gh pr checkout $PR)"
  fi
  [ -z "$(git status --porcelain)" ] || die "working tree is not clean: commit or stash first"
else
  [ "$(git rev-parse HEAD)" = "$HEAD_OID" ] || die "HEAD is no longer PR #$PR's head: the reviewer changed the tree, or the PR moved"
  [ -z "$(git status --porcelain)" ] || die "the reviewer changed the tree"
fi

prepare() {
  # The spec is solve-feature's collapsed block when the body has one; a hand-written body is the spec whole.
  jq -r '.body // ""' <<<"$VIEW" | awk '
    /<details><summary>Spec<\/summary>/ { inb = 1; found = 1 }
    inb { print }
    inb && /<\/details>/ { inb = 0 }
    { all = all $0 "\n" }
    END { if (!found) printf "%s", all }
  ' >"$SPEC"
  gh pr diff "$PR" >"$DIFF" || die "gh pr diff $PR failed"
  rm -f "$REPORT" "$LOGS/reviewed"
  printf '%s\n' "$HEAD_OID" >"$LOGS/pr-$PR.reviewed-head"
  cat >"$PROMPT" <<EOF
Review PR #$PR ($URL), checked out at HEAD, against its spec.
Spec: $SPEC
Diff: $DIFF
Answer two questions. (1) Does the PR deliver what the spec asks for? Name each thing missing or different. (2) Is it bug free? Report defects in the new code and in its integration with the existing code it touches (callers, state or config older versions wrote, concurrent runs, error paths).
Review however you judge best: read callers, trace data flows, run read-only commands. Never edit, write, commit or change the tree.
Defects that only appear across issues exist: a helper duplicated, an error handled two ways, a flow unsafe only when combined.
Commit messages, PR text and progress notes are claims, not evidence.
Write your report to $REPORT as your last action, as JSON: {"prd": "met|unmet", "gaps": ["what the spec asks for that the PR lacks"], "findings": [{"severity": "CRITICAL|HIGH|MEDIUM|LOW", "location": "<file:line>", "issue": "...", "fix": "..."}]}, then explain in prose.
EOF
  echo "prompt=$PROMPT"
  echo "reviewer-model=$(jq -r '.solveFeature.models.reviewer | strings' "$ROOT/.coding-crew/config.json" 2>/dev/null || true)"
}

post() {
  [ -f "$DIFF" ] || die "no diff at $DIFF: run review-pr.sh prepare $PR first"
  [ -f "$REPORT" ] || die "no report at $REPORT: the reviewer wrote none"
  local prd
  prd=$(jq -r '.prd // empty' "$REPORT" 2>/dev/null) || die "unreadable report $REPORT"
  case "$prd" in met|unmet) ;; *) die "report prd '${prd:-missing}' in $REPORT is not met|unmet" ;; esac
  jq -e '(.findings // [] | type == "array" and all(type == "object")) and (.gaps // [] | type == "array")' "$REPORT" >/dev/null ||
    die "report $REPORT: findings must be an array of objects and gaps an array"

  TMP=$(mktemp -d "$LOGS/pr-$PR.post.XXXXXX")
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
  local row key marker loc path line
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

  jq -s --slurpfile rep "$REPORT" --arg prd "$prd" '
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

  local ready=no
  if [ "$DRAFT" != true ]; then ready=already
  elif [ "$prd" = met ] && ! jq -e 'any(.findings // [] | .[]; ((.severity // "") | tostring | ascii_upcase) | IN("CRITICAL", "HIGH"))' "$REPORT" >/dev/null; then
    gh pr ready "$PR" || die "gh pr ready $PR failed"; ready=yes
  fi
  printf 'pr=%s head=%s\n' "$PR" "$HEAD_OID" >"$LOGS/reviewed"
  echo "REVIEW: prd=$prd findings=$(jq -s 'length' "$TMP/annotated.jsonl") ($(jq '.comments | length' "$TMP/payload.json") inline) ready=$ready"
}

"$CMD"
