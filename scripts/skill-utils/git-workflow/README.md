# Git Workflow Scripts

**Infrastructure scripts for skill build-time copying**

This directory contains reusable bash scripts that are copied into skills during `install.sh` execution. These scripts are **not skills themselves** — they are infrastructure utilities that skills use for git/branch/commit operations.

## Purpose

These scripts provide consistent git workflow operations across multiple skills:
- Branch safety validation
- Feature branch creation and switching
- Standardized commit operations

## How It Works

During installation (`install.sh`), skills that declare a `scripts` field in `registry.json` will have these scripts copied into their local `scripts/` directory:

```json
"solve-issue": {
  "scripts": ["feature-branch-setup.sh", "commit-changes.sh"],
  ...
}
```

After installation, skills reference them locally:
```bash
bash scripts/feature-branch-setup.sh "$ISSUE_PATH"
```

## Scripts

### `branch-safety-check.sh`

**Purpose**: Validate that the current branch is safe for operations (not on default branch).

**Usage**:
```bash
bash scripts/branch-safety-check.sh [--allow-default]
```

**Arguments**:
- `--allow-default`: Allow execution on default branch (prints warning instead of error)

**Exit codes**:
- `0`: Safe to proceed
- `1`: On default branch and not allowed

**Used by**:
- `address-pr-comments` (Step 0)
- `address-code-review` (Step 0)

**Example**:
```bash
# Enforce non-default branch
bash scripts/branch-safety-check.sh

# Allow default branch with warning
bash scripts/branch-safety-check.sh --allow-default
```

---

### `feature-branch-setup.sh`

**Purpose**: Create or switch to a feature branch based on issue slug. Optionally includes JIRA ticket prefix.

**Usage**:
```bash
bash scripts/feature-branch-setup.sh <issue-path> [--jira TICKET-123]
```

**Arguments**:
- `issue-path`: Path to the issue markdown file
- `--jira TICKET-123`: Optional JIRA ticket ID (validated format: `[A-Z]+-[0-9]+`)

**Behavior**:
- If on default branch: creates or switches to `feature/<slug>` or `feature/<JIRA>-<slug>`
- If already on non-default branch: no-op (stays on current branch)

**Environment variables**:
- `PROJECT_ROOT`: Optional, defaults to current directory

**Used by**:
- `solve-issue` (Step 0)
- `afk-sprint` (for single-issue mode)

**Example**:
```bash
# Simple feature branch
bash scripts/feature-branch-setup.sh .scratch/auth/issues/01-add-logout.md

# With JIRA ticket
bash scripts/feature-branch-setup.sh .scratch/auth/issues/01-add-logout.md --jira PROJ-456
# Creates: feature/PROJ-456-add-logout
```

---

### `commit-changes.sh`

**Purpose**: Stage specific files and commit with standardized message format.

**Usage**:
```bash
bash scripts/commit-changes.sh \
  --message "msg" \
  --files "file1 file2 file3" \
  [--coauthor "Name <email>"] \
  [--prefix "[slug]"]
```

**Arguments**:
- `--message`: Commit message body (required)
- `--files`: Space-separated list of files to stage (required)
- `--coauthor`: Optional Co-authored-by trailer
- `--prefix`: Optional prefix for commit message (e.g., "[01-auth]")

**Safety**:
- Never uses `git add -A` or `git add .`
- Only stages explicitly listed files
- Validates all required arguments

**Environment variables**:
- `PROJECT_ROOT`: Optional, defaults to current directory

**Used by**:
- `solve-issue` (Step 6)
- `address-pr-comments` (Step 5)
- `address-code-review` (Step 5)

**Example**:
```bash
# Simple commit
bash scripts/commit-changes.sh \
  --message "Fix authentication bug" \
  --files "src/auth.ts test/auth.test.ts"

# With issue prefix and co-author
bash scripts/commit-changes.sh \
  --prefix "[01-auth]" \
  --message "Add logout endpoint" \
  --files "src/api/auth.ts test/api/auth.test.ts" \
  --coauthor "Claude <noreply@anthropic.com>"
```

---

## Benefits

- **Consistency**: Same git workflow logic across all skills
- **Maintainability**: Fix bugs in one central location
- **Testability**: Scripts can be tested independently
- **Clarity**: Skills focus on workflow, not git implementation details
- **Reusability**: New skills can leverage existing scripts
- **Independence**: Each skill gets its own copy - no runtime dependencies

## Maintenance

To update scripts:
1. Edit scripts in `scripts/skill-utils/git-workflow/`
2. Run `install.sh` in consuming repos to get updates
3. Each skill maintains its own installed copy

## See Also

- `install.sh` - Script copying logic
- `registry.json` - Skill script declarations
- Individual skill SKILL.md files for usage context
