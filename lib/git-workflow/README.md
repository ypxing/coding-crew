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
  --coauthor "Claude <noreply@anthropic.com>"
```

---

### `discover-commands.sh`

**Purpose**: Mechanically decide whether a one-time command-discovery model call is needed, and if so, build its prompt (why this exists: CLAUDE.md/Makefile discovery by regex breaks on real-world tables and prose; a model reads the same files instead, once per repo, cached).

**Usage**:
```bash
bash scripts/git-workflow/discover-commands.sh [--refresh]
```

**Behavior**: Prints either a skip message (nothing to read, or `.coding-crew/dev-commands.json` already exists) or the full discovery prompt, ready to hand to a model as-is. Bootstrap-only: once the cache file exists it is trusted as-is, indefinitely, until a human clears it or passes `--refresh` (or `CREW_COMMANDS_REFRESH=1`) — there is no staleness re-check against source-doc content. The prompt asks for five fields, not three: `test`/`lint`/`typecheck`, plus `install` — a documented install command, reported only when the source explicitly states one, so dep-install can use it in place of its own mechanical Makefile-target/lockfile guess — and `env` — a documented `.env`-bootstrap command, reported the same way, so `ensure-env.sh` can use it in place of its own mechanical `.env.example`-or-empty convention.

**Used by**:
- `add-tests`

Not used by `solve-issue`: its own agent turn already *is* the model, so there is no separate
dispatch to build a prompt for — solve-issue's Step 5 inlines the equivalent bootstrap check
directly and reads `.coding-crew/dev-commands.json` itself when it is usable.

---

### `write-commands-cache.sh`

**Purpose**: Turn a model's discovery response into `.coding-crew/dev-commands.json` — a committed, human-editable file, so there is no staleness stamp to compute; once it exists, `discover-commands.sh` trusts it as-is.

**Usage**:
```bash
bash scripts/git-workflow/write-commands-cache.sh --response-file <path>
```

**Behavior**: Extracts `test`/`lint`/`typecheck`/`install`/`env`/`credential_target`/`coverage`/`integration` from the response, and `install_mode`/`docker_service` from dep-install's confirmed answer (tolerant of surrounding prose or a markdown code fence), and merges them into the current checkout's `.coding-crew/dev-commands.json`. A response with none of the fields recognisable fails without touching any existing cache.

**Used by**: the same two callers as `discover-commands.sh`, immediately after the model call it requested.

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
