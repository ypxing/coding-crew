#!/usr/bin/env bash
set -euo pipefail

# promote-findings.sh — the deterministic half of findings promotion (policy:
# references/findings-promotion.md); the orchestrator keeps the reasoning half.
# Usage: promote-findings.sh <defer|defer-integration|flush|list|open|remind|mark-not-run> [options]
# Every subcommand prints a greppable first token and exits 0 unless invoked wrongly: callers
# branch on the text, so "nothing to do" never looks like a failure mid-sprint.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_ROOT="${MAIN_ROOT:-$PWD}"
# Sprint files (.scratch/<slug>/…) live in the main checkout, whichever worktree this is run from.
cd "$MAIN_ROOT" || { echo "promote-findings.sh: cannot enter MAIN_ROOT $MAIN_ROOT" >&2; exit 1; }
# Each subcommand traces its own outcome, so the trace never depends on the orchestrator echoing it.
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" ${FEATURE_SLUG:+--feature-slug "$FEATURE_SLUG"} "$@" 2>/dev/null || true; return 0; }

# review_rollup <report-file>... — the one parser of the reviewer's aggregate report, shared with
# crew-summary.sh; an unreachable CLI degrades to no branches. $CREW_REVIEW_ROLLUP overrides the lookup.
review_rollup() {
  local node_cli="${CREW_REVIEW_ROLLUP:-}"
  [ -f "$node_cli" ] || node_cli="$MAIN_ROOT/.coding-crew/crew-afk/review-rollup.mjs"
  [ -f "$node_cli" ] || node_cli="$HOME/.coding-crew/crew-afk/review-rollup.mjs"
  if [ -f "$node_cli" ] && command -v node >/dev/null 2>&1; then
    node "$node_cli" "$@" 2>/dev/null || echo '{"branches":[]}'
  else
    echo '{"branches":[]}'
  fi
}

# $CREW_TRACKER_CLI overrides the lookup, for fixtures that exercise this script alone.
# shellcheck source=tracker-cli.sh
. "$SCRIPT_DIR/tracker-cli.sh"
resolve_tracker_cli "$MAIN_ROOT" || exit 1

DEFERRED_STATUS="deferred-findings"
READY_STATUS="ready-for-agent"

# The orchestrator resolves afk.fixFindings and passes --severities; no level table lives here.
need_severities() {
  echo "promote-findings.sh $1: missing required argument --severities <list>" >&2
  exit 2
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  promote-findings.sh defer --feature-slug <slug> --branch <branch> --slug <issue-slug>
                            --title <title> --report <review-report> --criteria-file <file>
                            --severities <list> [--blocked-by <issue-number>]
  promote-findings.sh defer-integration --feature-slug <slug> --report <integration-verify-output>
                            --criteria-file <file> [--at <commit>]
  promote-findings.sh flush --feature-slug <slug>
  promote-findings.sh list  --feature-slug <slug>
  promote-findings.sh open  --feature-slug <slug>
  promote-findings.sh remind --feature-slug <slug>
  promote-findings.sh mark-not-run --feature-slug <slug> --branch <branch> --slug <issue-slug>
                            --report <review-report> --reason <text>
USAGE
  exit 1
}

die() {
  echo "ERROR: $1" >&2
  exit 1
}

# Portable in-place edit: BSD sed reads the argument after a bare `-i` as a backup suffix.
sed_inplace() {
  local script="$1" file="$2" tmp="${2}.tmp.$$"
  sed "$script" "$file" > "$tmp"
  mv "$tmp" "$file"
}

issues_open_dir() {
  echo ".scratch/$1/issues/open"
}

