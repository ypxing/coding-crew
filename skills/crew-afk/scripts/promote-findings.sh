#!/usr/bin/env bash
set -euo pipefail

# promote-findings.sh — mechanical half of findings promotion for crew-afk
#
# Findings promotion turns actionable code-review findings into fix issues that the
# existing sprint loop implements in a second phase. See references/findings-promotion.md
# for the full policy (severity threshold, grouping, depth bound, phases).
#
# This script owns only the deterministic parts, so all four platform variants behave
# identically:
#
#   (the severity list comes from the orchestrator as --severities; no level table here)
#   defer   — write a parked fix issue (Status: deferred-findings) + annotate the review report
#   defer-gaps — the same for the PRD audit's ✗ missing requirements: one parked issue
#   defer-integration — the same for a fixable red integration check on the merged feature branch
#   flush   — flip every parked fix issue to ready-for-agent (Phase 1 → Phase 2 transition)
#   list    — list parked fix issues without changing anything
#   open    — the open findings as JSON (what remind counts)
#   remind  — count findings still needing human triage, for the end-of-sprint reminder
#   mark-not-run — record that a branch's review never completed, so the gap is visible
#
# The reasoning half (reading the review, deciding which findings are CRITICAL/HIGH,
# restating each as an acceptance criterion) stays with the orchestrator.
#
# Every subcommand prints a machine-greppable first token and exits 0 unless the
# invocation itself was wrong. Callers branch on the printed text, never on exit codes,
# so a "nothing to do" outcome can never look like a failure mid-sprint.
#
# Invocation: bash "<skill-dir>/scripts/promote-findings.sh" <command> [options]
# (install.sh does not chmod+x skill-local scripts)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_ROOT="${MAIN_ROOT:-$PWD}"
# Each subcommand traces its own outcome, so promotion, the phase flip and a review gap
# are all in the trace whether or not the orchestrator remembered to echo them.
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null; return 0; }

# review_rollup <report-file>... — the one parser of the reviewer's aggregate report
# file(s), shared with crew-summary.sh's code_review_summary(). See
# orchestrator/lib/report.mjs's parseReviewAggregate doc comment: this used to be a
# hand-rolled, line-anchored awk in each of the two scripts, and they drifted apart on
# how much whitespace a herdr-captured review header could carry before neither matched
# it. Prints {"branches": [...]} to stdout; an unreachable CLI degrades to no branches
# rather than erroring the reminder. $CREW_REVIEW_ROLLUP overrides the lookup — bats
# fixtures set it to the repo's own orchestrator/review-rollup.mjs, since they exercise
# this script alone, not a full install.
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

# Which backend (local|github) this repo tracks issues in, and its optional --repo
# override — read once, the same lookup-chain shape review_rollup() uses above.
# $CREW_TRACKER_CONFIG overrides the lookup for bats fixtures that exercise this script
# alone, not a full install. Fails safe to local when the reader is missing entirely — an
# in-between install state (this script updated, tracker-config.sh not yet installed)
# must not break the local path.
TRACKER_CONFIG_TRACKER="local"
TRACKER_CONFIG_REPO=""
# BEGIN tracker-lookup — identical in every caller; tests/tracker-lookup.bats fails if one drifts.
# Where tracker-config.sh (and mark-issue-done.sh beside it) are looked for, first hit wins.
# It cannot live in tracker-config.sh itself: that is the file being looked for.
# Callers break on the first hit, closing the pipe while this may still be writing; where
# SIGPIPE is ignored that write fails with "Broken pipe", so it stops quietly instead.
tracker_config_candidates() {
  local main_root="$1" c
  for c in "${CREW_TRACKER_CONFIG:-}" \
    "${CREW_INSTALL_DIR:+$CREW_INSTALL_DIR/scripts/tracker-config.sh}" \
    "$main_root/.coding-crew/scripts/tracker-config.sh" \
    "$main_root/scripts/tracker/tracker-config.sh" \
    "${HOME:+$HOME/.coding-crew/scripts/tracker-config.sh}"; do
    if [ -n "$c" ]; then printf '%s\n' "$c" 2>/dev/null || return 0; fi
  done
  return 0
}
# END tracker-lookup
_tracker_config_sh=""
while IFS= read -r _tc; do
  if [ -f "$_tc" ]; then _tracker_config_sh="$_tc"; break; fi
