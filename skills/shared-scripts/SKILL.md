---
name: shared-scripts
description: >
  Shared scripts library used by multiple skills (branch safety, feature branch setup, commit changes).
  This is infrastructure - not invoked directly by users.
---

# Shared Scripts Library

This skill provides reusable bash scripts used by other skills like `solve-issue`, `address-pr-comments`, `address-code-review`, and `afk-sprint`.

## Available Scripts

### branch-safety-check.sh
Validates the current branch is not a default branch (main/master/develop).
Used by address-* skills to prevent accidental commits to protected branches.

### feature-branch-setup.sh
Creates or switches to a feature branch based on an issue slug.
Supports JIRA ticket integration via `--jira TICKET-123` flag.

### commit-changes.sh
Safely stages and commits specific files with standardized commit messages.
Supports optional prefixes and co-authors.

## Usage

Skills that depend on `shared-scripts` should use platform detection:

```bash
# Auto-detect platform directory
if [ -d ".claude" ]; then
  PLATFORM_DIR=".claude"
elif [ -d ".copilot" ]; then
  PLATFORM_DIR=".copilot"
else
  echo "Error: No .claude or .copilot directory found" >&2
  exit 1
fi

# Call shared scripts
bash "$PLATFORM_DIR/skills/shared-scripts/scripts/feature-branch-setup.sh" "$@"
```

## See Also

Full documentation in `scripts/README.md`.
