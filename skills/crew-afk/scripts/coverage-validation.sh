#!/usr/bin/env bash
set -euo pipefail

# Coverage validation — mechanical gate for crew-afk
#
# Coverage validation is **opt-in** (`/crew-afk --coverage`). It is a whole extra reasoning
# pass over the PRD plus every closed issue plus greps of the merged code, producing advisory
# output — after every issue already passed its own acceptance-criteria gate before merging.
# Running it unconditionally cost every sprint 5–15k tokens for a report nothing acts on, so
# the sprint no longer pays for it unless it was asked for.
#
# Responsibilities:
#   1. Refuse unless the sprint was started with --coverage (session-init.sh records it in
#      sprint.env as CREW_COVERAGE; --coverage here, or CREW_COVERAGE=1, also works)
#   2. Locate the feature's PRD.md
#   3. If absent: print a skip message and exit 0
#   4. If present: print the PRD path *and the validation prompt*, so the prompt is only
#      ever in a context window when it is about to be used
#
# The reasoning step (extracting requirements, classifying covered/partial/missing) is done
# by the orchestrator or the validation agent it spawns, using the prompt printed below.
#
# Invocation: bash "<skill-dir>/scripts/coverage-validation.sh" [--coverage]
# (install.sh does not chmod+x skill-local scripts)

COVERAGE_REQUESTED="${CREW_COVERAGE:-0}"
while [ $# -gt 0 ]; do
  case "$1" in
    --coverage) COVERAGE_REQUESTED=1; shift ;;
    *) echo "coverage-validation.sh: unknown argument: $1" >&2; exit 1 ;;
  esac
done

case "$COVERAGE_REQUESTED" in
  1|yes|true|on) ;;
  *)
    echo "Coverage validation: skipped (opt-in — re-run the sprint with --coverage)"
    exit 0
    ;;
esac

# Prefer the slug the sprint recorded; fall back to the branch name for out-of-sprint use.
MAIN_ROOT=$(git rev-parse --show-toplevel)
if [ -z "${FEATURE_SLUG:-}" ] && [ -f "$MAIN_ROOT/.scratch/sprint.env" ]; then
  # shellcheck disable=SC1091
  . "$MAIN_ROOT/.scratch/sprint.env" 2>/dev/null || true
fi
if [ -z "${FEATURE_SLUG:-}" ]; then
  # Strip JIRA prefix (e.g., PROJ-123-) to match session-init.sh behavior.
  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  FEATURE_SLUG=$(echo "$CURRENT_BRANCH" | sed 's|.*/||' | sed -E 's/^[A-Z]+-[0-9]+-//' | sed 's|-[0-9][0-9]-.*||')
fi

PRD_PATH=".scratch/$FEATURE_SLUG/PRD.md"

if [ ! -f "$PRD_PATH" ]; then
  echo "Coverage validation: skipped (no PRD.md found for feature '$FEATURE_SLUG')"
  exit 0
fi

echo "Coverage validation: PRD found at $PRD_PATH"
cat <<PROMPT

--- validation prompt (do not run this on a cheap model tier — it is genuine reasoning) ---
Extract all requirements from $PRD_PATH.

Categories to extract:
- Key User Stories
- Technical decisions
- Cross-cutting concerns (error handling, logging, security, performance, testing,
  architecture, validation, observability)
- Interface contracts
- Multi-issue flows

For each requirement, check:
1. Completed issues in .scratch/$FEATURE_SLUG/issues/done/ — match requirement to issue
   acceptance criteria
2. Merged code — heuristic validation (grep for relevant patterns, function names, config
   changes)

Classify each requirement as:
✓ covered - found in both issue criteria and code
⚠ partial - found in issue criteria OR code, but not both
✗ missing - no evidence in either

Report format:
✓ N covered / ⚠ N partial / ✗ N missing

### Details
✓ <requirement>: <brief evidence from issues/code>
⚠ <requirement>: <what's present and what's missing>
✗ <requirement>: <no evidence found>
--- end validation prompt ---
PROMPT
exit 0
