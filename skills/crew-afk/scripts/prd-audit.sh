#!/usr/bin/env bash
set -euo pipefail

# PRD audit — mechanical gate for crew-afk's prdAuditor
#
# The reviewer checks one branch against its own issue's acceptance criteria. What no
# per-branch review can see is a PRD requirement that no issue ever carried, or a flow that
# spans several issues. That is this audit's job, run once, after Phase 1 has drained.
#
# Mode is config.json's afk.PRDAudit (`--prd-audit` for one run), recorded in sprint.env by
# session-init.sh as CREW_PRD_AUDIT:
#   off     skip
#   report  audit, and leave the report for a human
#   fix     audit, and the orchestrator queues each ✗ missing requirement for Phase 2
#
# A PRD can be older than the decisions made since it was written. A requirement a later ADR,
# CONTEXT.md entry or commit replaced is ⊘ superseded: named in the summary for a human, never
# queued in either mode.
#
# Responsibilities:
#   1. Skip when the mode is off
#   2. Locate the feature's PRD — .scratch/<slug>/PRD.md, or failing that under tracker:
#      github the milestone's "PRD:" issue, fetched to .scratch/<slug>/prd-issue.md; if
#      neither, print a skip message and exit 0
#   3. If present: print the PRD path *and the audit prompt*, so the prompt is only ever in a
#      context window when it is about to be used
#
# The reasoning step is the prdAuditor dispatch (orchestrator/lib/loop.mjs), using the prompt
# printed below. Its closing fenced json is the only part the orchestrator reads.
#
# Invocation: bash "<skill-dir>/scripts/prd-audit.sh" [--mode off|report|fix]
# (install.sh does not chmod+x skill-local scripts)

MODE="${CREW_PRD_AUDIT:-off}"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:?--mode requires off, report or fix}"; shift 2 ;;
    *) echo "prd-audit.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$MODE" in
  report|fix) ;;
  off)
    echo "PRD audit: skipped (PRDAudit is off — set afk.PRDAudit in .coding-crew/config.json, or --prd-audit report|fix)"
    exit 0
    ;;
  *) echo "prd-audit.sh: --mode must be off, report or fix (got '$MODE')" >&2; exit 1 ;;
esac

MAIN_ROOT=$(git rev-parse --show-toplevel)
if [ -z "${FEATURE_SLUG:-}" ] && [ -f "$MAIN_ROOT/.scratch/sprint.env" ]; then
  # shellcheck disable=SC1091
  . "$MAIN_ROOT/.scratch/sprint.env" 2>/dev/null || true
fi
if [ -z "${FEATURE_SLUG:-}" ]; then
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  FEATURE_SLUG=$(echo "$CURRENT_BRANCH" | sed 's|.*/||' | sed -E 's/^[A-Z]+-[0-9]+-//' | sed 's|-[0-9][0-9]-.*||')
fi

# Which backend holds the PRD and the finished issues — the lookup chain promote-findings.sh
# uses. Missing reader means local.
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

if [ "$TRACKER_CONFIG_TRACKER" = "github" ] && [ ! -f ".scratch/$FEATURE_SLUG/PRD.md" ]; then
  # to-prd publishes the PRD as the milestone's "PRD: <title>" issue, with no local file, so
  # its body is fetched into the sprint dir for the auditor to read. A local PRD.md, when
  # there is one, is still read first.
  node_cli="${CREW_GITHUB_TRACKER_CLI:-}"
  [ -f "$node_cli" ] || node_cli="$MAIN_ROOT/.coding-crew/crew-afk/lib/trackers/github.mjs"
  [ -f "$node_cli" ] || node_cli="$HOME/.coding-crew/crew-afk/lib/trackers/github.mjs"
  if [ ! -f "$node_cli" ]; then
    echo "PRD audit: skipped (github tracker CLI github.mjs not found — cannot fetch the PRD issue)"
    exit 0
  fi
  PRD_PATH=".scratch/$FEATURE_SLUG/prd-issue.md"
  mkdir -p "$MAIN_ROOT/.scratch/$FEATURE_SLUG"
  set +e
  prd_err=$(node "$node_cli" prd --feature-slug "$FEATURE_SLUG" --main-root "$MAIN_ROOT" 2>&1 >"$MAIN_ROOT/$PRD_PATH")
  prd_rc=$?
  set -e
  if [ "$prd_rc" -eq 3 ]; then
    rm -f "$MAIN_ROOT/$PRD_PATH"
    echo "PRD audit: skipped (no \"PRD:\" issue in milestone '$FEATURE_SLUG')"
    exit 0
  elif [ "$prd_rc" -ne 0 ]; then
    rm -f "$MAIN_ROOT/$PRD_PATH"
    echo "PRD audit: skipped (could not fetch the PRD issue: ${prd_err:+$(printf "%s" "$prd_err" | tr "\n" " ")}exit $prd_rc)"
    exit 0
  fi
  DONE_ISSUES="the done issues in GitHub milestone '$FEATURE_SLUG' — labelled awaiting-merge or closed (gh issue list --milestone '$FEATURE_SLUG' --state all, then keep those two)"
