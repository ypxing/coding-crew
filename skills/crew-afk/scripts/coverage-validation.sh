#!/usr/bin/env bash
set -euo pipefail

# Coverage validation — mechanical gate for crew-afk
#
# Responsibilities:
#   1. Extract the feature slug from the current branch
#   2. Locate the feature's PRD.md
#   3. If absent: print a skip message and exit 0
#   4. If present: print the PRD path and exit 0
#
# The reasoning step (extracting requirements, classifying covered/partial/missing)
# is done by the orchestrator's validation agent, which is invoked only when this
# script exits 0 and its output contains a PRD path.
#
# Invocation: bash "<skill-dir>/scripts/coverage-validation.sh"
# (install.sh does not chmod+x skill-local scripts)

# Extract feature slug from current branch.
# Strip JIRA prefix (e.g., PROJ-123-) to match session-init.sh behavior.
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
FEATURE_SLUG=$(echo "$CURRENT_BRANCH" | sed 's|.*/||' | sed -E 's/^[A-Z]+-[0-9]+-//' | sed 's|-[0-9][0-9]-.*||')

# Locate PRD.md for this feature
PRD_PATH=".scratch/$FEATURE_SLUG/PRD.md"

if [ ! -f "$PRD_PATH" ]; then
  echo "Coverage validation: skipped (no PRD.md found for feature '$FEATURE_SLUG')"
  exit 0
fi

echo "Coverage validation: PRD found at $PRD_PATH"
exit 0
