#!/usr/bin/env bash
set -uo pipefail

# crew-summary.sh — render the end-of-sprint summary and findings reminder from sprint-state.json
# and the review reports, so no retained branch or review gap can be dropped from it.
# Usage: crew-summary.sh [--feature-slug <slug>] [--stalled] [--capped] [--no-reminder]
#          [--posted-to <pr-url>] [--promoted <severities>]
# Sections with nothing to report are omitted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STALLED=0
CAPPED=0
REMINDER=1
POSTED_TO=""
PROMOTE_POLICY=""   # what the sprint promoted, resolved by the orchestrator (report.mjs)
FEATURE_SLUG_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --feature-slug) FEATURE_SLUG_ARG="${2:-}"; shift 2 ;;
    --stalled) STALLED=1; shift ;;
    --capped) CAPPED=1; shift ;;
    --no-reminder) REMINDER=0; shift ;;
    --posted-to) POSTED_TO="${2:-}"; shift 2 ;;
    --promoted) PROMOTE_POLICY="${2:-}"; shift 2 ;;
    *) echo "crew-summary.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

# shellcheck source=main-root.sh
. "$SCRIPT_DIR/main-root.sh"
MAIN_ROOT="${MAIN_ROOT:-$(main_root || pwd)}"
FEATURE_SLUG="${FEATURE_SLUG_ARG:-${FEATURE_SLUG:-}}"
if [ -z "$FEATURE_SLUG" ]; then
  echo "crew-summary.sh: no sprint to summarise — pass --feature-slug <slug>" >&2
  exit 2
fi

state() { bash "$SCRIPT_DIR/state.sh" "$@" ${FEATURE_SLUG:+--feature-slug "$FEATURE_SLUG"}; }

SF=$(state get state-file) || { echo "crew-summary: no sprint state found" >&2; exit 1; }

# FEATURE_BRANCH from the sprint's own env file: git would guess wrong off that branch.
if [ -z "${FEATURE_BRANCH:-}" ] && [ -f "$MAIN_ROOT/.scratch/$FEATURE_SLUG/sprint.env" ]; then
  # shellcheck disable=SC1091
  . "$MAIN_ROOT/.scratch/$FEATURE_SLUG/sprint.env" 2>/dev/null || true
fi

count_csv() {
  [ -n "$1" ] || { echo 0; return; }
  printf '%s' "$1" | tr ',' '\n' | grep -c . || true
}

# review_rollup <report-file>... — the one review-report parser, as in promote-findings.sh.
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
or_none() { [ -n "$1" ] && printf '%s' "$(printf '%s' "$1" | sed 's/,/, /g')" || printf 'none'; }

REVIEW_DIR="$MAIN_ROOT/.scratch/$FEATURE_SLUG/reviews"

