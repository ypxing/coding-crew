#!/usr/bin/env bash
set -euo pipefail

# promote-findings.sh — mechanical half of findings promotion for crew-afk
#
# Findings promotion turns CRITICAL/HIGH code-review findings into fix issues that the
# existing sprint loop implements in a second phase. See references/findings-promotion.md
# for the full policy (severity threshold, per-branch grouping, depth guard, phases).
#
# This script owns only the deterministic parts, so all four platform variants behave
# identically:
#
#   policy  — which severities this sprint promotes (CRITICAL by default)
#   guard   — may findings from this issue's branch be promoted, or is it already a fix issue?
#   defer   — write a parked fix issue (Status: deferred-findings) + annotate the review report
#   defer-gaps — the same for the PRD audit's ✗ missing requirements: one parked issue
#   flush   — flip every parked fix issue to ready-for-agent (Phase 1 → Phase 2 transition)
#   list    — list parked fix issues without changing anything
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
_tracker_config_sh="${CREW_TRACKER_CONFIG:-}"
[ -f "$_tracker_config_sh" ] || _tracker_config_sh="$MAIN_ROOT/.coding-crew/scripts/tracker-config.sh"
[ -f "$_tracker_config_sh" ] || _tracker_config_sh="$HOME/.coding-crew/scripts/tracker-config.sh"
if [ -f "$_tracker_config_sh" ]; then
  # shellcheck disable=SC1090
  source "$_tracker_config_sh"
  read_tracker_config "$MAIN_ROOT"
fi

DEFERRED_STATUS="deferred-findings"
READY_STATUS="ready-for-agent"

# --- promotion threshold -----------------------------------------------------
# The lowest severity fixed automatically: CREW_FIX_FINDINGS (config.json's afk.fixFindings,
# recorded in sprint.env by session-init.sh), default high. Each promoted branch costs a full
# coder + verify + review + merge cycle, which is why MEDIUM — no failure scenario required —
# is opt-in. Nothing unpromoted is dropped: `remind` counts and names it for
# /crew-address-findings. CREW_PROMOTE is the old name (critical | critical-high).
fix_findings_level() {
  local level="${CREW_FIX_FINDINGS:-}"
  if [ -z "$level" ]; then
    case "${CREW_PROMOTE:-}" in
      critical) level="critical" ;;
      *) level="high" ;;
    esac
  fi
  echo "$level"
}

promote_severities() {
  case "$(fix_findings_level)" in
    critical) echo "CRITICAL" ;;
    medium) echo "CRITICAL, HIGH, MEDIUM" ;;
    none) echo "" ;;
    *) echo "CRITICAL, HIGH" ;;
  esac
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  promote-findings.sh policy
  promote-findings.sh guard --issue <issue-file>
  promote-findings.sh defer --feature-slug <slug> --branch <branch> --slug <issue-slug>
                            --title <title> --report <review-report> --criteria-file <file>
                            [--severities CRITICAL,HIGH] [--blocked-by <issue-number>]
  promote-findings.sh defer-gaps --feature-slug <slug> --report <prd-audit-report>
                            --criteria-file <file>
  promote-findings.sh flush --feature-slug <slug>
  promote-findings.sh list  --feature-slug <slug>
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

# --- guard -------------------------------------------------------------------
# The depth bound. A fix issue carries a `Source:` line; findings raised against a fix
# issue's own branch are reported only, never promoted again. That caps the sprint at
# two phases without any counter or state flag.
cmd_guard() {
  local issue=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue) issue="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$issue" ] || usage

  local body
  if [ "$TRACKER_CONFIG_TRACKER" = "github" ]; then
    # No local file to grep — under github, `--issue` is the issue number, and the depth
    # bound must hold against whatever the body says *right now*, not a stale in-memory
    # copy from an earlier `gh issue list`. A human may have edited the body since.
    local repo_args=()
    [ -n "$TRACKER_CONFIG_REPO" ] && repo_args=(--repo "$TRACKER_CONFIG_REPO")
    if ! body="$(gh issue view "$issue" "${repo_args[@]}" --json body -q .body 2>/dev/null)"; then
      # A missing/unreachable issue cannot be shown to be a fix issue. Fail closed: no promotion.
      echo "guard: skip — issue not found: $issue"
      exit 0
    fi
  else
    # A missing file cannot be shown to be a fix issue. Fail closed: no promotion.
    if [ ! -f "$issue" ]; then
      echo "guard: skip — issue file not found: $issue"
      exit 0
    fi
    body="$(cat "$issue")"
  fi

  if printf '%s\n' "$body" | grep -q '^Source:'; then
    echo "guard: skip — source-guarded (this issue was itself promoted from a review)"
  elif [ -z "$(promote_severities)" ]; then
    echo "guard: skip — fixFindings is none"
  else
    # The severity list is printed with the verdict so no caller has to carry the threshold in
    # prose: promote exactly the severities named here, and nothing else.
    echo "guard: promotable — severities: $(promote_severities)"
  fi
}

