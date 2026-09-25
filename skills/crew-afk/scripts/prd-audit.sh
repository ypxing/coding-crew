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
# Responsibilities:
#   1. Skip when the mode is off
#   2. Locate the feature's PRD.md; if absent, print a skip message and exit 0
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

PRD_PATH=".scratch/$FEATURE_SLUG/PRD.md"

if [ ! -f "$PRD_PATH" ]; then
  echo "PRD audit: skipped (no PRD.md found for feature '$FEATURE_SLUG')"
  exit 0
fi

echo "PRD audit: PRD found at $PRD_PATH (mode: $MODE)"
cat <<PROMPT

--- audit prompt (do not run this on a cheap model tier — it is genuine reasoning) ---
Extract all requirements from $PRD_PATH.

Categories to extract:
- Key User Stories
- Technical decisions
- Cross-cutting concerns (error handling, logging, security, performance, testing,
  architecture, validation, observability)
- Interface contracts
- Multi-issue flows

Every issue in .scratch/$FEATURE_SLUG/issues/done/ already passed a review of its own
acceptance criteria against its diff before it merged. Treat those criteria as met; do not
re-grade them. Your job is what that per-issue review cannot see:
1. A requirement no issue's acceptance criteria carry at all.
2. A flow or contract that spans several issues — does the merged code connect them?
3. A cross-cutting concern the PRD asks for that no single issue owned.

Check the merged code for each (grep for relevant patterns, function names, config).

Classify each requirement as:
✓ covered - an issue's criteria carry it, or the merged code clearly implements it
⚠ partial - part of it is carried or implemented, part is not
✗ missing - no issue carries it and the merged code has no evidence of it

Report format:
✓ N covered / ⚠ N partial / ✗ N missing

✓ <requirement>: <brief evidence from issues/code>
⚠ <requirement>: <what's present and what's missing>
✗ <requirement>: <no evidence found>

End with exactly one fenced json block, the only part a program reads. Each ✗ missing entry
is written as an acceptance criterion a coder could implement and a reviewer could check:

\`\`\`json
{"covered": N, "partial": N, "missing": [{"requirement": "<the criterion>", "detail": "<what the PRD asks, where you looked>"}]}
\`\`\`
--- end audit prompt ---
PROMPT
exit 0
