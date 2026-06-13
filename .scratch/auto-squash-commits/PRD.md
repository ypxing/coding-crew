# PRD: Auto-Squash Commits for Clean Feature Branch History

## Problem Statement

Agent skills (`afk-sprint`, `solve-issue`) currently commit each issue individually, resulting in multiple commits per sprint. Users want a clean, single commit per sprint session on their feature branch before creating a PR. Additionally, users can accidentally commit agent work directly to the default branch (main/master) without realizing it, bypassing the PR workflow.

This is problematic for:
- Teams that prefer atomic feature commits for cleaner git history
- PR workflows where squash should happen before push, not relying on GitHub's squash-merge
- Preventing accidental commits to protected default branches
- Maintaining semantic commit history while preserving granular work during development

## Solution

Transform the agent workflow to use feature branches with automatic commit squashing:

1. **Feature branch workflow**: Detect when on default branch, automatically create or switch to feature branch
2. **Individual commits during development**: Each issue commits with `[issue-slug]` prefix for traceability
3. **Auto-squash after sprint**: All completed issue commits squashed into one clean commit
4. **Iterative support**: Multiple sprint sessions on same branch accumulate multiple squashed commits (one per session)
5. **Default branch protection**: Block work on main/master with clear error messages

## Key User Stories

1. As a **developer running afk-sprint**, I want commits automatically squashed into one clean commit per sprint session, so that my feature branch has readable history before creating a PR.

2. As a **developer on the default branch**, I want the agent to stop and create a feature branch automatically, so that I don't accidentally commit to main and bypass PR workflows.

3. As a **developer with a JIRA ticket**, I want to run `/afk-sprint --jira PROJ-123` to include the ticket number in my branch name, so that my branches are linked to our issue tracker.

4. As a **developer iterating on a feature**, I want to run multiple sprint sessions on the same feature branch, with each session producing one squashed commit, so that I can incrementally build features without cluttering history.

5. As a **developer using solve-issue**, I want the same feature branch safety and commit conventions, so that single-issue work follows the same clean patterns as sprint work.

## Decisions

### 1. Feature Branch Naming and Creation

**Default branch detection:**
- Before any work starts, check current branch against default branch (main, master, or from git config)
- If on default branch: create or switch to feature branch
- If already on feature branch: continue with existing branch

**Branch naming convention:**
- Default format: `feature/<first-issue-slug>`
- With JIRA ticket: `feature/<JIRA-123>-<first-issue-slug>`
- JIRA provided via optional CLI flag: `--jira PROJ-123`
- User can customize suggested name at creation time

**Branch reuse:**
- If suggested branch name already exists: automatically switch to it and continue
- Supports iterative development on same feature branch

**Applies to:**
- `skills/afk-sprint/SKILL.md` (both Claude and Copilot versions)
- `skills/solve-issue/SKILL.md`

**Files modified:**
```markdown
# In solve-issue SKILL.md - add before Step 1:

### 0. Feature Branch Setup

Parse optional `--jira` flag from invocation.

Check current branch:
```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  # On default branch - need to create feature branch
  # Extract first issue slug for branch name
  ISSUE_SLUG=$(basename "$ISSUE_PATH" | sed 's/^[0-9]*-//' | sed 's/\.md$//')
  
  if [ -n "$JIRA_TICKET" ]; then
    SUGGESTED_BRANCH="feature/$JIRA_TICKET-$ISSUE_SLUG"
  else
    SUGGESTED_BRANCH="feature/$ISSUE_SLUG"
  fi
  
  # Check if branch exists
  if git rev-parse --verify "$SUGGESTED_BRANCH" >/dev/null 2>&1; then
    git checkout "$SUGGESTED_BRANCH"
  else
    git checkout -b "$SUGGESTED_BRANCH"
  fi
fi
```
```

### 2. Commit Message Convention

**Individual issue commits:**
- Format: `[issue-slug] <commit message>`
- Example: `[01-auth-logout] Add user logout endpoint`
- Purpose: Enables parsing commits by issue for selective squashing

**Commit message body:**
- Use existing issue title as primary message
- Include key decisions/tradeoffs if any
- Add platform-appropriate Co-authored-by trailer

**Files modified:**
- `skills/solve-issue/SKILL.md` - Step 6 (Commit)

**Change in Step 6:**
```markdown
Commit message format (when committing):
```
[<issue-slug>] <issue title>