# --- policy ------------------------------------------------------------------
# One place any caller can ask what this sprint promotes — used by the end-of-sprint reminder
# so it can state the threshold that left a HIGH finding open.
cmd_policy() {
  [ $# -eq 0 ] || usage
  echo "promote: $(promote_severities)"
}

# --- defer -------------------------------------------------------------------

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

# _defer_github <slug> <title> <branch> <report> <criteria-file> <severities> <blocked-by> —
# github path: creates the issue via _github_tracker_cli, labeled ready-for-agent immediately
# (github has no pre-created label to represent "parked", so there is no local-style
# park/flush step for this backend — flush/list correctly report nothing to promote, see
# cmd_flush/cmd_list). The body mirrors local's Source: convention exactly, plus a numeric
# `## Blocked by` reference when the caller names one, so issue 04's parseIssue parses both
# the same way. Prints the created issue's URL (github.mjs's own stdout, itself `gh issue
# create`'s stdout passed through).
_defer_github() {
  local slug="$1" title="$2" branch="$3" report="$4" criteria_file="$5" severities="$6" blocked_by="$7"

  local body_file
  body_file="$(mktemp)"
  {
    echo "Source: $report ($branch)"
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
    echo "The branch already merged — these are follow-up fixes, not a revert. Full reviewer"
    echo "notes, including the snippet citations, are in the review report named in \`Source:\`."
    echo ""
    echo "## Acceptance criteria"
    echo ""
    cat "$criteria_file"
  } > "$body_file"

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
  local slug="" branch="" issue_slug="" title="" report="" criteria_file="" severities blocked_by=""
  severities="$(promote_severities)"
  while [ $# -gt 0 ]; do
    case "$1" in
      --feature-slug) slug="${2:-}"; shift 2 ;;
      --branch) branch="${2:-}"; shift 2 ;;
      --slug) issue_slug="${2:-}"; shift 2 ;;
      --title) title="${2:-}"; shift 2 ;;
      --report) report="${2:-}"; shift 2 ;;
      --criteria-file) criteria_file="${2:-}"; shift 2 ;;
      --severities) severities="${2:-}"; shift 2 ;;
      --blocked-by) blocked_by="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$branch" ] && [ -n "$issue_slug" ] || usage
  [ -n "$title" ] && [ -n "$report" ] && [ -n "$criteria_file" ] || usage
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
      echo "branch is already addressed. Findings at other severities still need triage."
      echo ""
    } >> "$report"
  fi
  echo "- $branch: $severities → $ref" >> "$report"

  _trace PROMOTE "branch=$branch issue=$ref severities=$severities"
  echo "defer: $ref"
}

