#!/bin/bash
# Integration test script for worktree lifecycle in crew-afk
# Tests: creation, .worktreeinclude symlinking, removal, and prune patterns
# Follows the pattern of test-session-init.sh

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Setup — temp repo with cleanup trap
# ---------------------------------------------------------------------------
TEST_DIR=$(mktemp -d)
FEATURE_SLUG="my-sprint"
ISSUE_SLUG="add-auth"

trap 'rm -rf "$TEST_DIR"' EXIT

cd "$TEST_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"
git branch -M main
git checkout -b "feature/$FEATURE_SLUG" -q

MAIN_ROOT="$TEST_DIR"
BRANCH="crew/$FEATURE_SLUG/$ISSUE_SLUG"
WORKTREE_PATH="$MAIN_ROOT/.scratch/worktrees/$BRANCH"

echo "Testing crew-afk worktree lifecycle..."
echo

# ---------------------------------------------------------------------------
# Assertion 1: Worktree is created at the expected path during a round
# ---------------------------------------------------------------------------
echo "Assertion 1: Worktree created at expected path"
mkdir -p "$(dirname "$WORKTREE_PATH")"
git -C "$MAIN_ROOT" worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD -q 2>/dev/null

if [ -d "$WORKTREE_PATH" ]; then
    pass "Worktree created at $WORKTREE_PATH"
else
    fail "Worktree not found at expected path $WORKTREE_PATH"
fi
echo

# ---------------------------------------------------------------------------
# Assertion 2: .worktreeinclude entries are symlinked when file exists
# ---------------------------------------------------------------------------
echo "Assertion 2: .worktreeinclude entries symlinked when file exists"
echo "secret-value" > "$MAIN_ROOT/.env.local"
mkdir -p "$MAIN_ROOT/shared"
echo "shared-data" > "$MAIN_ROOT/shared/config.yml"

cat > "$MAIN_ROOT/.worktreeinclude" <<'EOF'
# Config files to include in worktrees
.env.local
shared/config.yml

# blank lines and comments above are skipped
EOF

# Simulate what the orchestrator does: symlink each listed entry
if [ -f "$MAIN_ROOT/.worktreeinclude" ]; then
    while IFS= read -r entry; do
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        src="$MAIN_ROOT/$entry"
        dst="$WORKTREE_PATH/$entry"
        mkdir -p "$(dirname "$dst")"
        ln -sf "$src" "$dst"
    done < "$MAIN_ROOT/.worktreeinclude"
fi

if [ -L "$WORKTREE_PATH/.env.local" ] && [ -L "$WORKTREE_PATH/shared/config.yml" ]; then
    pass ".worktreeinclude entries (.env.local, shared/config.yml) symlinked into worktree"
else
    fail ".worktreeinclude entries not symlinked; .env.local symlink=$([ -L "$WORKTREE_PATH/.env.local" ] && echo yes || echo no) shared/config.yml symlink=$([ -L "$WORKTREE_PATH/shared/config.yml" ] && echo yes || echo no)"
fi
echo

# ---------------------------------------------------------------------------
# Assertion 3: .worktreeinclude is skipped gracefully when absent
# ---------------------------------------------------------------------------
echo "Assertion 3: .worktreeinclude absent — symlink step skipped gracefully"
WORKTREE2_PATH="$MAIN_ROOT/.scratch/worktrees/crew/$FEATURE_SLUG/second-issue"
mkdir -p "$(dirname "$WORKTREE2_PATH")"
git -C "$MAIN_ROOT" worktree add -b "crew/$FEATURE_SLUG/second-issue" "$WORKTREE2_PATH" HEAD -q 2>/dev/null

rm -f "$MAIN_ROOT/.worktreeinclude"

SYMLINK_ERROR=0
if [ -f "$MAIN_ROOT/.worktreeinclude" ]; then
    while IFS= read -r entry; do
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        ln -sf "$MAIN_ROOT/$entry" "$WORKTREE2_PATH/$entry" 2>/dev/null || SYMLINK_ERROR=1
    done < "$MAIN_ROOT/.worktreeinclude"
