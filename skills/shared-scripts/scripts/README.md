# Shared Scripts

This directory contains reusable shell scripts that are shared across multiple skills to reduce duplication and improve maintainability.

## Scripts

### `branch-safety-check.sh`

**Purpose**: Validate that the current branch is safe for operations (not on default branch).

**Usage**:
```bash
bash skills/shared-scripts/scripts/branch-safety-check.sh [--allow-default]
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
bash skills/shared-scripts/scripts/branch-safety-check.sh

# Allow default branch with warning
bash skills/shared-scripts/scripts/branch-safety-check.sh --allow-default
```

---

### `feature-branch-setup.sh`

**Purpose**: Create or switch to a feature branch based on issue slug. Optionally includes JIRA ticket prefix.

**Usage**:
```bash
bash skills/shared-scripts/scripts/feature-branch-setup.sh <issue-path> [--jira TICKET-123]
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
- Can also be used by `afk-sprint` for single-issue mode

**Example**:
```bash
# Simple feature branch
bash skills/shared-scripts/scripts/feature-branch-setup.sh .scratch/auth/issues/01-add-logout.md

# With JIRA ticket
bash skills/shared-scripts/scripts/feature-branch-setup.sh .scratch/auth/issues/01-add-logout.md --jira PROJ-456
# Creates: feature/PROJ-456-add-logout
```

---

### `commit-changes.sh`

**Purpose**: Stage specific files and commit with standardized message format.

**Usage**:
```bash
bash skills/shared-scripts/scripts/commit-changes.sh \
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
bash skills/shared-scripts/scripts/commit-changes.sh \
  --message "Fix authentication bug" \
  --files "src/auth.ts test/auth.test.ts"

# With issue prefix and co-author
bash skills/shared-scripts/scripts/commit-changes.sh \
  --prefix "[01-auth]" \
  --message "Add logout endpoint" \
  --files "src/api/auth.ts test/api/auth.test.ts" \
  --coauthor "Claude <noreply@anthropic.com>"
```

---

## Integration Plan

### Skills to Update

1. **`solve-issue/SKILL.md`**
   - Step 0: Replace lines 50-86 with `bash skills/shared-scripts/scripts/feature-branch-setup.sh "$ISSUE_PATH"`
   - Step 6: Replace lines 144-172 with `bash skills/shared-scripts/scripts/commit-changes.sh ...`

2. **`address-pr-comments/SKILL.md`**
   - Step 0: Replace lines 26-45 with `bash skills/shared-scripts/scripts/branch-safety-check.sh`
   - Step 5: Replace lines 116-134 with `bash skills/shared-scripts/scripts/commit-changes.sh ...`

3. **`address-code-review/SKILL.md`**
   - Step 0: Replace lines 23-37 with `bash skills/shared-scripts/scripts/branch-safety-check.sh`
   - Step 5: Replace lines 102-122 with `bash skills/shared-scripts/scripts/commit-changes.sh ...`

### Benefits

- **Consistency**: Same branch logic across all skills
- **Maintainability**: Fix bugs in one place
- **Testability**: Scripts can be tested independently
- **Clarity**: Skills focus on workflow, not implementation details
- **Reusability**: New skills can leverage existing scripts

### Installation

When installing skills via `install.sh`, the `_shared/` directory should be copied to the target repo so scripts are available to all skills:

```bash
# In install.sh
cp -r skills/shared-scripts "$TARGET_REPO/skills/shared-scripts"
```

---

## Development Guidelines

When modifying these scripts:

1. **Maintain backward compatibility** - existing skill invocations should continue to work
2. **Validate inputs** - check for required arguments and proper formats
3. **Use meaningful exit codes** - 0 for success, non-zero for errors
4. **Write to stderr for errors** - use `>&2` for error messages
5. **Support `PROJECT_ROOT`** - respect existing environment variable
6. **Test with both platforms** - Claude Code and GitHub Copilot

## Testing

```bash
# Branch safety check
cd /path/to/repo
git checkout main
bash skills/shared-scripts/scripts/branch-safety-check.sh  # should error
git checkout feature/test
bash skills/shared-scripts/scripts/branch-safety-check.sh  # should succeed

# Feature branch setup
bash skills/shared-scripts/scripts/feature-branch-setup.sh .scratch/test/issues/01-test.md
git branch | grep "feature/test"

# Commit changes
echo "test" > test.txt
bash skills/shared-scripts/scripts/commit-changes.sh \
  --message "Test commit" \
  --files "test.txt"
git log -1
```
