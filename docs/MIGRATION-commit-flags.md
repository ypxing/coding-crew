# Migration Guide: Deprecated --commit/--no-commit Flags

## Summary

The `--commit` and `--no-commit` flags have been removed from all agent skills as part of the auto-squash commits feature implementation. All skills now always commit changes automatically.

## Affected Skills

- `solve-issue`
- `afk-sprint` (both Claude and Copilot versions)
- `address-pr-comments`
- `address-code-review`

## What Changed

**Before:**
```bash
/solve-issue path/to/issue.md --no-commit  # Stage only, don't commit
/solve-issue path/to/issue.md --commit     # Commit (was default)
/afk-sprint --no-commit                     # Process all issues, stage only
```

**After:**
```bash
/solve-issue path/to/issue.md              # Always commits
/afk-sprint                                 # Always commits, then auto-squashes
/afk-sprint --no-squash                     # Commits individually, skips squash
```

## Migration Path

### If you were using `--no-commit` for manual review:

**Option 1 - Review commits before pushing:**
```bash
# Run the agent (commits automatically)
/afk-sprint

# Review commits locally
git log -p

# If satisfied, push
git push
```

**Option 2 - Use feature branches (recommended):**
The auto-squash feature now automatically creates feature branches and squashes all commits. This provides clean history before creating PRs:

```bash
# Agent creates feature/your-feature branch automatically
/afk-sprint

# All commits squashed into one clean commit
# Review and push when ready
git push origin feature/your-feature
```

### If you were using `--commit` (default behavior):

No changes needed. This was always the default and remains the behavior.

### Config File Removal

If you have `docs/agents/sprint-config.md` in your project from a previous installation, it is no longer used and can be safely deleted:

```bash
rm docs/agents/sprint-config.md
```

## New Features

The new auto-squash workflow provides:

1. **Automatic feature branch creation** - No more accidental commits to main
2. **JIRA ticket integration** - Use `--jira PROJ-123` to include ticket numbers in branch names
3. **Automatic commit squashing** - Clean, single-commit history per sprint session
4. **Safety validations** - Checks for dependencies (jq), valid git state, and branch ancestry

## Troubleshooting

### "Warning: --commit/--no-commit flags are no longer supported"

These flags are silently ignored. Remove them from your commands.

### "ERROR: jq is required but not installed"

Install jq for state tracking:
```bash
# Debian/Ubuntu
sudo apt-get install jq

# macOS
brew install jq
```

### "ERROR: Cannot run on default branch"

The new safety checks prevent accidental commits to main. Either:
- Let the agent create a feature branch automatically
- Manually switch to a feature branch first: `git checkout -b feature/my-feature`

## Questions?

See the updated skill documentation:
- `skills/solve-issue/SKILL.md`
- `skills/afk-sprint/SKILL.md`
- `skills/afk-sprint/copilot.SKILL.md`
