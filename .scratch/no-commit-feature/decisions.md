# Feature: Optional Commit Mode for solve-issue and afk-sprint

## Summary of All Decisions

### 1. Use Case
Interactive development - review changes before committing. Users want to run afk-sprint, review all implemented changes, then commit manually.

### 2. Implementation Approach
Add `committed: true|false` flag to coder agent's structured output. Status `complete` means work done and verified; `committed` flag indicates whether git commit happened.

### 3. Platform Support
**GitHub Copilot only** - Claude Code always commits due to worktree isolation requirements.
- Copilot: Supports `--commit` / `--no-commit` flags
- Claude: Always commits (changes must be visible to subsequent issues in parallel worktrees)

### 4. TDD Workflow
No intermediate commits during implementation. Current behavior already works this way:
- Steps 1-5: Work in working directory, no commits
- Step 6: Stage changes, conditionally commit based on flag

### 5. Configuration System

**New file**: `docs/agents/sprint-config.md`
- Installed for both platforms
- Includes note that Claude ignores this setting
- Default value: `auto_commit: yes` (backward compatible)

**Format**:
```markdown
# Sprint Configuration

## Commit behavior
auto_commit: yes

Note: Claude Code always commits due to worktree isolation. 
This setting only affects GitHub Copilot CLI.
```

**Precedence** (highest to lowest):
1. CLI flags (`--commit` or `--no-commit`)
2. Config file value (`auto_commit: yes/no`)
3. Default: `yes`

**Flags supported**:
- `/afk-sprint --commit` - force commit
- `/afk-sprint --no-commit` - skip commit
- `/solve-issue --commit path/to/issue.md`
- `/solve-issue --no-commit path/to/issue.md`

### 6. Step 6 Behavior (solve-issue commit step)

**Always**:
- Stage modified files (`git add <file1> <file2> ...`)
- Never `git add .` or `git add -A`

**Conditionally**:
- If `--commit` flag OR config says `yes`: proceed with `git commit`
- If `--no-commit` flag OR config says `no`: stop after staging

**Failure handling**:
- Don't stage if any check fails (same as current behavior)
- Report `status: "partial"` or `"blocked"`

### 7. Step 7 Behavior (mark done)

**When --no-commit**:
- Skip Step 7 entirely
- Issue stays at current status (`ready-for-agent`)
- Issue file stays in place (not moved to `done/`)

**Marking done after manual commit**:
- For direct invocation: re-run `/solve-issue path/to/issue.md` (no flag)
  - Detects work already committed (no staged/unstaged changes)
  - Verifies checks still pass
  - Marks issue done
- For afk-sprint workflow: automatic on next run (see Decision 9)

### 8. afk-sprint --no-commit Behavior

**Implementation phase** (first run):
- Parse `--no-commit` flag and config file
- Pass commit preference to each coder agent
- Spawns coder agents in parallel (current behavior)
- Each coder stages changes but doesn't commit

**After all coders complete**:
- **Skip merge step entirely** (no `git merge --no-ff`)
- Keep all worktrees intact for review
- Don't mark any issues done
- Don't clean up branches/worktrees

**Output summary**:
```
Sprint complete: 5 issues implemented, awaiting review

Worktrees with staged changes:
  - issue/01-auth-logout: /path/to/worktree-1 (3 files)
  - issue/02-user-profile: /path/to/worktree-2 (5 files)
  - issue/03-password-reset: /path/to/worktree-3 (8 files)
  - issue/04-email-verify: /path/to/worktree-4 (2 files)
  - issue/05-user-settings: /path/to/worktree-5 (4 files)

Next steps:
1. Review: cd <worktree-path> && git diff --staged
2. Commit approved changes: cd <worktree-path> && git commit -m "message"
3. Merge and close: /afk-sprint (to merge committed branches and mark issues done)
```

### 9. afk-sprint Second Run (merge phase)

**When running `/afk-sprint` after manual commits**:

1. **Detect committed branches**:
   - Check each tracked worktree
   - Identify which have new commits (compare with main)

2. **Merge committed branches only**:
   - Run `git merge --no-ff <branch>` for committed branches
   - Track merge success/failure (current behavior)

3. **Mark issues done**:
   - Only for successfully merged branches
   - Use `docs/agents/issue-tracker.md` convention

4. **Leave uncommitted worktrees**:
   - Don't delete/discard uncommitted worktrees
   - Issues stay `ready-for-agent`
   - User can re-run solve-issue, discard manually, or commit later

### 10. Claude Platform Handling

**Behavior**:
- Always commits regardless of flags or config
- Worktree isolation requires commits for dependency visibility

**Error handling**:
- If user uses `--no-commit` flag: print warning and continue
- Warning message: `"Warning: --no-commit is not supported on Claude Code (worktree isolation requires commits). Proceeding with auto-commit."`
- Non-blocking, user-friendly

**Config file**:
- Still installed for Claude
- Includes note: "Claude Code always commits due to worktree isolation. This setting only affects GitHub Copilot CLI."
- Claude code ignores `auto_commit` value

### 11. Output Format

**Individual coder agents**:
- Minimal status reporting (current structured output)
- Add `committed` field to output

**afk-sprint orchestrator**:
- During execution: brief progress logs
- At completion: comprehensive summary
  - List all worktrees with paths
  - File counts per worktree
  - Clear next steps for review/commit/merge

**Example individual coder output**:
```json
{
  "status": "complete",
  "committed": false,
  "branch": "issue/01-auth-logout",
  "working_directory": "/path/to/worktree",
  "checks": [
    {"command": "npm test", "result": "pass"},
    {"command": "npm run lint", "result": "pass"}
  ],
  "acceptance_criteria": "- [x] criterion 1\n- [x] criterion 2",
  "changes": ["src/auth.ts", "src/auth.test.ts"],
  "notes": "none"
}
```

### 12. Partial Manual Commits

**Scenario**: User commits only some worktrees after `--no-commit` sprint.

**Behavior**:
- Non-destructive approach
- Merge only committed branches
- Mark only successfully merged issues as done
- Leave uncommitted worktrees in place
- User retains full control over rejected changes

**No prompts or blocking** - fully automated partial merge.

---

## Files to Create/Modify

1. **New**: `docs/agents/sprint-config.md` - Configuration template
2. **Modify**: `skills/solve-issue/SKILL.md` - Add flag parsing, conditional Step 6/7
3. **Modify**: `skills/afk-sprint/SKILL.md` - Add flag parsing, conditional merge logic (Copilot only)
4. **Modify**: `skills/afk-sprint/copilot.SKILL.md` - Add flag parsing, conditional merge logic
5. **Modify**: `agents/coder/copilot.agent.md` - Add `committed` field to report format
6. **Modify**: `registry.json` - Add `sprint-config.md` to docs section

## Implementation Notes

- Claude version remains unchanged (always commits)
- Copilot version gets all new functionality
- Backward compatible: default behavior unchanged
- Config file optional: works without it (uses default)
- No breaking changes to existing workflows