# A branch reviewed more than once is folded to its latest verdict: reports are globbed in
# creation order, and a later `## Branch:` block overwrites an earlier one.
code_review_summary() {
  local dir="$1"
  local files=()
  if [ -d "$dir" ]; then
    for f in "$dir"/*.md; do [ -f "$f" ] && files+=("$f"); done
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    echo "No branches were reviewed this sprint."
    return
  fi

  local rollup n
  rollup=$(review_rollup "${files[@]}")
  n=$(printf '%s' "$rollup" | jq '.branches | length' 2>/dev/null || echo 0)
  if [ "${n:-0}" -eq 0 ]; then
    echo "No branches were reviewed this sprint."
    return
  fi

  printf '%s' "$rollup" | jq -r '
    def sevcount(sev): [.findings[] | select(.severity == sev)] | length;
    (.branches) as $b
    | ($b | map(select(.verdict == "all-met")) | length) as $met
    | ($b | map(select(.verdict == "unmet")) | length) as $unmet
    | ($b | map(select(.verdict == "not_run")) | length) as $notrun
    | ($b | map(.findings[]?) | map(select(.severity == "CRITICAL")) | length) as $tcrit
    | ($b | map(.findings[]?) | map(select(.severity == "HIGH")) | length) as $thigh
    | ($b | map(.findings[]?) | map(select(.severity == "MEDIUM")) | length) as $tmed
    | ($b | map(.findings[]?) | map(select(.severity == "LOW")) | length) as $tlow
    | "Branches reviewed: \($b | length) (all-met: \($met), unmet: \($unmet), not-reviewed: \($notrun))",
      "Findings: \($tcrit + $thigh + $tmed + $tlow) total (CRITICAL: \($tcrit), HIGH: \($thigh), MEDIUM: \($tmed), LOW: \($tlow))",
      ($b[] | "- \(.branch): \(if .verdict == "not_run" then "not-reviewed" else .verdict end) (C:\(sevcount("CRITICAL")) H:\(sevcount("HIGH")) M:\(sevcount("MEDIUM")) L:\(sevcount("LOW")))")
  '
}

MERGED_SLUGS=$(state get completed)
PARTIAL_SLUGS=$(state get partial)
BLOCKED_SLUGS=$(state get blocked)

echo "Run $(state get runs) for this feature; previous: $(state get previous-exit)"
echo "Rounds: $(state get rounds)"
echo "Model:  $(state get model)"
# Omitted when nothing was recorded: platforms without cost data are not zero cost. Totals span
# every run; this run's `.dispatches` are split by role (`conflict` counts as coder) and attempt.
# A dispatch stopped before its `result` event is counted as cost unknown, never priced at $0.
TOTAL_COST_USD=$(state get total-cost-usd)
UNKNOWN_COST_N=$(jq -r '(.current_run) as $r
  | [(.dispatches // [])[] | select($r != null and .run == $r and .cost_unknown == true)] | length' "$SF" 2>/dev/null || echo 0)
UNKNOWN_COST_N=${UNKNOWN_COST_N:-0}
UNKNOWN_NOTE=""
if [ "$UNKNOWN_COST_N" -gt 0 ]; then
  UNKNOWN_NOTE=" + $UNKNOWN_COST_N stopped dispatch$([ "$UNKNOWN_COST_N" -eq 1 ] || echo es), cost unknown"
fi
if awk -v c="$TOTAL_COST_USD" 'BEGIN { exit !(c > 0) }' || [ "$UNKNOWN_COST_N" -gt 0 ]; then
  RUN_ROW=$(jq -r '(.current_run) as $r
    | [(.dispatches // [])[] | select($r != null and .run == $r)] as $d
    | def sum(f): ($d | map(f // 0) | add // 0);
      def by(p): ($d | map(select(p) | .cost_usd // 0) | add // 0);
    if ($d | length) == 0 then empty else
      [($d | length), sum(.cost_usd), sum(.duration_ms), sum(.turns),
       by(.role == "coder" or .role == "conflict"), by(.role == "reviewer"), by(.role == "triage"),
       by(.role | IN("coder", "conflict", "reviewer", "triage") | not),
       by((.attempt // 0) <= 1), by((.attempt // 0) > 1)] | @tsv end' "$SF" 2>/dev/null || true)
  if [ -n "$RUN_ROW" ]; then
    printf '%s\t%s\n' "$RUN_ROW" "$TOTAL_COST_USD" | awk -F'\t' -v note="$UNKNOWN_NOTE" '{
      printf "Cost:   this run $%.2f · %d dispatches · %.1fm agent time · %d turns — feature total $%.2f%s\n", $2, $1, $3 / 60000, $4, $11, note
      printf "        by role: coder $%.2f · reviewer $%.2f · triage $%.2f · other $%.2f — first attempts $%.2f · retries $%.2f\n", $5, $6, $7, $8, $9, $10
    }'
  else
    TOTAL_TURNS=$(state get total-dispatch-turns)
    echo "Cost:   $(awk -v c="$TOTAL_COST_USD" 'BEGIN { printf "$%.2f", c }') · agent time: $(awk -v ms="$(state get total-dispatch-duration-ms)" 'BEGIN { printf "%.1fm", ms / 60000 }') across $TOTAL_TURNS turns (every run of this feature)"
  fi
fi
echo "Merged  ($(count_csv "$MERGED_SLUGS")): $(or_none "$MERGED_SLUGS")"
echo "Partial ($(count_csv "$PARTIAL_SLUGS")): $(or_none "$PARTIAL_SLUGS")"
echo "Blocked ($(count_csv "$BLOCKED_SLUGS")): $(or_none "$BLOCKED_SLUGS")"
# Labelled `blocked` on GitHub: later runs skip these until the label comes off.
UNBLOCK=$(jq -r '(.blocked_labelled // {}) | to_entries[] | "  gh issue edit \(.value) --remove-label blocked   # \(.key)"' "$SF" 2>/dev/null || true)
if [ -n "$UNBLOCK" ]; then
  echo "Labelled blocked — later runs skip these until a human puts them back in the queue:"
  printf '%s\n' "$UNBLOCK"
fi
# --capped: the wall-clock cap, not a blocker, is what left work undone.
if [ "$CAPPED" -eq 1 ]; then echo "CAPPED: the wall-clock cap stopped new claims — re-run (/crew-afk) to continue"
elif [ "$STALLED" -eq 1 ]; then echo "STALLED: resolve blockers and re-run (/crew-afk)"
fi

echo ""
echo "## Code Review"
code_review_summary "$REVIEW_DIR"

VERIFY_FAILS=$(jq -r '(.retention // {}) | to_entries[]
  | select(.value.reason | startswith("verification-failed"))
  | "- \(.value.branch): \(.value.reason)"' "$SF" 2>/dev/null || true)
if [ -n "$VERIFY_FAILS" ]; then
  echo ""
  echo "## Verification Failures"
  printf '%s\n' "$VERIFY_FAILS"
fi

GAPS=$(jq -r '(.coverage_gaps // {}) | to_entries[] | "- \(.key): not_run \(.value)"' "$SF" 2>/dev/null || true)
if [ -n "$GAPS" ]; then
  echo ""
  echo "## Coverage Gaps"
  echo "Checks with no discoverable command — these did not pass, they never ran."
  printf '%s\n' "$GAPS"
fi

DEVIATIONS=$(jq -r '(.deviations // {}) | to_entries[] | .key as $k | .value[] | "- \($k): \(.)"' "$SF" 2>/dev/null || true)
if [ -n "$DEVIATIONS" ]; then
  echo ""
  echo "## Deviations"
  echo "Coders that ran the full test suite themselves — logged, not failed; the verify gate owns it."
  printf '%s\n' "$DEVIATIONS"
fi

RETAINED=$(jq -r '(.retention // {}) | to_entries[] | "- \(.value.branch): retained (\(.value.reason))"' "$SF" 2>/dev/null || true)
if [ -n "$RETAINED" ]; then
  echo ""
  echo "## Retained Branches"
  printf '%s\n' "$RETAINED"
fi

# merge-failed is the one retention a re-run cannot fix: merge-branches.sh never resolves a
# conflict, so spell out the manual step.
MERGE_CONFLICTS=$(jq -r '(.retention // {}) | to_entries[] | select(.value.reason | startswith("merge-failed")) | .value.branch' "$SF" 2>/dev/null || true)
if [ -n "$MERGE_CONFLICTS" ]; then
  echo ""
  echo "## Merge Conflicts (need a human)"
  echo "crew-afk never resolves merge conflicts automatically. To unblock each branch below:"
  echo "  1. In a temporary worktree (the main checkout must not end up on the feature branch):"
  echo "     git worktree add /tmp/crew-resolve ${FEATURE_BRANCH:-<feature-branch>} && cd /tmp/crew-resolve && git merge --no-ff <branch>"
  echo "  2. Resolve the conflicts by hand, then: git add -A && git commit; then: cd - && git worktree remove /tmp/crew-resolve"
  echo "  3. Re-run crew-afk — merge-branches.sh sees the branch as already merged and closes the issue normally."
  printf '%s\n' "$MERGE_CONFLICTS" | sed 's/^/- /'
fi

# The merge was refused for uncommitted changes in the feature worktree; a re-run resumes at the merge.
DIRTY_BLOCKED=$(jq -r '(.retention // {}) | to_entries[] | select(.value.reason | test("main-tree-dirty")) | "- \(.value.branch): \(.value.reason | sub("^.*main-tree-dirty — "; ""))"' "$SF" 2>/dev/null || true)
if [ -n "$DIRTY_BLOCKED" ]; then
  echo ""
  echo "## Feature Worktree Not Clean (need a human)"
  echo "These branches passed every gate; only the merge was refused because the feature branch's worktree had uncommitted changes. Re-run (/crew-afk) — the worktree is recreated and they resume at the merge."
  printf '%s\n' "$DIRTY_BLOCKED"
fi

# Triage judged the failure unfixable by recoding and a coder-free retry hit it again: carved out
# so a human sees "fix the environment" at a glance.
ENV_BLOCKED=$(jq -r '(.retention // {}) | to_entries[]
  | select(.value.reason | test("^blocked — environment"))
  | "- \(.key) (\(.value.branch)): \(.value.reason)"' "$SF" 2>/dev/null || true)
if [ -n "$ENV_BLOCKED" ]; then
  echo ""
  echo "## Environment Blockers (need a human)"
  echo "crew-triage classified each of these as not fixable by recoding, and a plain,"
  echo "coder-free retry (deps + verify only) hit the identical failure again — a registry,"
  echo "network, credential, or infrastructure problem, not something in the diff. Resolve the"
  echo "environment, then re-run crew-afk: these issues are attempted normally on the next run."
  printf '%s\n' "$ENV_BLOCKED"
fi

# The markers promote-findings.sh defer appends: "- <branch>: <severities> → <ref> (<n> finding(s))",
# the count absent on an older marker. A local ref's count and state come from the issue file; a
# github URL renders as #<n> with the marker's count, with no network call.
PROMOTED=""
if [ -d "$REVIEW_DIR" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    branch=${line#- }; branch=${branch%%:*}
    issue_path=${line##*→ }
    marker_n=""
    if [[ "$issue_path" =~ ^(.*)\ \(([0-9]+)\ finding\(s\)\)$ ]]; then
      issue_path=${BASH_REMATCH[1]}
      marker_n=${BASH_REMATCH[2]}
    fi
    if [[ "$issue_path" =~ ^https?://.*/issues/([0-9]+)/?$ ]]; then
      count="findings"
      [ -z "$marker_n" ] || count="$marker_n finding(s)"
      PROMOTED="${PROMOTED}- $branch: $count → #${BASH_REMATCH[1]}
