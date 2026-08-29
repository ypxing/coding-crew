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

# FEATURE_BRANCH (used by the merge-conflict hint below) only came along above when the
# global pointer was sourced, which an explicit --feature-slug skips on purpose — it may
# name a different sprint than whatever the pointer currently points at. Read it straight
# from that sprint's own env file instead of re-deriving it from git, which would guess
# wrong the moment the caller is not currently on that sprint's feature branch.
if [ -z "${FEATURE_BRANCH:-}" ] && [ -f "$MAIN_ROOT/.scratch/$FEATURE_SLUG/sprint.env" ]; then
  # shellcheck disable=SC1091
  . "$MAIN_ROOT/.scratch/$FEATURE_SLUG/sprint.env" 2>/dev/null || true
fi

count_csv() {
  [ -n "$1" ] || { echo 0; return; }
  printf '%s' "$1" | tr ',' '\n' | grep -c . || true
}
or_none() { [ -n "$1" ] && printf '%s' "$(printf '%s' "$1" | sed 's/,/, /g')" || printf 'none'; }

REVIEW_DIR="$MAIN_ROOT/.scratch/$FEATURE_SLUG/reviews"

# --- Code review summary -------------------------------------------------------
# One place that answers "did anything actually get reviewed, and what did it find" —
# every other review-shaped section below (Promoted Findings, Next Step, Unreviewed
# Branches) is detail off of this same disk state, not a second source of truth. A
# branch reviewed more than once (retried after criteria-unmet or review-not-run) is
# folded to its latest verdict here: the report files are globbed in creation order, so
# a later `## Branch:` block for the same name overwrites an earlier one.
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
  awk '
    function reset_branch(b) {
      verdict[b] = ""
      crit[b] = 0; high[b] = 0; med[b] = 0; low[b] = 0
    }
    /^## Branch:/ {
      branch = $0
      sub(/^## Branch: */, "", branch)
      # The reviewer emits a bare "## Branch: <name>"; the not_run stub adds
      # "(<slug>)". Strip it so both forms key the same branch.
      sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/, "", branch)
      if (!(branch in seen)) { order[++n] = branch; seen[branch] = 1 }
      reset_branch(branch)
      next
    }
    branch == "" { next }
    /^AC:[[:space:]]*all-met/     { verdict[branch] = "all-met"; next }
    /^AC:[[:space:]]*unmet/       { verdict[branch] = "unmet"; next }
    /^Review:[[:space:]]*not_run/ { verdict[branch] = "not-reviewed"; next }
    /^FINDING:[[:space:]]*CRITICAL/ { crit[branch]++; next }
    /^FINDING:[[:space:]]*HIGH/     { high[branch]++; next }
    /^FINDING:[[:space:]]*MEDIUM/   { med[branch]++; next }
    /^FINDING:[[:space:]]*LOW/      { low[branch]++; next }
    END {
      if (n == 0) { print "No branches were reviewed this sprint."; exit }
      met = 0; unmet = 0; notrun = 0
      tcrit = 0; thigh = 0; tmed = 0; tlow = 0
      for (i = 1; i <= n; i++) {
        b = order[i]
        if (verdict[b] == "all-met") met++
        else if (verdict[b] == "unmet") unmet++
        else if (verdict[b] == "not-reviewed") notrun++
        tcrit += crit[b]; thigh += high[b]; tmed += med[b]; tlow += low[b]
      }
      printf "Branches reviewed: %d (all-met: %d, unmet: %d, not-reviewed: %d)\n", n, met, unmet, notrun
      printf "Findings: %d total (CRITICAL: %d, HIGH: %d, MEDIUM: %d, LOW: %d)\n", tcrit+thigh+tmed+tlow, tcrit, thigh, tmed, tlow
      for (i = 1; i <= n; i++) {
        b = order[i]
        v = (verdict[b] == "" ? "unknown" : verdict[b])
        printf "- %s: %s (C:%d H:%d M:%d L:%d)\n", b, v, crit[b], high[b], med[b], low[b]
      }
    }
  ' "${files[@]}"
}

