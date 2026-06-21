#!/usr/bin/env bash
set -euo pipefail

# Coverage validation for afk-run
# Checks design.md/PRD.md against completed issues and merged code

# Extract feature slug from current branch
# Strip JIRA prefix (e.g., PROJ-123-) to match session-init.sh behavior
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
FEATURE_SLUG=$(echo "$CURRENT_BRANCH" | sed 's|.*/||' | sed 's/^[A-Z]\+-[0-9]\+-//' | sed 's|-[0-9][0-9]-.*||')

# Check for design.md or PRD.md
DESIGN_PATH=".scratch/$FEATURE_SLUG/design.md"
PRD_PATH=".scratch/$FEATURE_SLUG/PRD.md"

if [ ! -f "$DESIGN_PATH" ] && [ ! -f "$PRD_PATH" ]; then
  echo "Coverage validation: skipped (no design.md or PRD.md found)"
  exit 0
fi

# TODO: Spawn validation agent
echo "Coverage validation: not yet implemented"
exit 0