"
      continue
    fi
    issue_slug=$(basename "$issue_path" .md)
    if [ -f "$issue_path" ]; then
      status=$(sed -n 's/^Status:[[:space:]]*//p' "$issue_path" | head -1)
      n=$(grep -c '^- \[' "$issue_path" 2>/dev/null || echo 0)
    else
      done_path="$MAIN_ROOT/.scratch/$FEATURE_SLUG/issues/done/$(basename "$issue_path")"
      if [ -f "$done_path" ]; then
        status="merged"
        n=$(grep -c '^- \[' "$done_path" 2>/dev/null || echo 0)
      else
        status="missing"
        n=0
      fi
    fi
    PROMOTED="${PROMOTED}- $branch: $n finding(s) → $issue_slug ($status)
"
  done < <(grep -h '^- .*→' "$REVIEW_DIR"/*.md 2>/dev/null || true)
fi
if [ -n "$PROMOTED" ]; then
  echo ""
  echo "## Promoted Findings"
  printf '%s' "$PROMOTED"
fi

bash "$SCRIPT_DIR/trace.sh" --level "$([ "$(count_csv "$BLOCKED_SLUGS")" -eq 0 ] && echo info || echo warn)" EXIT \
  "merged=$(count_csv "$MERGED_SLUGS") partial=$(count_csv "$PARTIAL_SLUGS") blocked=$(count_csv "$BLOCKED_SLUGS")"

[ "$REMINDER" -eq 1 ] || exit 0

# Release the close gate (mark-done refuses while .orchestrated exists) — on the final summary
# only: --no-reminder is the per-round rollup.
rm -f "$MAIN_ROOT/.scratch/$FEATURE_SLUG/.orchestrated"

# Nothing auto-commits dev-commands.json, and a stray `git clean` would lose it.
DEV_COMMANDS_STATUS=$(git -C "$MAIN_ROOT" status --porcelain -- .coding-crew/dev-commands.json 2>/dev/null || true)
if [ -n "$DEV_COMMANDS_STATUS" ]; then
  echo ""
  echo "## Dev Commands Cache"
  echo "Reminder: .coding-crew/dev-commands.json has uncommitted changes at MAIN_ROOT — review and commit it."
fi

REMIND=$(cd "$MAIN_ROOT" && bash "$SCRIPT_DIR/promote-findings.sh" remind --feature-slug "$FEATURE_SLUG" 2>/dev/null || true)

OPEN_LINE=$(printf '%s\n' "$REMIND" | grep '^FINDINGS: open=' || true)
REPORTS=$(printf '%s\n' "$REMIND" | sed -n 's/^report: //p' | paste -sd ', ' - 2>/dev/null || true)
GAP_LINE=$(printf '%s\n' "$REMIND" | grep '^REVIEW-GAPS: ' || true)

echo ""
if [ -n "$OPEN_LINE" ]; then
  total=${OPEN_LINE#FINDINGS: open=}; total=${total%% *}
  breakdown=$(printf '%s' "$OPEN_LINE" | sed -n 's/.*(\(.*\)).*/\1/p')
  echo "## Next Step"
  echo "$total review finding(s) still need triage ($breakdown)."
  echo "Reports: $REPORTS"
  if [ -n "$POSTED_TO" ]; then
    echo "$total finding(s) posted to $POSTED_TO"
    echo "Run: /address-pr-comments $POSTED_TO"
  else
    echo "Run: /crew-address-findings"
  fi
  # Debatable findings lead: they are the ones triage would not let an unattended coder touch.
  DEBATABLE_LINES=$(printf '%s\n' "$REMIND" | grep '^debatable: ' | sed 's/^debatable: /- /' || true)
  if [ -n "$DEBATABLE_LINES" ]; then
    echo "$(printf '%s\n' "$REMIND" | sed -n 's/^DEBATABLE: \([0-9]*\) .*/\1/p') Debatable — decide these first (triage judged them unsafe to fix unattended):"
    printf '%s\n' "$DEBATABLE_LINES"
  fi
  # A reduced promotion threshold is a real coverage reduction, so it is stated where the
  # consequence shows up: a HIGH the sprint did not fix must be visibly queued, never silent.
  case "$breakdown" in
    *CRITICAL*|*HIGH*)
      if [ "$PROMOTE_POLICY" = "actionable" ]; then
        echo "Includes CRITICAL/HIGH findings this sprint did not fix — triage judged them Debatable or Dismissed, or they were raised against a fix branch (report-only by design), or triage failed and the high rule applied to a branch's findings. Triage these first (config.json's afk.fixFindings, or --fix-findings, sets what is fixed; default actionable)."
      else
        echo "Includes CRITICAL/HIGH findings this sprint did not fix — promotion covered ${PROMOTE_POLICY:-no severity} on Phase 1 branches only, and findings on fix branches are report-only by design. Triage these first (config.json's afk.fixFindings, or --fix-findings, sets the lowest severity fixed; default actionable)."
      fi ;;
  esac