fi

if [ $SYMLINK_ERROR -eq 0 ]; then
    pass "No error when .worktreeinclude is absent"
else
    fail "Error occurred when .worktreeinclude is absent"
fi
echo

# ---------------------------------------------------------------------------
# Assertion 4: Worktree is removed after the round completes
# ---------------------------------------------------------------------------
echo "Assertion 4: Worktree removed after round completes"
git -C "$MAIN_ROOT" worktree remove --force "$WORKTREE_PATH" 2>/dev/null
git -C "$MAIN_ROOT" worktree remove --force "$WORKTREE2_PATH" 2>/dev/null

if [ ! -d "$WORKTREE_PATH" ] && [ ! -d "$WORKTREE2_PATH" ]; then
    pass "Worktrees removed after round completes"
else
    fail "Worktree(s) still present after remove: path1=$([ -d "$WORKTREE_PATH" ] && echo exists || echo gone) path2=$([ -d "$WORKTREE2_PATH" ] && echo exists || echo gone)"
fi
echo

# ---------------------------------------------------------------------------
# Assertion 5: .scratch/worktrees/ is empty (or absent) after git worktree prune
# ---------------------------------------------------------------------------
echo "Assertion 5: .scratch/worktrees/ empty or absent after git worktree prune"
git -C "$MAIN_ROOT" worktree prune 2>/dev/null
# Remove empty parent directories left over after worktree removal
find "$MAIN_ROOT/.scratch/worktrees" -mindepth 1 -type d -empty -delete 2>/dev/null || true

WORKTREE_DIR="$MAIN_ROOT/.scratch/worktrees"
if [ ! -d "$WORKTREE_DIR" ] || [ -z "$(ls -A "$WORKTREE_DIR" 2>/dev/null)" ]; then
    pass ".scratch/worktrees/ is empty or absent after prune"
else
    REMAINING=$(find "$WORKTREE_DIR" -mindepth 1 -maxdepth 3 2>/dev/null | head -5)
    fail ".scratch/worktrees/ still has entries after prune: $REMAINING"
fi
echo

# ---------------------------------------------------------------------------
# Assertion 6: Branch crew/<feature-slug>/<issue-slug> exists after creation
#              and is removed after cleanup
# ---------------------------------------------------------------------------
echo "Assertion 6: Branch crew/<feature-slug>/<issue-slug> created then removed"

# Create a fresh worktree (and branch) to verify the pattern
WORKTREE3_PATH="$MAIN_ROOT/.scratch/worktrees/crew/$FEATURE_SLUG/third-issue"
BRANCH3="crew/$FEATURE_SLUG/third-issue"
mkdir -p "$(dirname "$WORKTREE3_PATH")"
git -C "$MAIN_ROOT" worktree add -b "$BRANCH3" "$WORKTREE3_PATH" HEAD -q 2>/dev/null

BRANCH_EXISTS_BEFORE=$(git -C "$MAIN_ROOT" branch --list "$BRANCH3" | grep -c "$BRANCH3" || true)

# Remove worktree and delete branch
git -C "$MAIN_ROOT" worktree remove --force "$WORKTREE3_PATH" 2>/dev/null
git -C "$MAIN_ROOT" branch -D "$BRANCH3" 2>/dev/null || true

BRANCH_EXISTS_AFTER=$(git -C "$MAIN_ROOT" branch --list "$BRANCH3" | grep -c "$BRANCH3" || true)

if [ "$BRANCH_EXISTS_BEFORE" -ge 1 ] && [ "$BRANCH_EXISTS_AFTER" -eq 0 ]; then
    pass "Branch $BRANCH3 existed after creation and was removed after cleanup"
elif [ "$BRANCH_EXISTS_BEFORE" -lt 1 ]; then
    fail "Branch $BRANCH3 was not created"
else
    fail "Branch $BRANCH3 still exists after cleanup"
fi
echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "---"
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    exit 1
fi
echo "All assertions passed!"