# Next NN prefix, scanning done/ too so a number is never reused.
next_issue_number() {
  local slug="$1" max=0 n f
  for f in ".scratch/$slug/issues/open"/*.md ".scratch/$slug/issues/done"/*.md; do
    [ -f "$f" ] || continue
    n=$(basename "$f" | sed -n 's/^\([0-9][0-9]*\)-.*/\1/p')
    [ -n "$n" ] || continue
    n=$((10#$n))
    [ "$n" -gt "$max" ] && max="$n"
  done
  printf '%02d' $((max + 1))
}


# count_criteria <criteria-file> — one `- [ ]` line per promoted finding (or queued gap).
count_criteria() { grep -c '^- \[' "$1" 2>/dev/null || true; }

# _defer_local <slug> <issue-slug> <title> <criteria-file> <severities> — prints the new file's path.
_defer_local() {
  local slug="$1" issue_slug="$2" title="$3" criteria_file="$4" severities="$5" branch="$6"
  local open_dir num issue_path
  open_dir=$(issues_open_dir "$slug")
  mkdir -p "$open_dir"
  num=$(next_issue_number "$slug")
  issue_path="$open_dir/$num-fix-findings-$issue_slug.md"

  # Not ready-for-agent: the loop selects on that, so a parked issue stays invisible until flush and
  # cannot compete with in-flight Phase 1 issues over the same files.
  {
    echo "# $title"
    echo ""
    echo "Status: $DEFERRED_STATUS"
    echo "Source: $report ($branch)"
    echo ""
    echo "## Context"
    echo ""
    echo "Auto-promoted by crew-afk from the $severities findings raised against \`$branch\`."
    echo "The branch already merged — these are follow-up fixes, not a revert. Full reviewer"
    echo "notes, including the snippet citations, are in the review report named in \`Source:\`."
    echo ""
    echo "## Acceptance criteria"
    echo ""
    cat "$criteria_file"
  } > "$issue_path"

  echo "$issue_path"
}

_github_tracker_cli() {
  node "$TRACKER_CLI" "$@"
}

# A github fix issue is read where the sprint's checkout does not exist and .scratch/ is never
# pushed, so its body carries the evidence itself, never a local path.
FINDINGS_MAX_BYTES=30000   # all embedded review findings; GitHub caps a body at 65536
EVIDENCE_MAX_BYTES=8000    # the failing output's tail
FINDING_MAX_LINES=60       # one finding's prose

# _scrub_paths — absolute and .scratch/ paths made relative or reduced: a body must not leak a
# username or a directory layout.
_scrub_paths() {
  local p='[^[:space:]:)"'"'"'`,;/]+'
  sed -e "s#${MAIN_ROOT%/}/##g" -e "s#${PWD%/}/##g" \
    | sed -E \
      -e "s#(^|[^[:alnum:]_.~/-])/(Users|home|root|private|var|tmp|opt|mnt|srv|workspace|builds)(/$p)*/($p)#\\1<path>/\\4#g" \
      -e "s#(^|[^[:alnum:]_.~/-])(\\.?[[:alnum:]_.-]+/)*\\.scratch(/$p)*/($p)#\\1<scratch>/\\4#g" \
      -e 's#\.scratch/#scratch/#g'
}

# _review_branch_prose <report> <branch> — the prose of the branch's last block in the review
# report (a retry's block overrides an earlier one, as review_rollup folds), minus its json.
_review_branch_prose() {
  awk -v branch="$2" '
    index($0, "Branch: " branch " (") && $0 ~ /^[ \t]*#+ / { inb = 1; buf = ""; skip = 0; fence = ""; next }
    inb && fence == "" && $0 ~ /^## / { inb = 0 }
    !inb { next }
    skip { if ($0 ~ /^[ \t]*```[ \t]*$/) skip = 0; next }
    fence == "" && $0 ~ /^[ \t]*```json/ { skip = 1; next }
    # A snippet fence can hold a column-0 `#`/`##` line (a shell or python comment): inside
    # one, nothing is a heading, so the block is not cut short.
    { if (match($0, /^[ \t]*(~~~|```)/)) { m = substr($0, RSTART, RLENGTH); gsub(/[ \t]/, "", m); if (fence == "") fence = m; else if (fence == m) fence = "" }
      buf = buf $0 "\n" }
    END { printf "%s", buf }
  ' "$1"
}

# _review_findings_md <report> <branch> <severities> — markdown for the findings `defer` promotes,
# each prose block in a <details>; under `actionable`, the blocks whose location triage judged
# actionable. With no block to keep, the json's one-line findings are listed. A `report_only`
# block is dropped only on an exact severity + File: match, so a promoted finding there keeps its own.
_review_findings_md() {
  local report="$1" branch="$2" severities="$3" locs="" sevs="" ro rollup
  rollup="$(review_rollup "$report")"
  ro="$(jq -r --arg b "$branch" '.branches[] | select(.branch == $b) | .findings[]? | select(.report_only == true) | select(.location != "") | "\(.severity)\t\(.location)"' <<< "$rollup" 2>/dev/null || true)"
  if [ "$severities" = "actionable" ]; then
    locs="$(jq -r --arg b "$branch" '.branches[] | select(.branch == $b) | .findings[]? | select(.verdict == "actionable") | .location | split(", ")[]' <<< "$rollup" 2>/dev/null || true)"
  else
    sevs="$(printf '%s' "$severities" | tr -d ' ')"
  fi

  local out
  # locs is one location per line: passed through the environment, since BSD awk rejects a newline in a -v value.
  out="$(_review_branch_prose "$report" "$branch" | PF_LOCS="$locs" PF_RO="$ro" awk -v sevs="$sevs" \
      -v maxb="$FINDINGS_MAX_BYTES" -v maxl="$FINDING_MAX_LINES" '
    BEGIN { locs = ENVIRON["PF_LOCS"]; ro = ENVIRON["PF_RO"] }
    # has(s, loc): s names loc, not a longer location it prefixes (src/x.ts:4 within src/x.ts:41).
    function has(s, loc,   p) {
      while ((p = index(s, loc)) > 0) {
        if (substr(s, p + length(loc), 1) !~ /[[:alnum:]_.]/) return 1
        s = substr(s, p + 1)
      }
      return 0
    }
    # fileloc(lines, n): the location on the File: line of the block, trimmed, backticks dropped.
    function fileloc(lines, n,   i, f) {
      for (i = 1; i <= n; i++) if (lines[i] ~ /^[ \t]*File:/) {
        f = lines[i]; sub(/^[ \t]*File:[ \t]*/, "", f); gsub(/`/, "", f); gsub(/^[ \t]+|[ \t]+$/, "", f); return f
      }
      return ""
    }
    function flush(   i, n, lines, m, L, ok, title, body, fences, entry, floc) {
      if (blk == "") return
      n = split(blk, lines, "\n")
      if (sevs != "") ok = (index("," sevs ",", "," sev ",") > 0)
      else if (locs != "") { ok = 0; m = split(locs, L, "\n"); for (i = 1; i <= m; i++) if (L[i] != "" && has(blk, L[i])) ok = 1 }
      else ok = 1
      if (ok && ro != "") { floc = fileloc(lines, n); m = split(ro, L, "\n"); for (i = 1; i <= m; i++) if (L[i] != "" && L[i] == sev "\t" floc) ok = 0 }
      if (ok) {
        title = lines[1]; gsub(/^[ \t]+|[ \t]+$/, "", title)
        gsub(/&/, "\\&amp;", title); gsub(/</, "\\&lt;", title); gsub(/>/, "\\&gt;", title)
        body = ""; fences = 0
        for (i = 1; i <= n && i <= maxl; i++) { body = body lines[i] "\n"; if (lines[i] ~ /^[ \t]*~~~/) fences++ }
        if (n > maxl) body = body "(… " (n - maxl) " more lines trimmed)\n"
        if (fences % 2) body = body "~~~\n"
        entry = "<details>\n<summary>" title "</summary>\n\n" body "\n</details>\n\n"
        if (total + length(entry) > maxb && emitted > 0) dropped++
        else { printf "%s", entry; total += length(entry); emitted++ }
      }
      blk = ""; fence = ""
    }
    # Lines inside a snippet fence belong to the block whatever they start with.
    blk != "" && fence != "" { blk = blk $0 "\n"; if (match($0, /^[ \t]*(~~~|```)/)) { m = substr($0, RSTART, RLENGTH); gsub(/[ \t]/, "", m); if (m == fence) fence = "" } next }
    /^[ \t]*\[(CRITICAL|HIGH|MEDIUM|LOW)\]/ { flush(); sev = $0; sub(/^[ \t]*\[/, "", sev); sub(/\].*/, "", sev); blk = $0 "\n"; next }
    /^#+ / { flush(); next }
    blk != "" { blk = blk $0 "\n"; if (match($0, /^[ \t]*(~~~|```)/)) { m = substr($0, RSTART, RLENGTH); gsub(/[ \t]/, "", m); fence = m } }
    END { flush(); if (dropped) printf "(%d more finding(s) trimmed to keep this issue within GitHub size limits)\n", dropped }
  ')"

  if [ -z "$out" ]; then
    out="$(jq -r --arg b "$branch" --arg sevs "$sevs" --arg locs "$locs" '
      ($locs | split("\n")) as $l
      | .branches[] | select(.branch == $b) | .findings[]?
      | select(.report_only != true)
      | .severity as $s
      | select(if $sevs != "" then ((","+$sevs+",") | contains(","+$s+","))
               elif $locs != "" then (.location as $x | any($l[]; . != "" and . == $x))
               else true end)
      | "- **[\(.severity)]** `\(.location)` — \(.criterion)"' <<< "$rollup" 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

_tail_fenced() {
  [ -f "$1" ] || return 0
  local tail_text
  tail_text="$(tail -c "$EVIDENCE_MAX_BYTES" "$1")"
  [ -n "$tail_text" ] || return 0
  printf '````\n%s\n````\n' "$tail_text"
}

# _defer_github <slug> <title> <branch> <report> <criteria-file> <severities> <blocked-by> — labeled
# ready-for-agent at once: github has no "parked" label, so flush and list have nothing to do there.
# `Source:` names kind and branch so parseIssue reads it like local's. Prints the issue's URL.
_defer_github() {
  local slug="$1" title="$2" branch="$3" report="$4" criteria_file="$5" severities="$6" blocked_by="$7"

  local body_file findings
  body_file="$(mktemp)"
  findings="$(_review_findings_md "$report" "$branch" "$severities")"
  {
    echo "Source: review ($branch)"
    if [ -n "$blocked_by" ]; then
      echo ""
      echo "## Blocked by"
      echo ""
      echo "- Issue #$blocked_by"
    fi
    echo ""
    echo "## Context"
    echo ""
    echo "Auto-promoted by crew-afk from the $severities findings raised against \`$branch\`."
    echo "The branch already merged — these are follow-up fixes, not a revert. The reviewer's"
    echo "full notes for each finding, including the snippet citations, are under"
    echo "\`## Review findings\` below."
    echo ""
    echo "## Acceptance criteria"
    echo ""
    cat "$criteria_file"
    if [ -n "$findings" ]; then
      echo ""
      echo "## Review findings"
      echo ""
      printf '%s\n' "$findings"
    fi
  } | _scrub_paths > "$body_file"

  local issue_ref
  if ! issue_ref=$(_github_tracker_cli create-issue --title "$title" --body-file "$body_file" \
      --feature-slug "$slug" --label "$READY_STATUS" --main-root "$MAIN_ROOT"); then
    rm -f "$body_file"
    die "gh issue create failed for: $title"
  fi
  rm -f "$body_file"
  echo "$issue_ref"
}

cmd_defer() {
  local slug="" branch="" issue_slug="" title="" report="" criteria_file="" severities="" blocked_by="" have_sev=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature-slug) slug="${2:-}"; shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --slug) issue_slug="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --report) report="${2:-}"; shift 2 ;;
      --criteria-file) criteria_file="${2:-}"; shift 2 ;;
      --severities) severities="${2:-}"; have_sev=1; shift 2 ;;
      --blocked-by) blocked_by="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$branch" ] && [ -n "$issue_slug" ] || usage
  [ -n "$title" ] && [ -n "$report" ] && [ -n "$criteria_file" ] || usage
  [ "$have_sev" -eq 1 ] && [ -n "$severities" ] || need_severities defer
  [ -f "$criteria_file" ] || die "criteria file not found: $criteria_file"
  [ -f "$report" ] || die "review report not found: $report"
  [ -s "$criteria_file" ] || die "criteria file is empty: $criteria_file (nothing to promote)"

  local ref
  if [ "$TRACKER_KIND" = "github" ]; then
    ref="$(_defer_github "$slug" "$title" "$branch" "$report" "$criteria_file" "$severities" "$blocked_by")"
  else
    ref="$(_defer_local "$slug" "$issue_slug" "$title" "$criteria_file" "$severities" "$branch")"
  fi

  # Mark the report so /crew-address-findings skips what this sprint fixed. Promotion takes every
  # finding at those severities for the branch, so (branch, severity) is an unambiguous key.
  if ! grep -q '^## Promoted Findings' "$report"; then
    {
      echo ""
      echo "## Promoted Findings"
      echo ""
      echo "Auto-promoted to fix issues by crew-afk and implemented later in this same sprint."
      echo "Skip these when triaging: every finding at the listed severities for the listed"
      echo "branch is already addressed — or, where the line says 'actionable', every finding of"
      echo "that branch whose verdict is actionable. Everything else still needs triage."
      echo ""
    } >> "$report"
  fi
  # The count rides on the marker: the summary makes no network call to read a github ref back.
  local n
  n=$(count_criteria "$criteria_file")
  echo "- $branch: $severities → $ref ($n finding(s))" >> "$report"

  _trace PROMOTE "branch=$branch issue=$ref severities=$severities findings=$n"
  echo "defer: $ref"
}

