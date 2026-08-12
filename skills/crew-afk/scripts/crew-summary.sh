#!/usr/bin/env bash
set -uo pipefail

# crew-summary.sh — render the end-of-sprint summary and the findings reminder from
# sprint-state.json and the review reports.
#
# Usage:
#   crew-summary.sh [--feature-slug <slug>] [--stalled] [--no-reminder]
#
# The summary used to be ~430 words of print template that the orchestrator filled in
# from lists it had been carrying in its context since round 1. That is the one part of
# the sprint where a dropped entry is invisible: a retained branch left out of
# "## Retained Branches" reads as a clean teardown, and a review gap left out of the
# reminder reads as a clean review. Both facts are already on disk — in
# sprint-state.json (written by state.sh) and in the review reports (written by the
# reviewer and by promote-findings.sh) — so rendering is mechanical.
#
# Sections with nothing to report are omitted, exactly as the prose template said.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STALLED=0
REMINDER=1
FEATURE_SLUG_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --feature-slug) FEATURE_SLUG_ARG="${2:-}"; shift 2 ;;
    --stalled) STALLED=1; shift ;;
    --no-reminder) REMINDER=0; shift ;;
    *) echo "crew-summary.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

MAIN_ROOT="${MAIN_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
if [ -z "$FEATURE_SLUG_ARG" ] && [ -f "$MAIN_ROOT/.scratch/sprint.env" ]; then
  # shellcheck disable=SC1091
  . "$MAIN_ROOT/.scratch/sprint.env" 2>/dev/null || true
fi
FEATURE_SLUG="${FEATURE_SLUG_ARG:-${FEATURE_SLUG:-}}"

state() { bash "$SCRIPT_DIR/state.sh" "$@" ${FEATURE_SLUG:+--feature-slug "$FEATURE_SLUG"}; }

SF=$(state get state-file) || { echo "crew-summary: no sprint state found" >&2; exit 1; }
[ -n "$FEATURE_SLUG" ] || FEATURE_SLUG=$(state get feature-slug)

count_csv() {
  [ -n "$1" ] || { echo 0; return; }
  printf '%s' "$1" | tr ',' '\n' | grep -c . || true
}
or_none() { [ -n "$1" ] && printf '%s' "$(printf '%s' "$1" | sed 's/,/, /g')" || printf 'none'; }

MERGED_SLUGS=$(state get completed)
PARTIAL_SLUGS=$(state get partial)
BLOCKED_SLUGS=$(state get blocked)

echo "Rounds: $(state get rounds)"
echo "Model:  $(state get model)"
echo "Merged  ($(count_csv "$MERGED_SLUGS")): $(or_none "$MERGED_SLUGS")"
echo "Partial ($(count_csv "$PARTIAL_SLUGS")): $(or_none "$PARTIAL_SLUGS")"
echo "Blocked ($(count_csv "$BLOCKED_SLUGS")): $(or_none "$BLOCKED_SLUGS")"
[ "$STALLED" -eq 1 ] && echo "STALLED: resolve blockers and re-run (/crew-afk)"

# --- Verification Failures ----------------------------------------------------
VERIFY_FAILS=$(jq -r '(.retention // {}) | to_entries[]
  | select(.value.reason | startswith("verification-failed"))
  | "- \(.value.branch): \(.value.reason)"' "$SF" 2>/dev/null || true)
if [ -n "$VERIFY_FAILS" ]; then
  echo ""
  echo "## Verification Failures"
  printf '%s\n' "$VERIFY_FAILS"
fi

# --- Coverage Gaps ------------------------------------------------------------
GAPS=$(jq -r '(.coverage_gaps // {}) | to_entries[] | "- \(.key): not_run \(.value)"' "$SF" 2>/dev/null || true)
if [ -n "$GAPS" ]; then
  echo ""
  echo "## Coverage Gaps"
  echo "Checks with no discoverable command — these did not pass, they never ran."
  printf '%s\n' "$GAPS"
fi

# --- Retained Branches --------------------------------------------------------
RETAINED=$(jq -r '(.retention // {}) | to_entries[] | "- \(.value.branch): retained (\(.value.reason))"' "$SF" 2>/dev/null || true)
if [ -n "$RETAINED" ]; then
  echo ""
  echo "## Retained Branches"
  printf '%s\n' "$RETAINED"
fi

# --- Promoted Findings --------------------------------------------------------
# Read back the markers promote-findings.sh defer appended to each review report:
#   - <branch>: <severities> → <issue path>
# The finding count is the number of acceptance criteria in the fix issue (one per
# promoted finding), and its state is where the issue file now lives.
REVIEW_DIR="$MAIN_ROOT/.scratch/$FEATURE_SLUG/reviews"
PROMOTED=""
if [ -d "$REVIEW_DIR" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    branch=${line#- }; branch=${branch%%:*}
    issue_path=${line##*→ }
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

bash "$SCRIPT_DIR/trace.sh" EXIT \
  "merged=$(count_csv "$MERGED_SLUGS") partial=$(count_csv "$PARTIAL_SLUGS") blocked=$(count_csv "$BLOCKED_SLUGS")"

[ "$REMINDER" -eq 1 ] || exit 0

# The sprint is over, so release the close gate: `mark-issue-done.sh` refuses while
# .orchestrated exists, and a marker left behind would block a standalone solve-issue run
# on this feature long after the orchestrator stopped. Only on the final summary —
# --no-reminder is the per-round rollup, and the sprint is still running then.
rm -f "$MAIN_ROOT/.scratch/$FEATURE_SLUG/.orchestrated"

# --- Findings reminder (last thing printed) -----------------------------------
# Promotion only covered the sprint's threshold severities (CRITICAL by default) on Phase 1
# branches. Everything else — HIGH under the default threshold, MEDIUM/LOW always, and any
# finding raised against a Phase 2 fix branch — still needs a human.
REMIND=$(cd "$MAIN_ROOT" && bash "$SCRIPT_DIR/promote-findings.sh" remind --feature-slug "$FEATURE_SLUG" 2>/dev/null || true)
PROMOTE_POLICY=$(bash "$SCRIPT_DIR/promote-findings.sh" policy 2>/dev/null | sed -n 's/^promote: //p')

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
  echo "Run: /crew-address-findings"
  # A reduced promotion threshold is a real coverage reduction, so it is stated where the
  # consequence shows up: a HIGH the sprint did not fix must be visibly queued, never silent.
  case "$breakdown" in
    *CRITICAL*|*HIGH*)
      echo "Includes CRITICAL/HIGH findings this sprint did not fix — promotion covered ${PROMOTE_POLICY:-CRITICAL} on Phase 1 branches only, and findings on fix branches are report-only by design. Triage these first (--promote critical-high promotes HIGH too)." ;;
  esac
elif [ -z "$GAP_LINE" ]; then
  echo "No open review findings."
fi

if [ -n "$GAP_LINE" ]; then
  gap_count=${GAP_LINE#REVIEW-GAPS: branches=}
  echo ""
  echo "## Unreviewed Branches"
  echo "$gap_count branch(es) had no completed code review:"
  printf '%s\n' "$REMIND" | sed -n 's/^gap: /- /p'
  echo "Their absence of findings means nothing — nobody looked. The review also carries the acceptance-criteria gate, so these branches were retained rather than merged: re-run the sprint, or review them by hand."
fi
