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
- `crew-address-findings` (Step 0)

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
- `crew-afk` (for single-issue mode)

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
- `crew-address-findings` (Step 5)

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

### `discover-commands.sh`

**Purpose**: Mechanically decide whether a one-time command-discovery model call is needed, and if so, build its prompt. See `orchestrator/lib/commands.mjs` for the full design (why this exists: CLAUDE.md/Makefile discovery by regex breaks on real-world tables and prose; a model reads the same files instead, once per repo, cached).

**Usage**:
```bash
bash scripts/discover-commands.sh [--refresh]
```

**Behavior**: Prints either a skip message (nothing to read, or `.scratch/commands.json`'s cached `sourceHash` already matches) or the full discovery prompt, ready to hand to a model as-is. The prompt asks for four fields, not three: `test`/`lint`/`typecheck`, plus `install` — a documented install command, reported only when the source explicitly states one, so `ensure-deps.sh` can use it in place of its own mechanical Makefile-target/lockfile guess.

**Used by**:
- `crew-afk` (`orchestrator/lib/commands.mjs`, once per sprint via `dispatchPlain`, run **before** `ensure-deps.sh`'s own sprint-level call so a discovered `install` override is already cached by the time that call reads it)

Not used by `solve-issue`: its own agent turn already *is* the model, so there is no separate
dispatch to build a prompt for — solve-issue's Step 5 inlines the equivalent cache-freshness
check directly and reads `.scratch/commands.json` itself when it is usable.

---

### `write-commands-cache.sh`

**Purpose**: Turn a model's discovery response into `.scratch/commands.json`, stamped with its own independently-computed source hash (never trusts a hash the caller supplies).

**Usage**:
```bash
bash scripts/write-commands-cache.sh --response-file <path>
```

**Behavior**: Extracts `test`/`lint`/`typecheck`/`install` from the response (tolerant of surrounding prose or a markdown code fence). A response with none of the four fields recognisable fails without touching any existing cache.

**Used by**: the same two callers as `discover-commands.sh`, immediately after the model call it requested.

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
