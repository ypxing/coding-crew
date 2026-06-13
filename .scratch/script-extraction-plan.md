# Script Extraction Plan

This document outlines the plan to extract inline scripts from skills and use shared reusable scripts.

## Current State

### Duplication Issues

1. **Branch safety check** - Duplicated verbatim in:
   - `address-pr-comments/SKILL.md` (lines 26-45)
   - `address-code-review/SKILL.md` (lines 23-37)

2. **Feature branch setup** - Similar logic in:
   - `solve-issue/SKILL.md` (lines 50-86)
   - `afk-sprint/scripts/session-init.sh` (already extracted, lines 40-84)

3. **Commit operations** - Similar patterns in:
   - `solve-issue/SKILL.md` (lines 144-172)
   - `address-pr-comments/SKILL.md` (lines 116-134)
   - `address-code-review/SKILL.md` (lines 102-122)

## Shared Scripts Created

Location: `skills/_shared/scripts/`

1. **`branch-safety-check.sh`** (926 bytes)
   - Checks if on default branch
   - Supports `--allow-default` flag
   - Exit 1 if on default branch (unless allowed)

2. **`feature-branch-setup.sh`** (2.3 KB)
   - Creates/switches feature branch from issue slug
   - Supports `--jira TICKET-123` flag
   - Validates JIRA format: `[A-Z]+-[0-9]+`
   - No-op if already on non-default branch

3. **`commit-changes.sh`** (1.7 KB)
   - Stages specific files (never `git add -A`)
   - Standardized commit format
   - Supports `--prefix`, `--coauthor` flags

## Integration Steps

### 1. Update `solve-issue/SKILL.md`

**Step 0 - Feature Branch Setup (lines 50-86)**

Replace:
```bash
CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git -C "$PROJECT_ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
# ... 30+ lines of branch logic ...
```

With:
```bash
bash skills/_shared/scripts/feature-branch-setup.sh "$ISSUE_PATH"
```

**Step 6 - Commit (lines 144-172)**

Replace:
```bash
git add <file1> <file2> ...
# ... commit message formatting ...
git commit -m "..."
```

With:
```bash
ISSUE_SLUG=$(basename "$ISSUE_PATH" | sed 's/\.md$//')
bash skills/_shared/scripts/commit-changes.sh \
  --prefix "[$ISSUE_SLUG]" \
  --message "<issue title>" \
  --files "<space-separated file list>" \
  --coauthor "<trailer if provided>"
```

**Estimated reduction**: ~50 lines → ~5 lines (90% reduction)

---

### 2. Update `address-pr-comments/SKILL.md`

**Step 0 - Branch Safety Check (lines 26-45)**

Replace:
```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
# ... 15+ lines of validation ...
```

With:
```bash
bash skills/_shared/scripts/branch-safety-check.sh
```

**Step 5 - Commit (lines 116-134)**

Replace:
```bash
git add <file1> <file2> ...
# ... commit message formatting ...
```

With:
```bash
bash skills/_shared/scripts/commit-changes.sh \
  --message "address PR review comments

<bullet list>" \
  --files "<file list>" \
  --coauthor "Claude <noreply@anthropic.com>"
```

**Estimated reduction**: ~30 lines → ~7 lines (77% reduction)

---

### 3. Update `address-code-review/SKILL.md`

**Step 0 - Branch Safety Check (lines 23-37)**

Replace:
```bash
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
# ... same as address-pr-comments ...
```

With:
```bash
bash skills/_shared/scripts/branch-safety-check.sh
```

**Step 5 - Commit (lines 102-122)**

Replace:
```bash
git add <file1> <file2> …
git commit -m "$(cat <<'EOF'
...
EOF
)"
```

With:
```bash
bash skills/_shared/scripts/commit-changes.sh \
  --message "address code review findings

<bullet list>" \
  --files "<file list>" \
  --coauthor "Claude <noreply@anthropic.com>"
```

**Estimated reduction**: ~30 lines → ~7 lines (77% reduction)

---

## Installation Integration

Update `install.sh` to copy shared scripts to target repo:

```bash
# After copying skill files
if [ -d "$SOURCE_REPO/skills/_shared" ]; then
  echo "Installing shared scripts..."
  mkdir -p "$TARGET_REPO/skills/_shared"
  cp -r "$SOURCE_REPO/skills/_shared/." "$TARGET_REPO/skills/_shared/"
  chmod +x "$TARGET_REPO/skills/_shared/scripts/"*.sh
fi
```

---

## Summary of Benefits

### Line Reduction
- **solve-issue**: ~50 lines → ~5 lines (90% reduction)
- **address-pr-comments**: ~30 lines → ~7 lines (77% reduction)
- **address-code-review**: ~30 lines → ~7 lines (77% reduction)
- **Total**: ~110 lines of inline script → ~19 lines of script calls

### Quality Improvements
1. **Single source of truth** for branch logic
2. **Consistent behavior** across all skills
3. **Easier testing** - scripts can be unit tested
4. **Better error handling** - centralized validation
5. **Maintainability** - fix bugs in one place
6. **Reusability** - new skills can use existing scripts

### Consistency Wins
- Same default branch detection everywhere
- Same JIRA ticket validation
- Same commit message format
- Same Co-authored-by trailer handling

---

## Next Steps

1. ✅ Create shared scripts directory and files
2. ✅ Document scripts in README
3. ⏭️ Update `solve-issue/SKILL.md` to use shared scripts
4. ⏭️ Update `address-pr-comments/SKILL.md` to use shared scripts
5. ⏭️ Update `address-code-review/SKILL.md` to use shared scripts
6. ⏭️ Update `install.sh` to copy `_shared/` directory
7. ⏭️ Update `registry.json` to document shared scripts
8. ⏭️ Test all skills with new scripts
9. ⏭️ Commit all changes

---

## Testing Checklist

Before committing:
- [ ] Test `branch-safety-check.sh` on default and non-default branches
- [ ] Test `feature-branch-setup.sh` with and without `--jira` flag
- [ ] Test `commit-changes.sh` with various argument combinations
- [ ] Verify `solve-issue` works end-to-end with new scripts
- [ ] Verify `address-pr-comments` works with new scripts
- [ ] Verify `address-code-review` works with new scripts
- [ ] Confirm `install.sh` copies `_shared/` correctly