done < <(tracker_config_candidates "$MAIN_ROOT")
if [ -n "$_tracker_config_sh" ]; then
  # shellcheck disable=SC1090
  source "$_tracker_config_sh"
  read_tracker_config "$MAIN_ROOT"
fi

DEFERRED_STATUS="deferred-findings"
READY_STATUS="ready-for-agent"

# --- promotion threshold -----------------------------------------------------
# The orchestrator resolves afk.fixFindings to the severities a sprint promotes
# (orchestrator/lib/report.mjs) and passes them as --severities: "actionable", or a list such as
# "CRITICAL, HIGH"; empty means nothing is promoted. This script keeps no level table of its own.
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
  promote-findings.sh defer-gaps --feature-slug <slug> --report <prd-audit-report>
                            --criteria-file <file>
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

# Portable in-place edit. GNU sed accepts a bare `-i`, but BSD/macOS sed reads the next
# argument as a backup suffix and then finds no script; `-i''` does not help because the
# shell strips the empty quotes. Temp file + mv works identically on both.
sed_inplace() {
  local script="$1" file="$2" tmp="${2}.tmp.$$"
  sed "$script" "$file" > "$tmp"
  mv "$tmp" "$file"
}

issues_open_dir() {
  echo ".scratch/$1/issues/open"
}

# Highest NN prefix across open/ and done/, +1, zero-padded to two digits. Both
# directories are scanned so a number is never reused after an issue is closed.
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

# --- defer -------------------------------------------------------------------

# count_criteria <criteria-file> — one `- [ ]` line per promoted finding (or queued gap).
count_criteria() { grep -c '^- \[' "$1" 2>/dev/null || true; }