MERGED_SLUGS=$(state get completed)
PARTIAL_SLUGS=$(state get partial)
BLOCKED_SLUGS=$(state get blocked)

echo "Rounds: $(state get rounds)"
echo "Model:  $(state get model)"
echo "Merged  ($(count_csv "$MERGED_SLUGS")): $(or_none "$MERGED_SLUGS")"
echo "Partial ($(count_csv "$PARTIAL_SLUGS")): $(or_none "$PARTIAL_SLUGS")"
echo "Blocked ($(count_csv "$BLOCKED_SLUGS")): $(or_none "$BLOCKED_SLUGS")"
[ "$STALLED" -eq 1 ] && echo "STALLED: resolve blockers and re-run (/crew-afk)"

echo ""
echo "## Code Review"
code_review_summary "$REVIEW_DIR"

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

# --- Merge conflicts (never auto-resolved — see merge-branches.sh) -----------
# A `merge-failed` retention is the one reason above that isn't the branch's content
# needing more work: verify passed, review returned all-met, the AC receipt is on disk,
# and only `git merge --no-ff` itself hit a conflict. merge-branches.sh aborts cleanly
# and never attempts resolution, by design — so unlike every other retained reason,
# re-running crew-afk alone cannot fix this one. Spell out the one manual step that does.
MERGE_CONFLICTS=$(jq -r '(.retention // {}) | to_entries[] | select(.value.reason | startswith("merge-failed")) | .value.branch' "$SF" 2>/dev/null || true)
if [ -n "$MERGE_CONFLICTS" ]; then
  echo ""
  echo "## Merge Conflicts (need a human)"
  echo "crew-afk never resolves merge conflicts automatically. To unblock each branch below:"
  echo "  1. git checkout ${FEATURE_BRANCH:-<feature-branch>} && git merge --no-ff <branch>"
  echo "  2. Resolve the conflicts by hand, then: git add -A && git commit"
  echo "  3. Re-run crew-afk — merge-branches.sh sees the branch as already merged and closes the issue normally."
  printf '%s\n' "$MERGE_CONFLICTS" | sed 's/^/- /'
fi

# --- Environment blockers (triage said not-fixable, twice — see handleVerificationFailure
# in orchestrator/lib/pipeline.mjs) -------------------------------------------
# A `blocked — environment — ...` reason is the other case, alongside merge-failed, that
# isn't the branch's own content needing more work: crew-triage judged the verification
# failure unfixable by recoding, a plain coder-free retry hit the identical failure again,
# and no further sprint round will change that outcome — carved out of the generic Retained
# Branches / Blocked list above so a human scanning the summary sees "go fix the
# registry/network/credentials" at a glance, not "go read what the coder got stuck on".
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

# --- Promoted Findings --------------------------------------------------------
# Read back the markers promote-findings.sh defer appended to each review report:
#   - <branch>: <severities> → <issue path>
# The finding count is the number of acceptance criteria in the fix issue (one per
# promoted finding), and its state is where the issue file now lives.
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

# --- dev-commands.json reminder -----------------------------------------------
# .coding-crew/dev-commands.json is committed and human-editable, but nothing here
# auto-commits it (see PRD: no auto-commit to any branch, ever) — a sprint's bootstrap
# write (discover-commands.sh / write-commands-cache.sh, before any worktree existed) is
# otherwise easy to lose to a stray `git clean` before the next sprint notices it. Stateless
# — re-run `git status` every time, no "already warned" flag file. Omitted when clean or
# absent, following this file's own "sections with nothing to report are omitted" style.
DEV_COMMANDS_STATUS=$(git -C "$MAIN_ROOT" status --porcelain -- .coding-crew/dev-commands.json 2>/dev/null || true)
if [ -n "$DEV_COMMANDS_STATUS" ]; then
  echo ""
  echo "## Dev Commands Cache"
  echo "Reminder: .coding-crew/dev-commands.json has uncommitted changes at MAIN_ROOT — review and commit it."
fi

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