# A fix issue from no reviewed branch: a red integration check on the merged feature branch that
# triage judged fixable. Its `Source:` line is the depth bound. The caller bounds how many a run
# creates; this refuses a second while one is open. A github body carries the failing tail.
_defer_feature_issue() {
  local command="$1" slug="$2" report="$3" criteria_file="$4" title="$5" source_tag="$6"
  local suffix="$7" label="$8" context="$9" github_context="${10}" numbered="${11:-}" ref

  if [ "$TRACKER_KIND" = "github" ]; then
    local body_file evidence source_name="integration check" evidence_heading="Failing output (tail)"
    body_file="$(mktemp)"
    evidence="$(_tail_fenced "$report")"
    {
      printf 'Source: %s (%s)\n\n## Context\n\n%s\n\n## Acceptance criteria\n\n' "$source_name" "$source_tag" "$github_context"
      cat "$criteria_file"
      if [ -n "$evidence" ]; then
        printf '\n## %s\n\n%s\n' "$evidence_heading" "$evidence"
      fi
    } | _scrub_paths > "$body_file"
    if ! ref=$(_github_tracker_cli create-issue --title "$title" --body-file "$body_file" \
        --feature-slug "$slug" --label "$READY_STATUS" --main-root "$MAIN_ROOT"); then
      rm -f "$body_file"
      die "gh issue create failed for: $title"
    fi
    rm -f "$body_file"
  else
    local open_dir existing f
    open_dir=$(issues_open_dir "$slug")
    mkdir -p "$open_dir"
    # A numbered kind gets a new slug each time: a reused one would read as the earlier, finished issue.
    local pattern="*-$suffix.md" name="$suffix"
    if [ -n "$numbered" ]; then
      local k=1
      for f in "$open_dir"/*-"$suffix"-[0-9]*.md ".scratch/$slug/issues/done"/*-"$suffix"-[0-9]*.md; do
        [ -f "$f" ] && k=$((k + 1))
      done
      pattern="*-$suffix-[0-9]*.md"
      name="$suffix-$k"
    fi
    for f in "$open_dir"/$pattern; do
      [ -f "$f" ] && existing="$f"
    done
    if [ -n "${existing:-}" ]; then
      echo "$command: skip — already queued: $existing"
      return 0
    fi
    ref="$open_dir/$(next_issue_number "$slug")-$name.md"
    {
      echo "# $title"
      echo ""
      echo "Status: $DEFERRED_STATUS"
      echo "Source: $report ($source_tag)"
      echo ""
      echo "## Context"
      echo ""
      echo "$context"
      echo ""
      echo "## Acceptance criteria"
      echo ""
      cat "$criteria_file"
    } > "$ref"
  fi

  _trace PROMOTE "$label issue=$ref findings=$(count_criteria "$criteria_file")"
  echo "$command: $ref"
}

# _feature_issue_args <command> <args...> — sets slug, report and criteria_file in the caller.
_feature_issue_args() {
  slug="" report="" criteria_file=""
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature-slug) slug="${2:-}"; shift 2 ;;
      --report) report="${2:-}"; shift 2 ;;
      --criteria-file) criteria_file="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$report" ] && [ -n "$criteria_file" ] || usage
  [ -s "$criteria_file" ] || die "criteria file is empty: $criteria_file (nothing to queue)"
}

cmd_defer_integration() {
  local slug report criteria_file at=""
  # --at names the failing tip, keeping each fix issue's title (and github slug) unique across drains.
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --at) at="${2:-}"; shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
  _feature_issue_args defer-integration "${args[@]}"
  _defer_feature_issue defer-integration "$slug" "$report" "$criteria_file" \
    "Fix integration check: $slug${at:+ (at $at)}" integration fix-integration integration "Auto-queued by crew-afk: every branch passed its own checks, but the project's checks fail
on the merged feature branch, and triage judged the failure fixable by a code change. No review
saw the branches together. The failing output is in the report named in \`Source:\`." "Auto-queued by crew-afk: every branch passed its own checks, but the project's checks fail
on the merged feature branch, and triage judged the failure fixable by a code change. No review
saw the branches together. The tail of the failing output is under \`## Failing output (tail)\`
below." numbered
}

# Phase 1 → Phase 2. Rewriting Status on disk makes this idempotent and crash-safe: an interrupted
# sprint resumes with the fix issues already ready-for-agent.
cmd_flush() {
  local slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature-slug) slug="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage

  # github's defer never parks an issue, so there is nothing to promote.
  if [ "$TRACKER_KIND" = "github" ]; then
    _trace FLUSH "promoted=0"
    echo "FLUSH: none"
    return
  fi

  local open_dir count=0 f
  open_dir=$(issues_open_dir "$slug")

  for f in "$open_dir"/*.md; do
    [ -f "$f" ] || continue
    grep -q "^Status: *$DEFERRED_STATUS" "$f" || continue
    sed_inplace "s/^Status: *$DEFERRED_STATUS.*/Status: $READY_STATUS/" "$f"
    echo "flushed: $f"
    count=$((count + 1))
  done

  if [ "$count" -eq 0 ]; then
    _trace FLUSH "promoted=0"
    echo "FLUSH: none"
  else
    _trace FLUSH "promoted=$count"
    echo "FLUSH: promoted=$count"
  fi
}