else
  PRD_PATH=".scratch/$FEATURE_SLUG/PRD.md"
  if [ ! -f "$PRD_PATH" ]; then
    echo "PRD audit: skipped (no PRD.md found for feature '$FEATURE_SLUG')"
    exit 0
  fi
  DONE_ISSUES=".scratch/$FEATURE_SLUG/issues/done/"
  [ "$TRACKER_CONFIG_TRACKER" = "github" ] &&
    DONE_ISSUES="the done issues in GitHub milestone '$FEATURE_SLUG' — labelled awaiting-merge or closed (gh issue list --milestone '$FEATURE_SLUG' --state all, then keep those two)"
fi

echo "PRD audit: PRD found at $PRD_PATH (mode: $MODE)"
cat <<PROMPT

--- audit prompt (do not run this on a cheap model tier — it is genuine reasoning) ---
Extract all requirements from $PRD_PATH.

Categories to extract:
- Behaviours (B-IDs when present)
  (an older PRD has "## Key User Stories" instead — treat those as behaviours)
- Technical decisions
- Cross-cutting concerns (error handling, logging, security, performance, testing,
  architecture, validation, observability)
- Interface contracts
- Multi-issue flows

Every issue in $DONE_ISSUES already passed a review of its own
acceptance criteria against its diff before it merged. Treat those criteria as met; do not
re-grade them. Your job is what that per-issue review cannot see:
1. A requirement no issue's acceptance criteria carry at all.
2. A flow or contract that spans several issues — does the merged code connect them?
3. A cross-cutting concern the PRD asks for that no single issue owned.

Check the merged code for each (grep for relevant patterns, function names, config).

The PRD records the plan as of when it was written, and may be older than decisions made
since. Before calling a requirement missing, check whether a later decision replaced it: an
ADR (any docs/adr/ directory), CONTEXT.md, or the git history of the code it names. A
requirement a later decision deliberately contradicts is superseded, not missing — a coder
must not be sent to build it. Name the decision; a requirement merely absent is not
superseded.

Classify each requirement as:
✓ covered - an issue's criteria carry it, or the merged code clearly implements it
⚠ partial - part of it is carried or implemented, part is not
✗ missing - no issue carries it and the merged code has no evidence of it
⊘ superseded - a later ADR, CONTEXT.md entry or commit deliberately decided otherwise

Report format:
✓ N covered / ⚠ N partial / ✗ N missing / ⊘ N superseded

✓ <requirement>: <brief evidence from issues/code>
⚠ <requirement>: <what's present and what's missing>
✗ <requirement>: <no evidence found>
⊘ <requirement>: <the decision that replaced it, with its path or commit>

End with exactly one fenced json block, the only part a program reads. Each ✗ missing entry
is written as an acceptance criterion a coder could implement and a reviewer could check;
each ⊘ superseded entry names what replaced it, for a human to update the PRD:

\`\`\`json
{"covered": N, "partial": N, "missing": [{"requirement": "<the criterion>", "detail": "<what the PRD asks, where you looked>"}], "superseded": [{"requirement": "<the PRD's requirement>", "by": "<the ADR, CONTEXT.md entry or commit>"}]}
\`\`\`
--- end audit prompt ---
PROMPT
exit 0