elif [ -z "$GAP_LINE" ]; then
  echo "No open review findings."
fi
# Findings triage dismissed are not "still need triage" — named here, with the report that holds the rationale.
DISMISSED_N=$(printf '%s\n' "$REMIND" | sed -n 's/^DISMISSED: \([0-9]*\) .*/\1/p')
if [ -n "$DISMISSED_N" ]; then
  echo "$DISMISSED_N finding(s) dismissed by triage (rationale in the report): $REPORTS"
fi

if [ -n "$GAP_LINE" ]; then
  # A merged branch passed an all-met review (the merge gate requires it), so a `gap:` for one is a
  # stale not_run stub from an earlier attempt and must not contradict the Merged line.
  GAP_ENTRIES=""
  gap_count=0
  while IFS= read -r gline; do
    [ -n "$gline" ] || continue
    branch=${gline#gap: }; branch=${branch%% — *}
    merged=0
    if [ -n "$MERGED_SLUGS" ]; then
      IFS=',' read -ra slugs <<< "$MERGED_SLUGS"
      for s in "${slugs[@]}"; do
        [ "${branch##*/}" = "$s" ] && { merged=1; break; }
      done
    fi
    if [ "$merged" -eq 0 ]; then
      GAP_ENTRIES="${GAP_ENTRIES}- ${gline#gap: }
"
      gap_count=$((gap_count + 1))
    fi
  done < <(printf '%s\n' "$REMIND" | grep '^gap: ')

  if [ "$gap_count" -gt 0 ]; then
    echo ""
    echo "## Unreviewed Branches"
    echo "$gap_count branch(es) had no completed code review:"
    printf '%s' "$GAP_ENTRIES"
    echo "Their absence of findings means nothing — nobody looked. The review also carries the acceptance-criteria gate, so these branches were retained rather than merged: re-run the sprint, or review them by hand."
  fi
fi