- <key decision or tradeoff — omit if none>

Co-authored-by: <Platform> <email>
```

Where `<issue-slug>` is extracted from the issue filename (e.g., `01-auth-logout` from `01-auth-logout.md`).
```

### 3. Sprint State Tracking

**State file location:**
- Path: `.scratch/<feature-slug>/sprint-state.json`
- Feature-slug derived from branch name (strip `feature/` prefix and JIRA ticket)
- Example: `feature/PROJ-123-auth-logout` → `.scratch/auth-logout/sprint-state.json`

**State file structure:**
```json
{
  "branches": {
    "feature/PROJ-123-auth-logout": {
      "base_sha": "abc123def456...",
      "created_at": "2026-06-13T12:00:00Z"
    },
    "feature/user-profile": {
      "base_sha": "789ghi012jkl...",
      "created_at": "2026-06-13T14:30:00Z"
    }
  }
}
```

**State lifecycle:**
1. **At sprint start**: Record current HEAD SHA as base_sha for current branch
2. **After successful squash**: Update base_sha to new HEAD (the squashed commit SHA)
3. **On subsequent sprints**: Read base_sha to know where current sprint started

**Directory creation:**
- Auto-create `.scratch/<feature-slug>/` with `issues/` subdirectory if doesn't exist
- If issues span multiple `.scratch/` directories, use first issue's parent directory

**Files modified:**
- `skills/afk-sprint/SKILL.md` - add state management in Session Init and after squash
- `skills/afk-sprint/copilot.SKILL.md` - same changes

### 4. Auto-Squashing Logic

**When squashing happens:**
- After all issues in sprint complete successfully
- Before final summary output
- Only applies to completed issues (skip blocked/partial)

**How to identify commits to squash:**
- Parse commit messages looking for `[issue-slug]` prefix
- Track which issues were marked complete in current sprint
- Squash only commits matching completed issue slugs
- Start squashing from base_sha (recorded at sprint start)

**Squash command:**
```bash
# Get base SHA from state file
BASE_SHA=$(jq -r ".branches[\"$CURRENT_BRANCH\"].base_sha" "$STATE_FILE")

# Interactive rebase with autosquash
git rebase -i --autosquash "$BASE_SHA"
```

**Failure handling:**
- If squash fails: report error, leave commits intact, provide manual fix command
- Error message: `"Failed to squash commits. Manual rebase needed: git rebase -i $BASE_SHA"`
- Exit without updating state file

**Opt-out flag:**
- Add `--no-squash` flag to preserve individual commits
- Useful for debugging or when granular history needed

**Files modified:**
- `skills/afk-sprint/SKILL.md` - add Step 4.5 (Squash) between current Step 4 (Merge housekeeping) and Exit
- `skills/afk-sprint/copilot.SKILL.md` - same addition

**New Step 4.5 in afk-sprint:**
```markdown
### Step 4.5 — Squash Commits

Parse `--no-squash` flag. If present, skip this step.

Read sprint state file to get base SHA:
```bash
FEATURE_SLUG=$(git rev-parse --abbrev-ref HEAD | sed 's/^feature\///' | sed 's/^[A-Z]*-[0-9]*-//')
STATE_FILE="$MAIN_ROOT/.scratch/$FEATURE_SLUG/sprint-state.json"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if [ -f "$STATE_FILE" ]; then
  BASE_SHA=$(jq -r ".branches[\"$CURRENT_BRANCH\"].base_sha // empty" "$STATE_FILE")
fi

if [ -z "$BASE_SHA" ]; then
  echo "Warning: No base SHA found in state file. Skipping squash."
  # Continue to exit
fi
```

Collect completed issue slugs from this sprint session (tracked in memory from Step 2-3).

Generate squashed commit message (see Decision 5).

Perform squash:
```bash
# Create squash commit
FIRST_COMMIT=$(git rev-list "$BASE_SHA..HEAD" | tail -1)
git reset --soft "$BASE_SHA"
git commit -m "$SQUASH_MESSAGE"
```

Update state file with new HEAD:
```bash
NEW_HEAD=$(git rev-parse HEAD)
jq ".branches[\"$CURRENT_BRANCH\"].base_sha = \"$NEW_HEAD\"" "$STATE_FILE" > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"
```

If squash fails, report error and exit without updating state.
```

### 5. Squashed Commit Message Format

**Message structure:**
```
Implement N features

- <First issue title>
- <Second issue title>
- <Third issue title>

Co-authored-by: <Platform> <email>
```

