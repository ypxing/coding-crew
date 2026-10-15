# Git Workflow Scripts

**A library: shared scripts, linked into the skills that use them**

These scripts are **not skills themselves** — they are infrastructure utilities that skills use for git/branch/commit operations.

## Purpose

These scripts provide consistent git workflow operations across multiple skills:
- Branch safety validation
- Standardized commit operations

## How It Works

`install.sh` writes this directory once to `<root>/.coding-crew/lib/git-workflow/` and links it as
`<skill-dir>/scripts/git-workflow` into every skill whose `libs` in `registry.json` names it:

```json
"solve-issue": {
  "libs": ["checks", "git-workflow", "tracker"],
  ...
}
```

Skills run them through the link:
```bash
bash "<skill-dir>/scripts/git-workflow/commit-changes.sh" --message "..." --files "..."
```

## Scripts

### `branch-safety-check.sh`

**Purpose**: Validate that the current branch is safe for operations (not on default branch).

**Usage**:
```bash
bash scripts/git-workflow/branch-safety-check.sh [--allow-default]
```

**Arguments**:
- `--allow-default`: Allow execution on default branch (prints warning instead of error)

**Exit codes**:
- `0`: Safe to proceed
- `1`: On default branch and not allowed

**Used by**:
- `address-pr-comments` (Step 0)

**Example**:
```bash
# Enforce non-default branch
bash scripts/git-workflow/branch-safety-check.sh

# Allow default branch with warning
bash scripts/git-workflow/branch-safety-check.sh --allow-default
```

---

### `commit-changes.sh`

**Purpose**: Stage specific files and commit with standardized message format.

**Usage**:
```bash
bash scripts/git-workflow/commit-changes.sh \
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

**Example**:
```bash
# Simple commit
bash scripts/git-workflow/commit-changes.sh \
  --message "Fix authentication bug" \
  --files "src/auth.ts test/auth.test.ts"

# With issue prefix and co-author
bash scripts/git-workflow/commit-changes.sh \
  --prefix "[01-auth]" \
  --message "Add logout endpoint" \
  --files "src/api/auth.ts test/api/auth.test.ts" \
  --coauthor "<agent name> <agent commit email>"
```

---

## Benefits

- **Consistency**: Same git workflow logic across all skills
- **Maintainability**: Fix bugs in one central location
- **Testability**: Scripts can be tested independently
- **Clarity**: Skills focus on workflow, not git implementation details
- **Reusability**: New skills can leverage existing scripts
- **One copy**: installed once, linked as `<skill-dir>/scripts/git-workflow` into each skill that uses it

## Maintenance

To update scripts:
1. Edit scripts in `lib/git-workflow/`
2. Run `install.sh` in consuming repos to get updates
3. One installed copy, linked into each skill whose registry `libs` names it

## See Also

- `install.sh` - library install and links
- `registry.json` - each skill's `libs`
- Individual skill SKILL.md files for usage context