# _defer_local <slug> <issue-slug> <title> <criteria-file> <severities> — unchanged: still
# hand-writes a numbered file under issues/open/. Prints the new file's path.
_defer_local() {
  local slug="$1" issue_slug="$2" title="$3" criteria_file="$4" severities="$5" branch="$6"
  local open_dir num issue_path
  open_dir=$(issues_open_dir "$slug")
  mkdir -p "$open_dir"
  num=$(next_issue_number "$slug")
  issue_path="$open_dir/$num-fix-findings-$issue_slug.md"

  # Status is deliberately NOT ready-for-agent: the loop's list operation selects on
  # ready-for-agent, so a parked issue is invisible until flush. That is what keeps
  # findings work from competing with in-flight Phase 1 issues over the same files.
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

# _github_tracker_cli <args...> — shells out to orchestrator/lib/trackers/github.mjs's own
# CLI, so `defer`'s github path calls the exact same `createIssue` (+ lazy, idempotent
# milestone bootstrap) every other GitHub write path uses, rather than a second hand-rolled
# `gh issue create` that can drift from it (it did: this script's own milestone bootstrap
# used to be missing entirely). Same lookup-chain shape as review_rollup() above.
# $CREW_GITHUB_TRACKER_CLI overrides the lookup for bats fixtures that exercise this script
# alone, not a full install.
_github_tracker_cli() {
  local node_cli="${CREW_GITHUB_TRACKER_CLI:-}"
  [ -f "$node_cli" ] || node_cli="$MAIN_ROOT/.coding-crew/crew-afk/lib/trackers/github.mjs"
  [ -f "$node_cli" ] || node_cli="$HOME/.coding-crew/crew-afk/lib/trackers/github.mjs"
  [ -f "$node_cli" ] || { echo "ERROR: github tracker CLI (github.mjs) not found" >&2; return 1; }
  node "$node_cli" "$@"
}

# --- github bodies embed their evidence --------------------------------------
# A github fix issue is read where the sprint's checkout does not exist, and the `.scratch/`
# reports are gitignored runtime bookkeeping that is never pushed. So under github the body
# carries the reviewer's / auditor's / verifier's content itself, and never a local path.
# (Local issues sit in the same checkout as the report and keep naming it in `Source:`.)
FINDINGS_MAX_BYTES=30000   # all embedded review findings; GitHub caps a body at 65536
EVIDENCE_MAX_BYTES=8000    # the audit's evidence / the failing output's tail
FINDING_MAX_LINES=60       # one finding's prose

# _scrub_paths — stdin → stdout with absolute filesystem paths and `.scratch/` paths made
# repo-relative or reduced to their last component. A body must not leak a username or a
# directory layout, and an embedded snippet or failing output can quote either.
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

# _review_findings_md <report> <branch> <severities> — markdown for the findings `defer`
# promotes: each one's full prose block (title, File:, Snippet:, Issue:, Fix:) in a <details>.
# <severities> is a list such as "CRITICAL, HIGH", or `actionable`, which keeps the blocks whose
# location the findings triage judged actionable (that verdict sits in the block's json, not its
# prose; a folded duplicate_of target's location lists both spots, each matched on its own). Where the prose has no block to keep, the json's one-line findings are listed instead,
# so a promoted finding is never absent from the body.
_review_findings_md() {
  local report="$1" branch="$2" severities="$3" locs="" sevs="" rollup
  rollup="$(review_rollup "$report")"
  if [ "$severities" = "actionable" ]; then
    locs="$(jq -r --arg b "$branch" '.branches[] | select(.branch == $b) | .findings[]? | select(.verdict == "actionable") | .location | split(", ")[]' <<< "$rollup" 2>/dev/null || true)"
  else
    sevs="$(printf '%s' "$severities" | tr -d ' ')"
  fi

  local out
  # locs is one location per line: passed through the environment, since BSD awk rejects a newline in a -v value.
  out="$(_review_branch_prose "$report" "$branch" | PF_LOCS="$locs" awk -v sevs="$sevs" \
      -v maxb="$FINDINGS_MAX_BYTES" -v maxl="$FINDING_MAX_LINES" '
    BEGIN { locs = ENVIRON["PF_LOCS"] }
    function flush(   i, n, lines, m, L, ok, title, body, fences, entry) {
      if (blk == "") return
      n = split(blk, lines, "\n")
      if (sevs != "") ok = (index("," sevs ",", "," sev ",") > 0)
      else if (locs != "") { ok = 0; m = split(locs, L, "\n"); for (i = 1; i <= m; i++) if (L[i] != "" && index(blk, L[i]) > 0) ok = 1 }
      else ok = 1
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
      | select(if $sevs != "" then ((","+$sevs+",") | contains(","+.severity+","))
               elif $locs != "" then (.location as $x | any($l[]; . != "" and . == $x))
               else true end)
      | "- **[\(.severity)]** `\(.location)` — \(.criterion)"' <<< "$rollup" 2>/dev/null || true)"
  fi
  printf '%s' "$out"
}

# _prd_gaps_md <report> — the audit's evidence for each missing requirement, from the audit's
# closing fenced json (the last block naming `missing`, as parsePrdAudit reads it). An audit
# without one falls back to the report's tail.
_prd_gaps_md() {
  local report="$1" json md=""
  [ -f "$report" ] || return 0
  json="$(awk '
    /^[ \t]*```json/ { inj = 1; cur = ""; next }
    inj && /^[ \t]*```[ \t]*$/ { inj = 0; if (cur ~ /"missing"/) last = cur; next }
    inj { cur = cur $0 "\n" }
    END { printf "%s", last }
  ' "$report")"
  if [ -n "$json" ]; then
    md="$(printf '%s' "$json" | jq -r '.missing[]? | (if type == "string" then {requirement: .} else . end)
      | "- **\(.requirement)**" + (if (.detail // "") != "" then "\n  " + (.detail | gsub("\n"; "\n  ")) else "" end)' 2>/dev/null || true)"
  fi
  if [ -z "$md" ]; then
    md="$(_tail_fenced "$report")"
  fi
  printf '%s' "$md" | head -c "$EVIDENCE_MAX_BYTES"
}

# _tail_fenced <file> — the last lines of <file> (EVIDENCE_MAX_BYTES at most) in a fenced block.
_tail_fenced() {
  [ -f "$1" ] || return 0
  local tail_text
  tail_text="$(tail -c "$EVIDENCE_MAX_BYTES" "$1")"
  [ -n "$tail_text" ] || return 0
  printf '````\n%s\n````\n' "$tail_text"
}

# _defer_github <slug> <title> <branch> <report> <criteria-file> <severities> <blocked-by> —
# github path: creates the issue via _github_tracker_cli, labeled ready-for-agent immediately
# (github has no pre-created label to represent "parked", so there is no local-style
# park/flush step for this backend — flush/list correctly report nothing to promote, see
# cmd_flush/cmd_list). The body keeps local's `Source:` line (naming the kind and branch, not
# a local report path) so parseIssue reads both the same way, embeds the promoted
# findings' full reviewer text, and adds a numeric `## Blocked by` reference when the caller
# names one. Prints the created issue's URL (github.mjs's own stdout, itself `gh issue
# create`'s stdout passed through).
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
  if [ "$TRACKER_CONFIG_TRACKER" = "github" ]; then
    ref="$(_defer_github "$slug" "$title" "$branch" "$report" "$criteria_file" "$severities" "$blocked_by")"
  else
    ref="$(_defer_local "$slug" "$issue_slug" "$title" "$criteria_file" "$severities" "$branch")"
  fi

  # Annotate the report so a later human run of /crew-address-findings does not
  # re-triage findings this sprint already fixed. Appended at the end of the file
  # (the report is fully written before promotion runs), keyed by branch + severity —
  # promotion always takes *all* findings at those severities for that branch, so the
  # pair is an unambiguous marker with no per-finding parsing. Shared across backends:
  # the review report is runtime bookkeeping, always local (see docs/PRD's Decisions).
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
  # The count rides on the marker so crew-summary.sh can show it without the issue file —
  # a github ref is a URL, and the summary makes no network call to read it back.
  local n
  n=$(count_criteria "$criteria_file")
  echo "- $branch: $severities → $ref ($n finding(s))" >> "$report"

  _trace PROMOTE "branch=$branch issue=$ref severities=$severities findings=$n"
  echo "defer: $ref"
}

# --- defer-gaps / defer-integration ---------------------------------------------
# Two fix issues that come from no reviewed branch, each one per feature while open, each flushed
# into Phase 2 with the review findings. Their `Source:` line is the same depth bound: findings on
# their branches are report-only.
#   defer-gaps        — the PRD audit's ✗ missing requirements. A resumed sprint that audits again
#                       must not queue the same gaps twice.
#   defer-integration — a drain-time integration check that triage judged fixable: the merged
#                       feature branch's own checks fail. The caller (loop.mjs) bounds how many a
#                       run may create; this only refuses a second while one is still open.
# _defer_feature_issue <command> <feature-slug> <report> <criteria-file> <title> <source-tag>
#                      <file-suffix> <trace-label> <context> <github-context> [numbered]
# The github body drops the report path for the evidence itself: <source-tag> `prd-audit` embeds
# the audit's missing-requirement details, `integration` the tail of the failing output.
_defer_feature_issue() {
  local command="$1" slug="$2" report="$3" criteria_file="$4" title="$5" source_tag="$6"
  local suffix="$7" label="$8" context="$9" github_context="${10}" numbered="${11:-}" ref

  if [ "$TRACKER_CONFIG_TRACKER" = "github" ]; then
    local body_file evidence="" evidence_heading source_name
    body_file="$(mktemp)"
    case "$source_tag" in
      prd-audit) source_name="PRD audit"; evidence_heading="PRD audit evidence"; evidence="$(_prd_gaps_md "$report")" ;;
      *) source_name="integration check"; evidence_heading="Failing output (tail)"; evidence="$(_tail_fenced "$report")" ;;
    esac
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
    # A numbered kind (several per feature over time) gets a slug of its own each time: the slug
    # is the issue's identity in the sprint's bookkeeping, and a reused one would read as the
    # earlier, finished issue.
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

# _feature_issue_args <command> <args...> — the options both subcommands take; sets slug,
# report and criteria_file in the caller (bash dynamic scope).
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

cmd_defer_gaps() {
  local slug report criteria_file
  _feature_issue_args defer-gaps "$@"
  _defer_feature_issue defer-gaps "$slug" "$report" "$criteria_file" "Fix PRD gaps: $slug" prd-audit \
    fix-prd-gaps prd-gaps "Auto-queued by crew-afk from the PRD audit's missing requirements. No issue carried
these, so no review ever checked them. The audit's evidence for each is in the report named in
\`Source:\`." "Auto-queued by crew-afk from the PRD audit's missing requirements. No issue carried
these, so no review ever checked them. The audit's evidence for each is under
\`## PRD audit evidence\` below."
}

cmd_defer_integration() {
  local slug report criteria_file at=""
  # --at <commit> names the feature-branch tip that failed: it keeps each fix issue's title (and
  # so, under github, its slug) unique across the run's drains.
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

# --- flush -------------------------------------------------------------------
# Phase 1 → Phase 2. Rewriting Status on disk (rather than holding a list in memory) is
# what makes this idempotent and crash-safe: once flipped, the parked set is empty, so
# reaching another exit re-runs flush harmlessly and an interrupted sprint resumes with
# the fix issues already looking like ordinary ready-for-agent work.
cmd_flush() {
  local slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature-slug) slug="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage

  # github's defer (cmd_defer) creates fix issues labeled ready-for-agent immediately —
  # there is no pre-created "parked" label to represent local's deferred-findings Status,
  # so nothing is ever queued here for github to promote. Still "works" in the sense the
  # AC asks for: no crash, and an honest zero rather than scanning a local dir that, under
  # `tracker: github`, holds no issue content at all.
  if [ "$TRACKER_CONFIG_TRACKER" = "github" ]; then
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

# --- list --------------------------------------------------------------------
cmd_list() {
  local slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature-slug) slug="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] || usage

  # Same reasoning as cmd_flush's github branch: defer never parks a github issue, so
  # there is never a deferred one to list.
  if [ "$TRACKER_CONFIG_TRACKER" = "github" ]; then
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

# --- mark-not-run ------------------------------------------------------------
# Review is advisory: a failed reviewer never blocks a merge. But "advisory" must not
# decay into "reported as clean". If the dispatch dies there is no --out file, so nothing
# is appended to reviews/ — and `remind` globbing an empty directory prints
# "FINDINGS: none", which reads as an all-clear on a branch nobody looked at.
#
# Writing a stub block closes that hole with the same `not_run` convention
# verify-worktree.sh already uses for undiscoverable check commands: an unknown result is
# recorded as unknown, never as a pass. Creating the report when absent is the load-bearing
# part — it is what makes the gap survive into the end-of-sprint reminder.
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
  # A gap with no reason is nearly as unactionable as no gap at all.
  [ -n "$report" ] && [ -n "$reason" ] || usage

  mkdir -p "$(dirname "$report")"

  # Idempotent: a retried dispatch that fails twice must not double-count the branch.
  if [ -f "$report" ] && grep -q "^## Branch: $branch (" "$report"; then
    echo "mark-not-run: already recorded — $branch"
    return 0
  fi

  # jq -n builds the JSON safely regardless of what $reason contains (quotes, backslashes,
  # …) — the same reason a reviewer's own findings never get hand-interpolated into a
  # report either. See report.mjs's parseReviewAggregate for who reads this block.
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

# open_findings_json <rollup-json> <report>... — the one definition of "open": every finding in
# the rollup minus what a fix issue already covers: the (branch, severity) pairs, and — under
# `actionable` — a branch's findings that triage judged Actionable (its bullet names `actionable`
# where the severities go). Those are defer's own bash-generated "## Promoted Findings" bullets
# ("- <branch>: SEV, SEV → <ref>", since #209 followed by " (<n> finding(s))"), never the reviewer's free text, so a plain regex capture reads
# them exactly. Prints a JSON array of {branch, severity, location, criterion, verdict, rationale};
# verdict and rationale are "" for a finding triage never judged. `carried: true` is added to a
# finding an earlier review of the branch raised and the latest did not repeat. A finding marked
# `report_only` (a feature review past the promotion cap) is never covered: no fix issue took it.
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

# --- open ---------------------------------------------------------------------
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

# verdict_lines <verdict> <HEADING> <note> — open findings (JSON on stdin) with that triage
# verdict: "HEADING: n (note)" then one "<heading, lowercased>: <branch> [SEV] <location> — <what>
# — why: <rationale>" line each. Prints nothing when there are none.
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

# --- remind ------------------------------------------------------------------
# Promotion only covers what the sprint's fixFindings rule selects (every Actionable finding by
# default) on Phase 1 branches. Everything else — Debatable and Dismissed findings, the severities
# a severity level leaves out, plus any finding raised against a Phase 2 fix branch (report-only
# by the depth bound) — still needs a human. This counts exactly those so the end-of-sprint reminder states a
# real number instead of nudging the user toward an empty queue, or worse, staying silent
# when CRITICAL findings from a fix branch are sitting unread.
#
# Findings are attributed to the `## Branch: <name>` section they appear under, then any
# (branch, severity) pair listed in `## Promoted Findings` is subtracted. Reports already
# archived under reviews/done/ are ignored.
#
# Branches marked `Review: not_run` are counted separately and always printed. They
# contribute no findings by definition, so folding them into the findings total would be
# wrong — but omitting them is the silent all-clear this is here to prevent.
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
  # A finding triage dismissed is not "still needing triage": it is counted apart (DISMISSED) and
  # left out of the total and its severity breakdown.
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
    # What a human decides first: the findings triage judged Debatable. An Actionable one still
    # open here was not promoted (its fix issue failed to queue); Dismissed ones are collapsed to
    # one line each with the reason. Nothing is printed for findings triage never judged.
    verdict_lines debatable DEBATABLE "decide these first" <<< "$open_json"
    verdict_lines actionable ACTIONABLE "not promoted" <<< "$open_json"
    verdict_lines dismiss DISMISSED "triage's rationale, collapsed" <<< "$open_json"
    # Carried findings triage never judged have no line above to carry the label; they are counted
    # in the total already.
    jq -r '.[] | select(.carried == true and .verdict == "")
      | "earlier: \(.branch) [\(.severity)] \(.location) — \(.criterion) (earlier review)"' <<< "$open_json"
    printf 'report: %s\n' "${reports[@]}"
  fi

  # Printed after the findings line and never suppressed by it: a sprint with zero open
  # findings and an unreviewed branch is exactly the case that must not look clean.
  # review_rollup already folded a retried, real verdict over an earlier not_run stub
  # for the same branch, so a `not_run` entry here is never stale.
  local gaps gap_count
  gaps=$(jq -r '.branches[] | select(.verdict == "not_run") | [.branch, (.detail // "")] | @tsv' <<< "$rollup")
  gap_count=0
  [ -n "$gaps" ] && gap_count=$(printf '%s\n' "$gaps" | grep -c . || true)

  if [ "${gap_count:-0}" -gt 0 ]; then
    echo "REVIEW-GAPS: branches=$gap_count"
    printf '%s\n' "$gaps" | while IFS=$'\t' read -r branch reason; do
      echo "gap: $branch — $reason"
    done
    # The report paths are printed with the findings line above; when there are no
    # findings, the gap lines are the only reason to name the report, so print them here.
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
  defer-gaps) cmd_defer_gaps "$@" ;;
  defer-integration) cmd_defer_integration "$@" ;;
  flush) cmd_flush "$@" ;;
  list)  cmd_list "$@" ;;
  open) cmd_open "$@" ;;
  remind) cmd_remind "$@" ;;
  mark-not-run) cmd_mark_not_run "$@" ;;
  *) usage ;;
esac