cmd_list() {
  local slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature-slug) slug="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage

  # As in cmd_flush: github never has a parked issue.
  if [ "$TRACKER_KIND" = "github" ]; then
    echo "DEFERRED: none"
    return
  fi

  local open_dir count=0 f
  open_dir=$(issues_open_dir "$slug")
  for f in "$open_dir"/*.md; do
    [ -f "$f" ] || continue
    grep -q "^Status: *$DEFERRED_STATUS" "$f" || continue
    echo "deferred: $f"
    count=$((count + 1))
  done
  [ "$count" -eq 0 ] && echo "DEFERRED: none" || echo "DEFERRED: count=$count"
}

# A dead review dispatch leaves no report, which `remind` would read as an all-clear. A `not_run`
# stub records the gap so it survives into the end-of-sprint reminder.
cmd_mark_not_run() {
  local slug="" branch="" issue_slug="" report="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature-slug) slug="${2:-}"; shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --slug) issue_slug="${2:-}"; shift 2 ;;
      --report) report="${2:-}"; shift 2 ;;
      --reason) reason="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$branch" ] && [ -n "$issue_slug" ] || usage
  [ -n "$report" ] && [ -n "$reason" ] || usage

  mkdir -p "$(dirname "$report")"

  # Idempotent: a retried dispatch that fails twice must not double-count the branch.
  if [ -f "$report" ] && grep -q "^## Branch: $branch (" "$report"; then
    echo "mark-not-run: already recorded — $branch"
    return 0
  fi

  # jq -n builds the JSON safely whatever $reason contains.
  local json_block
  json_block=$(jq -n --arg branch "$branch" --arg slug "$issue_slug" --arg reason "$reason" \
    '{branch: $branch, slug: $slug, verdict: "not_run", detail: $reason, findings: []}')

  {
    [ -s "$report" ] && echo ""
    echo "## Branch: $branch ($issue_slug)"
    echo ""
    echo '```json'
    echo "$json_block"
    echo '```'
    echo ""
    echo "Review: not_run — $reason"
    echo ""
    echo "### Findings"
    echo ""
    echo "None recorded. The code review for this branch did not complete, so the branch was"
    echo "merged unreviewed. This is a coverage gap, not a clean review: no conclusion about"
    echo "this branch's security, quality, or correctness can be drawn from its absence of"
    echo "findings. Review it manually, or re-run the reviewer against the merged range."
  } >> "$report"

  _trace --level warn REVIEW "branch=$branch result=not_run"
  echo "mark-not-run: not_run recorded — $branch ($reason)"
}

# open_findings_json <rollup-json> <report>... — every finding minus what a fix issue covers: the
# (branch, severity) pairs in defer's own "## Promoted Findings" bullets, or under `actionable` a
# branch's triage-actionable findings. `report_only` findings are never covered. Prints a JSON array;
# `carried: true` marks a finding an earlier review raised and the latest did not repeat.
open_findings_json() {
  local rollup="$1" promoted
  shift
  # grep's own "no lines matched" status must not reach the pipeline under `pipefail`.
  promoted=$( (grep -h '^- .*:.*→' "$@" 2>/dev/null || true) | jq -R -s '
    [splits("\n") | select(length > 0) |
      (capture("^- *(?<b>[^:]+): *(?<sevs>[^→]+)→")?) |
      select(. != null) |
      {branch: (.b | rtrimstr(" ")), sevs: [.sevs | splits(", *") | gsub("^\\s+|\\s+$"; "") | select(length > 0)]}
    ]
  ' 2>/dev/null || echo '[]')
  jq -n --argjson rollup "$rollup" --argjson promoted "$promoted" '
    ($promoted | map(.branch as $b | .sevs[] as $s | {(($b + " " + $s)): true}) | add // {}) as $pset
    | [$rollup.branches[] | .branch as $b | .findings[]
       | select((.report_only == true)
                 or ((($pset[$b + " " + .severity] // false)
                 or ((.verdict // "") == "actionable" and ($pset[$b + " actionable"] // false))) | not))
       | {branch: $b, severity, location: (.location // ""), issue: (.issue // ""), criterion: (.criterion // ""),
          verdict: (.verdict // ""), rationale: (.rationale // "")}
          + (if .carried == true then {carried: true} else {} end)]
  '
}

# The open findings as JSON, for post-findings.sh. `[]` when there is nothing.
cmd_open() {
  local slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature-slug) slug="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage
  local reports=() f
  for f in ".scratch/$slug/reviews"/*.md; do
    [ -f "$f" ] && reports+=("$f")
  done
  if [ "${#reports[@]}" -eq 0 ]; then echo '[]'; return 0; fi
  open_findings_json "$(review_rollup "${reports[@]}")" "${reports[@]}"
}

# verdict_lines <verdict> <HEADING> <note> — open findings (JSON on stdin) with that verdict:
# "HEADING: n (note)", then one line each. Prints nothing when there are none.
verdict_lines() {
  local verdict="$1" heading="$2" note="$3" json n
  json=$(cat)
  n=$(jq --arg v "$verdict" '[.[] | select(.verdict == $v)] | length' <<< "$json")
  [ "${n:-0}" -gt 0 ] || return 0
  echo "$heading: $n ($note)"
  jq -r --arg v "$verdict" --arg h "$(printf '%s' "$heading" | tr '[:upper:]' '[:lower:]')" '
    .[] | select(.verdict == $v)
    | "\($h): \(.branch) [\(.severity)] \(.location) — \(.criterion)\(if .carried == true then " (earlier review)" else "" end)\(if .rationale != "" then " — why: " + .rationale else "" end)"
  ' <<< "$json"
}

# Counts what still needs a human — findings promotion did not take (Debatable, Dismissed,
# severities left out, anything on a Phase 2 fix branch) — so the reminder states a real number.
# Review gaps (`Review: not_run`) carry no findings but are always printed: omitting them is the
# silent all-clear this exists to prevent.
cmd_remind() {
  local slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature-slug) slug="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage

  local reports=() f
  for f in ".scratch/$slug/reviews"/*.md; do
    [ -f "$f" ] && reports+=("$f")
  done

  if [ "${#reports[@]}" -eq 0 ]; then
    echo "FINDINGS: none"
    return 0
  fi

  local rollup open_json
  rollup=$(review_rollup "${reports[@]}")
  open_json=$(open_findings_json "$rollup" "${reports[@]}")

  local totals crit high med low total breakdown
  # Dismissed findings are counted apart, outside the total.
  totals=$(jq -r '
    map(select(.verdict != "dismiss")) as $o
    | [($o | map(select(.severity == "CRITICAL")) | length),
       ($o | map(select(.severity == "HIGH")) | length),
       ($o | map(select(.severity == "MEDIUM")) | length),
       ($o | map(select(.severity == "LOW")) | length)] | @tsv
  ' <<< "$open_json")
  IFS=$'\t' read -r crit high med low <<< "$totals"
  total=$((crit + high + med + low))
  breakdown=""
  [ "$crit" -gt 0 ] && breakdown="${breakdown:+$breakdown, }CRITICAL=$crit"
  [ "$high" -gt 0 ] && breakdown="${breakdown:+$breakdown, }HIGH=$high"
  [ "$med" -gt 0 ] && breakdown="${breakdown:+$breakdown, }MEDIUM=$med"
  [ "$low" -gt 0 ] && breakdown="${breakdown:+$breakdown, }LOW=$low"

  local dismissed
  dismissed=$(jq '[.[] | select(.verdict == "dismiss")] | length' <<< "$open_json")
  if [ "$total" -eq 0 ]; then
    echo "FINDINGS: none"
    if [ "${dismissed:-0}" -gt 0 ]; then
      verdict_lines dismiss DISMISSED "triage's rationale, collapsed" <<< "$open_json"
      printf 'report: %s\n' "${reports[@]}"
    fi
  else
    echo "FINDINGS: open=$total ($breakdown)"
    # Debatable first. An Actionable one still open failed to queue its fix issue; untriaged findings
    # get no line.
    verdict_lines debatable DEBATABLE "decide these first" <<< "$open_json"
    verdict_lines actionable ACTIONABLE "not promoted" <<< "$open_json"
    verdict_lines dismiss DISMISSED "triage's rationale, collapsed" <<< "$open_json"
    # Untriaged carried findings, already in the total, get their own line.
    jq -r '.[] | select(.carried == true and .verdict == "")
      | "earlier: \(.branch) [\(.severity)] \(.location) — \(.criterion) (earlier review)"' <<< "$open_json"
    printf 'report: %s\n' "${reports[@]}"
  fi

  # Never suppressed: zero findings plus an unreviewed branch must not look clean. review_rollup
  # already folded a retried verdict over a not_run stub, so no entry here is stale.
  local gaps gap_count
  gaps=$(jq -r '.branches[] | select(.verdict == "not_run") | [.branch, (.detail // "")] | @tsv' <<< "$rollup")
  gap_count=0
  [ -n "$gaps" ] && gap_count=$(printf '%s\n' "$gaps" | grep -c . || true)

  if [ "${gap_count:-0}" -gt 0 ]; then
    echo "REVIEW-GAPS: branches=$gap_count"
    printf '%s\n' "$gaps" | while IFS=$'\t' read -r branch reason; do
      echo "gap: $branch — $reason"
    done
    # With no findings, the gaps are the only reason to name the report.
    if [ "$total" -eq 0 ] && [ "${dismissed:-0}" -eq 0 ]; then
      printf 'report: %s\n' "${reports[@]}"
    fi
  fi
}

COMMAND="${1:-}"
[ -n "$COMMAND" ] || usage
shift || true

case "$COMMAND" in
  defer) cmd_defer "$@" ;;
  defer-integration) cmd_defer_integration "$@" ;;
  flush) cmd_flush "$@" ;;
  list)  cmd_list "$@" ;;
  open) cmd_open "$@" ;;
  remind) cmd_remind "$@" ;;
  mark-not-run) cmd_mark_not_run "$@" ;;
  *) usage ;;
esac