# --- defer-gaps ----------------------------------------------------------------
# The PRD audit's ✗ missing requirements → one parked fix issue, flushed into Phase 2 with
# the review findings. Its `Source:` line is the same depth bound: findings on its branch are
# report-only. One per feature while it's open — a resumed sprint that audits again must not
# queue the same gaps twice.
cmd_defer_gaps() {
  local slug="" report="" criteria_file=""
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

  local title="Fix PRD gaps: $slug" ref
  local context="Auto-queued by crew-afk from the PRD audit's missing requirements. No issue carried
these, so no review ever checked them. The audit's evidence for each is in the report named in
\`Source:\`."

  if [ "$TRACKER_CONFIG_TRACKER" = "github" ]; then
    local body_file
    body_file="$(mktemp)"
    printf 'Source: %s (prd-audit)\n\n## Context\n\n%s\n\n## Acceptance criteria\n\n' "$report" "$context" > "$body_file"
    cat "$criteria_file" >> "$body_file"
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
    for f in "$open_dir"/*-fix-prd-gaps.md; do
      [ -f "$f" ] && existing="$f"
    done
    if [ -n "${existing:-}" ]; then
      echo "defer-gaps: skip — already queued: $existing"
      return 0
    fi
    ref="$open_dir/$(next_issue_number "$slug")-fix-prd-gaps.md"
    {
      echo "# $title"
      echo ""
      echo "Status: $DEFERRED_STATUS"
      echo "Source: $report (prd-audit)"
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

  _trace PROMOTE "prd-gaps issue=$ref"
  echo "defer-gaps: $ref"
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

  _trace REVIEW "branch=$branch result=not_run"
  echo "mark-not-run: not_run recorded — $branch ($reason)"
}

# --- remind ------------------------------------------------------------------
# Promotion only covers the threshold severities (CRITICAL by default) on Phase 1 branches.
# Everything else — HIGH when the threshold is CRITICAL-only, MEDIUM/LOW always, plus any
# severity raised against a Phase 2 fix branch (report-only by the depth bound) — still needs
# a human. This counts exactly those so the end-of-sprint reminder states a
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

  local rollup
  rollup=$(review_rollup "${reports[@]}")

  # (branch, severity) pairs already covered by a fix issue this sprint — defer's own
  # bash-generated "## Promoted Findings" bullets ("- <branch>: SEV, SEV → <path>"),
  # never the reviewer's free text, so a plain regex capture reads them exactly; no awk
  # state machine needed for a shape this script itself wrote.
  local promoted
  # grep's own "no lines matched" exit status must not reach the pipeline under
  # `pipefail` — `|| true` neutralises it before jq runs, so the `|| echo '[]'` fallback
  # below only fires on an actual jq failure, never doubling jq's own (valid) output.
  promoted=$( (grep -h '^- .*:.*→' "${reports[@]}" 2>/dev/null || true) | jq -R -s '
    [splits("\n") | select(length > 0) |
      (capture("^- *(?<b>[^:]+): *(?<sevs>[^→]+)→")?) |
      select(. != null) |
      {branch: (.b | rtrimstr(" ")), sevs: [.sevs | splits(", *") | gsub("^\\s+|\\s+$"; "") | select(length > 0)]}
    ]
  ' 2>/dev/null || echo '[]')

  # Every open finding, once — there is exactly one representation now (the reviewer's
  # own `findings` array), not a machine line and a prose block to reconcile.
  local totals crit high med low total breakdown
  totals=$(jq -rn --argjson rollup "$rollup" --argjson promoted "$promoted" '
    ($promoted | map(.branch as $b | .sevs[] as $s | {(($b + " " + $s)): true}) | add // {}) as $pset
    | [$rollup.branches[] | .branch as $b | .findings[] | select(($pset[$b + " " + .severity] // false) | not) | .severity] as $open
    | [($open | map(select(. == "CRITICAL")) | length),
       ($open | map(select(. == "HIGH")) | length),
       ($open | map(select(. == "MEDIUM")) | length),
       ($open | map(select(. == "LOW")) | length)] | @tsv
  ')
  IFS=$'\t' read -r crit high med low <<< "$totals"
  total=$((crit + high + med + low))
  breakdown=""
  [ "$crit" -gt 0 ] && breakdown="${breakdown:+$breakdown, }CRITICAL=$crit"
  [ "$high" -gt 0 ] && breakdown="${breakdown:+$breakdown, }HIGH=$high"
  [ "$med" -gt 0 ] && breakdown="${breakdown:+$breakdown, }MEDIUM=$med"
  [ "$low" -gt 0 ] && breakdown="${breakdown:+$breakdown, }LOW=$low"

  if [ "$total" -eq 0 ]; then
    echo "FINDINGS: none"
  else
    echo "FINDINGS: open=$total ($breakdown)"
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
    if [ "$total" -eq 0 ]; then
      printf 'report: %s\n' "${reports[@]}"
    fi
  fi
}

COMMAND="${1:-}"
[ -n "$COMMAND" ] || usage
shift || true

case "$COMMAND" in
  policy) cmd_policy "$@" ;;
  guard) cmd_guard "$@" ;;
  defer) cmd_defer "$@" ;;
  defer-gaps) cmd_defer_gaps "$@" ;;
  flush) cmd_flush "$@" ;;
  list)  cmd_list "$@" ;;
  remind) cmd_remind "$@" ;;
  mark-not-run) cmd_mark_not_run "$@" ;;
  *) usage ;;
esac