**Summary line generation:**
- Simple count: "Implement N features" or "Complete N issues"
- No category inference, no AI required

**Git-message skill integration (optional):**
- Check if `git-message` skill exists in `.copilot/skills/` or `.claude/skills/`
- If exists: delegate full message generation to skill (pass issue titles as input)
- If not exists: use default format above
- This is a future enhancement hook, not required for v1

**Files modified:**
- `skills/afk-sprint/SKILL.md` - message generation logic in Step 4.5

### 6. Platform Consistency

**Both Claude Code and Copilot CLI:**
- Identical behavior for feature branch creation, commit conventions, and squashing
- No platform-specific workarounds needed (unlike original `--no-commit` PRD)
- Worktree isolation doesn't conflict since we're always committing

**Files modified:**
- `skills/afk-sprint/SKILL.md` (Claude version)
- `skills/afk-sprint/copilot.SKILL.md` (Copilot version)
- `skills/solve-issue/SKILL.md` (platform-agnostic)

### 7. address-pr-comments and address-code-review

**Changes:**
- Add default branch protection check only
- Stop if on main/master with error: "Cannot run on default branch. Switch to your PR branch first."
- Keep existing single-commit behavior (no squashing needed)
- No feature branch creation (assume already on PR branch)

**Files modified:**
- `skills/address-pr-comments/SKILL.md` - add branch check before Step 1
- `skills/address-code-review/SKILL.md` - add branch check before Step 1

**New Step 0 in both skills:**
```markdown
### 0. Branch Safety Check

Check current branch:
```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
  echo "ERROR: Cannot run on default branch ($DEFAULT_BRANCH)."
  echo "Switch to your PR branch first: git checkout <branch-name>"
  exit 1
fi
```
```

### 8. Removing Old --commit/--no-commit Flags

**Deprecated:**
- Remove all references to `--commit` and `--no-commit` flags
- Remove `docs/agents/sprint-config.md` (no longer needed)
- Remove config file reading logic from all skills

**Rationale:**
- New squashing approach makes staging-only mode obsolete
- Always commit during development, squash at end
- Simpler mental model with fewer configuration options

**Files modified:**
- `skills/solve-issue/SKILL.md` - remove lines 48-87 (commit behavior flags section)
- `skills/solve-issue/SKILL.md` - Step 6: remove conditional commit logic, always commit
- `skills/solve-issue/SKILL.md` - Step 7: always mark done after commit (remove conditionals)
- Remove `docs/agents/sprint-config.md` template from registry

**Registry changes:**
```json
// In registry.json, remove sprint-config.md from docs section
"docs": {
  "sprint-config.md": { ... }  // DELETE THIS ENTRY
}
```

### 9. Multi-Sprint Support (Relaxed Model)

**Behavior:**
- Each sprint session produces one squashed commit
- Multiple sprints on same branch = multiple commits (one per session)
- Each squash only touches commits since last sprint's squashed commit
- State file base_sha tracks "don't squash before this point"

**Example timeline:**
```
Sprint 1: 3 issues → commits A, B, C → squashed to S1
(base_sha updated to S1)

Sprint 2: 2 issues → commits D, E → squashed to S2
(base_sha updated to S2)

Final history: S1 → S2
```

**Implementation:**
- State tracking (Decision 3) ensures each sprint knows its starting point
- Squash logic (Decision 4) only operates on commits since base_sha

## Out of Scope

**Not included in this feature:**

1. **Push automation** — Skills never push to remote. User pushes manually after reviewing.

2. **PR creation** — User creates PR manually via `gh` or GitHub UI after pushing feature branch.

3. **Squashing across all sprints** — Each sprint keeps its squashed commit. No "re-squash everything" option.

4. **Git-message skill creation** — Integration hook exists, but skill itself is separate work.

5. **Interactive branch name editing** — Suggested name shown, but customization requires manual git commands (kept simple for v1).

6. **Partial commit selection** — All completed issues squashed together. No cherry-picking individual issues.

7. **Conflict resolution automation** — If squash fails due to conflicts, user resolves manually.

8. **Branch cleanup** — User deletes merged feature branches manually or via git hooks.

9. **Remote branch tracking** — All logic operates on local branches. Remote syncing is manual.

10. **Configuration file** — No `sprint-config.md` or other config files. All behavior controlled via flags or hardcoded defaults.
