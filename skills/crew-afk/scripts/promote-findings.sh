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
# Each subcommand traces its own outcome, so promotion, the phase flip and a review gap
# are all in the trace whether or not the orchestrator remembered to echo them.
_trace() { [ -f "$SCRIPT_DIR/trace.sh" ] && bash "$SCRIPT_DIR/trace.sh" "$@" 2>/dev/null; return 0; }

DEFERRED_STATUS="deferred-findings"
READY_STATUS="ready-for-agent"

# --- promotion threshold -----------------------------------------------------
# Default: CRITICAL only. Each promoted branch costs a full worker + verify + review + merge
# cycle, and HIGH is the reviewer's judgement class ("architecture drift", "trust boundary") —
# the most false-positive-prone severity — so promoting it by default spent a whole pipeline on
# findings a human would often dismiss. HIGH is not dropped: nothing subtracts an unpromoted
# severity from `remind`, so every HIGH is counted and named for /crew-address-findings.
# `--promote critical-high` (recorded in sprint.env by session-init.sh as CREW_PROMOTE)
# restores the old behaviour.
promote_severities() {
  case "${CREW_PROMOTE:-critical}" in
    critical-high) echo "CRITICAL, HIGH" ;;
    *) echo "CRITICAL" ;;
  esac
}

usage() {
  cat >&2 <<'USAGE'
Usage:
  promote-findings.sh policy
  promote-findings.sh guard --issue <issue-file>
  promote-findings.sh defer --feature-slug <slug> --branch <branch> --slug <issue-slug>
                            --title <title> --report <review-report> --criteria-file <file>
                            [--severities CRITICAL,HIGH]
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

  # A missing file cannot be shown to be a fix issue. Fail closed: no promotion.
  if [ ! -f "$issue" ]; then
    echo "guard: skip — issue file not found: $issue"
    exit 0
  fi

  if grep -q '^Source:' "$issue"; then
    echo "guard: skip — source-guarded (this issue was itself promoted from a review)"
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
cmd_defer() {
  local slug="" branch="" issue_slug="" title="" report="" criteria_file="" severities
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
      *) usage ;;
    esac
  done
  [ -n "$slug" ] && [ -n "$branch" ] && [ -n "$issue_slug" ] || usage
  [ -n "$title" ] && [ -n "$report" ] && [ -n "$criteria_file" ] || usage
  [ -f "$criteria_file" ] || die "criteria file not found: $criteria_file"
  [ -f "$report" ] || die "review report not found: $report"
  [ -s "$criteria_file" ] || die "criteria file is empty: $criteria_file (nothing to promote)"

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

  # Annotate the report so a later human run of /crew-address-findings does not
  # re-triage findings this sprint already fixed. Appended at the end of the file
  # (the report is fully written before promotion runs), keyed by branch + severity —
  # promotion always takes *all* findings at those severities for that branch, so the
  # pair is an unambiguous marker with no per-finding parsing.
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
  echo "- $branch: $severities → $issue_path" >> "$report"

  _trace PROMOTE "branch=$branch issue=$issue_path severities=$severities"
  echo "defer: $issue_path"
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

  {
    [ -s "$report" ] && echo ""
    echo "## Branch: $branch ($issue_slug)"
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

  # Two passes per file: the ## Promoted Findings section sits at the end of the report,
  # so the promoted set is not known until after the findings have been seen.
  local totals
  totals=$(awk '
    FNR == 1 { pass = (seen[FILENAME]++ ? 2 : 1) }
    /^## Promoted Findings/ { inpromoted = 1; next }
    /^## Branch:/ {
      inpromoted = 0
      branch = $0
      sub(/^## Branch: */, "", branch)
      # The reviewer emits "## Branch: <branch> (<slug>)". The promotion marker keys the
      # bare branch name, so the trailing parenthetical must come off or no promoted
      # finding ever matches and every one of them is counted again.
      sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/, "", branch)
      next
    }
    pass == 1 && inpromoted && /^- .*:.*→/ {
      b = $0
      sub(/^- */, "", b)
      sub(/:.*/, "", b)
      sevs = $0
      sub(/^[^:]*: */, "", sevs)
      sub(/ *→.*/, "", sevs)
      n = split(sevs, parts, /, */)
      for (i = 1; i <= n; i++) {
        gsub(/^ +| +$/, "", parts[i])
        promoted[b, parts[i]] = 1
      }
      next
    }
    # A finding is counted once, whichever form it arrives in. The reviewer emits both a
    # machine-readable `FINDING: <SEV> | file:line | criterion` line and a `[SEV]` prose
    # block per finding, but promotion parses only the first — so counting only the second
    # would let a report that carries just the machine line end a sprint as "no open
    # findings" while `findingsAtOrAbove()` was happily promoting from it. Per branch and
    # severity the count is the larger of the two, which is exact when both forms are
    # present (they are 1:1) and correct when only one is.
    pass == 2 && /^FINDING:[[:space:]]*(CRITICAL|HIGH|MEDIUM|LOW)/ {
      sev = $0
      sub(/^FINDING:[[:space:]]*/, "", sev)
      sub(/[^A-Z].*$/, "", sev)
      machine[branch, sev]++
      next
    }
    pass == 2 && /^Review: not_run/ {
      reason = $0
      sub(/^Review: not_run[[:space:]]*(—|-)?[[:space:]]*/, "", reason)
      notrun[branch] = reason
      next
    }
    # A retry that completes clears an earlier round not_run stub for the same branch.
    # Report files are named with a creation timestamp and globbed in that order, so a
    # genuine AC verdict (only the mark-not-run stub omits one) seen for a branch after
    # its not_run entry means the branch *was* reviewed on a later attempt — the earlier
    # stub is stale and must not still flag the branch as unreviewed.
    pass == 2 && /^AC:[[:space:]]*(all-met|unmet)/ {
      if (branch in notrun) delete notrun[branch]
      next
    }
    pass == 2 {
      for (sev in wanted) {
        if (index($0, "[" sev "]") > 0) prose[branch, sev]++
      }
    }
    BEGIN { split("CRITICAL HIGH MEDIUM LOW", order, " "); for (i in order) wanted[order[i]] = 1 }
    END {
      for (key in machine) seen[key] = 1
      for (key in prose) seen[key] = 1
      for (key in seen) {
        if (key in promoted) continue
        split(key, kp, SUBSEP)
        sev = kp[2]
        open[sev] += (machine[key] > prose[key] ? machine[key] : prose[key])
      }
      total = 0
      out = ""
      for (i = 1; i <= 4; i++) {
        sev = order[i]
        if (open[sev] > 0) {
          total += open[sev]
          out = out (out == "" ? "" : ", ") sev "=" open[sev]
        }
      }
      print total "\t" out
      for (b in notrun) print "GAP\t" b "\t" notrun[b]
    }
  ' "${reports[@]}" "${reports[@]}")

  local total breakdown gaps gap_count
  total=$(printf '%s\n' "$totals" | head -1 | cut -f1)
  breakdown=$(printf '%s\n' "$totals" | head -1 | cut -f2)
  gaps=$(printf '%s\n' "$totals" | grep '^GAP' || true)
  gap_count=$(printf '%s' "$gaps" | grep -c '^GAP' || true)

  if [ "${total:-0}" -eq 0 ]; then
    echo "FINDINGS: none"
  else
    echo "FINDINGS: open=$total ($breakdown)"
    printf 'report: %s\n' "${reports[@]}"
  fi

  # Printed after the findings line and never suppressed by it: a sprint with zero open
  # findings and an unreviewed branch is exactly the case that must not look clean.
  if [ "${gap_count:-0}" -gt 0 ]; then
    echo "REVIEW-GAPS: branches=$gap_count"
    printf '%s\n' "$gaps" | while IFS=$'\t' read -r _ branch reason; do
      echo "gap: $branch — $reason"
    done
    # The report paths are printed with the findings line above; when there are no
    # findings, the gap lines are the only reason to name the report, so print them here.
    if [ "${total:-0}" -eq 0 ]; then
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
  flush) cmd_flush "$@" ;;
  list)  cmd_list "$@" ;;
  remind) cmd_remind "$@" ;;
  mark-not-run) cmd_mark_not_run "$@" ;;
  *) usage ;;
esac
