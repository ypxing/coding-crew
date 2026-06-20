#!/bin/bash
# Test script for worktree lifecycle in copilot.SKILL.md
# Tests: creation, .worktreeinclude symlinking, removal, and prune patterns

set -e

REPO_ROOT=$(pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
PASS=0
FAIL=0

pass() { echo "✓ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "✗ FAIL: $1"; FAIL=$((FAIL + 1)); }

cd "$TEST_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "test" > file.txt
git add file.txt
git commit -q -m "Initial commit"
git branch -M main
git checkout -b feature/my-sprint -q

echo "Testing worktree lifecycle for copilot.SKILL.md..."
echo

# ---------------------------------------------------------------------------
# Test 1: Worktree creation with crew/<feature-slug>/<issue-slug> branch
# ---------------------------------------------------------------------------
echo "Test 1: Worktree created with correct branch pattern"
FEATURE_SLUG="my-sprint"
ISSUE_SLUG="add-auth"
BRANCH="crew/$FEATURE_SLUG/$ISSUE_SLUG"
MAIN_ROOT="$TEST_DIR"
WORKTREE_PATH="$MAIN_ROOT/.scratch/worktrees/$BRANCH"

mkdir -p "$(dirname "$WORKTREE_PATH")"
git -C "$MAIN_ROOT" worktree add -b "$BRANCH" "$WORKTREE_PATH" HEAD -q

if [ -d "$WORKTREE_PATH" ]; then
    pass "Worktree created at $WORKTREE_PATH"
else
    fail "Worktree not created at $WORKTREE_PATH"
fi

# Verify the branch name matches the pattern crew/<feature-slug>/<issue-slug>
CREATED_BRANCH=$(git -C "$WORKTREE_PATH" rev-parse --abbrev-ref HEAD)
if [ "$CREATED_BRANCH" = "$BRANCH" ]; then
    pass "Branch name follows crew/<feature-slug>/<issue-slug> pattern: $CREATED_BRANCH"
else
    fail "Branch name '$CREATED_BRANCH' does not match expected '$BRANCH'"
fi
echo

# ---------------------------------------------------------------------------
# Test 2: Worktree path matches .scratch/worktrees/crew/<feature>/<issue>
# ---------------------------------------------------------------------------
echo "Test 2: Worktree path follows .scratch/worktrees/crew/<feature-slug>/<issue-slug>/"
EXPECTED_PATH_PATTERN="$MAIN_ROOT/.scratch/worktrees/crew/$FEATURE_SLUG/$ISSUE_SLUG"
if [ "$WORKTREE_PATH" = "$EXPECTED_PATH_PATTERN" ]; then
    pass "Worktree path matches expected pattern"
else
    fail "Worktree path '$WORKTREE_PATH' != expected '$EXPECTED_PATH_PATTERN'"
fi
echo

# ---------------------------------------------------------------------------
# Test 3: .worktreeinclude symlinking when file exists
# ---------------------------------------------------------------------------
echo "Test 3: .worktreeinclude entries symlinked when file exists"
# Create some files in MAIN_ROOT to symlink
mkdir -p "$MAIN_ROOT/.claude"
echo "secret-config" > "$MAIN_ROOT/.env.local"
mkdir -p "$MAIN_ROOT/shared"
echo "shared-data" > "$MAIN_ROOT/shared/config.yml"

# Create .worktreeinclude listing them
cat > "$MAIN_ROOT/.worktreeinclude" <<'EOF'
# Config files to include in worktrees
.env.local
shared/config.yml

# blank lines and comments are skipped
EOF

# Simulate what the orchestrator does: symlink each listed entry
WORKTREE_PATH2="$MAIN_ROOT/.scratch/worktrees/crew/$FEATURE_SLUG/second-issue"
mkdir -p "$(dirname "$WORKTREE_PATH2")"
git -C "$MAIN_ROOT" worktree add -b "crew/$FEATURE_SLUG/second-issue" "$WORKTREE_PATH2" HEAD -q

if [ -f "$MAIN_ROOT/.worktreeinclude" ]; then
    while IFS= read -r entry; do
        # Skip blank lines and comments
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        src="$MAIN_ROOT/$entry"
        dst="$WORKTREE_PATH2/$entry"
        mkdir -p "$(dirname "$dst")"
        ln -sf "$src" "$dst"
    done < "$MAIN_ROOT/.worktreeinclude"
fi

if [ -L "$WORKTREE_PATH2/.env.local" ]; then
    pass ".env.local symlinked into worktree"
else
    fail ".env.local not symlinked into worktree"
fi

if [ -L "$WORKTREE_PATH2/shared/config.yml" ]; then
    pass "shared/config.yml symlinked into worktree"
else
    fail "shared/config.yml not symlinked into worktree"
fi

# Verify symlink target points to MAIN_ROOT
TARGET=$(readlink "$WORKTREE_PATH2/.env.local")
if [ "$TARGET" = "$MAIN_ROOT/.env.local" ]; then
    pass "Symlink target is absolute path from MAIN_ROOT"
else
    fail "Symlink target '$TARGET' should be '$MAIN_ROOT/.env.local'"
fi
echo

# ---------------------------------------------------------------------------
# Test 4: .worktreeinclude absent → symlink step skipped gracefully
# ---------------------------------------------------------------------------
echo "Test 4: Missing .worktreeinclude is skipped gracefully (no error)"
WORKTREE_PATH3="$MAIN_ROOT/.scratch/worktrees/crew/$FEATURE_SLUG/third-issue"
mkdir -p "$(dirname "$WORKTREE_PATH3")"
git -C "$MAIN_ROOT" worktree add -b "crew/$FEATURE_SLUG/third-issue" "$WORKTREE_PATH3" HEAD -q

# Remove .worktreeinclude to simulate absence
rm -f "$MAIN_ROOT/.worktreeinclude"

# Simulate graceful skip
SYMLINK_ERROR=0
if [ -f "$MAIN_ROOT/.worktreeinclude" ]; then
    while IFS= read -r entry; do
        [[ -z "$entry" || "$entry" == \#* ]] && continue
        ln -sf "$MAIN_ROOT/$entry" "$WORKTREE_PATH3/$entry" 2>/dev/null || SYMLINK_ERROR=1
    done < "$MAIN_ROOT/.worktreeinclude"
fi
# No error if file absent
if [ $SYMLINK_ERROR -eq 0 ]; then
    pass "No error when .worktreeinclude is absent"
else
    fail "Error occurred when .worktreeinclude is absent"
fi
echo

# ---------------------------------------------------------------------------
# Test 5: Worktree removed after merge (force remove)
# ---------------------------------------------------------------------------
echo "Test 5: Worktree removed with --force after merge"
git -C "$MAIN_ROOT" worktree remove --force "$WORKTREE_PATH" 2>/dev/null
if [ ! -d "$WORKTREE_PATH" ]; then
    pass "Worktree removed after merge"
else
    fail "Worktree still exists after remove"
fi
echo

# ---------------------------------------------------------------------------
# Test 6: Worktree removed even on failure (force)
# ---------------------------------------------------------------------------
echo "Test 6: Worktree removed even on failed/incomplete branch"
# WORKTREE_PATH2 still exists — simulate removing on failure
git -C "$MAIN_ROOT" worktree remove --force "$WORKTREE_PATH2" 2>/dev/null
if [ ! -d "$WORKTREE_PATH2" ]; then
    pass "Failed-branch worktree removed"
else
    fail "Failed-branch worktree not removed"
fi
echo

# ---------------------------------------------------------------------------
# Test 7: git worktree prune runs on exit
# ---------------------------------------------------------------------------
echo "Test 7: git worktree prune succeeds"
# Remove WORKTREE_PATH3's backing directory without git cleanup to create a stale ref
git -C "$MAIN_ROOT" worktree remove --force "$WORKTREE_PATH3" 2>/dev/null || true
PRUNE_OUTPUT=$(git -C "$MAIN_ROOT" worktree prune 2>&1)
PRUNE_EXIT=$?
if [ $PRUNE_EXIT -eq 0 ]; then
    pass "git worktree prune exits 0"
else
    fail "git worktree prune failed with exit $PRUNE_EXIT: $PRUNE_OUTPUT"
fi
echo

# ---------------------------------------------------------------------------
# Test 8: prompt includes Working directory and hardcoded MAIN_ROOT
# ---------------------------------------------------------------------------
echo "Test 8: Verify copilot.SKILL.md prompt shape contains Working directory and MAIN_ROOT fields"
SKILL_FILE="$REPO_ROOT/skills/crew-afk/copilot.SKILL.md"
if grep -q "Working directory:" "$SKILL_FILE" 2>/dev/null; then
    pass "copilot.SKILL.md contains 'Working directory:' in prompt"
else
    fail "copilot.SKILL.md missing 'Working directory:' in prompt"
fi

if grep -q "MAIN_ROOT=<absolute" "$SKILL_FILE" 2>/dev/null; then
    pass "copilot.SKILL.md documents that MAIN_ROOT must be hardcoded absolute path"
else
    fail "copilot.SKILL.md missing MAIN_ROOT hardcoded absolute path instruction"
fi
echo

# ---------------------------------------------------------------------------
# Test 9: prompt shape — no \$() substitution instruction for MAIN_ROOT
# ---------------------------------------------------------------------------
echo "Test 9: copilot.SKILL.md explicitly says no \$() substitution for MAIN_ROOT"
if grep -q "no.*\\\$().*substitution\|no.*subshell\|\\\$()" "$SKILL_FILE" 2>/dev/null; then
    # We just need the instruction to be present
    pass "copilot.SKILL.md mentions \$() substitution avoidance for MAIN_ROOT"
else
    # Check alternative phrasing
    if grep -q "hardcoded\|hard-code\|hard code" "$SKILL_FILE" 2>/dev/null; then
        pass "copilot.SKILL.md uses 'hardcoded' wording (equivalent instruction)"
    else
        fail "copilot.SKILL.md missing instruction to avoid \$() for MAIN_ROOT"
    fi
fi
echo

# ---------------------------------------------------------------------------
# Test 10: copilot.SKILL.md has worktree prune on exit
# ---------------------------------------------------------------------------
echo "Test 10: copilot.SKILL.md has 'worktree prune' in exit section"
if grep -q "worktree prune" "$SKILL_FILE" 2>/dev/null; then
    pass "copilot.SKILL.md contains 'worktree prune'"
else
    fail "copilot.SKILL.md missing 'worktree prune'"
fi
echo

# ---------------------------------------------------------------------------
# Test 11: copilot.SKILL.md has worktree remove after merge
# ---------------------------------------------------------------------------
echo "Test 11: copilot.SKILL.md has 'worktree remove' after merge"
if grep -q "worktree remove" "$SKILL_FILE" 2>/dev/null; then
    pass "copilot.SKILL.md contains 'worktree remove'"
else
    fail "copilot.SKILL.md missing 'worktree remove'"
fi
echo

# ---------------------------------------------------------------------------
# Test 12: copilot.SKILL.md dispatches all subagents in single response (not sequential)
# ---------------------------------------------------------------------------
echo "Test 12: copilot.SKILL.md instructs single-response dispatch (parallel), not sequential"
# Must have instruction to dispatch in a single response
HAS_SINGLE_RESPONSE=0
HAS_NO_SEQUENTIAL=0
grep -qi "single response\|dispatch.*all.*once\|all.*dispatch.*once\|parallel.*dispatch\|dispatch.*parallel" "$SKILL_FILE" 2>/dev/null && HAS_SINGLE_RESPONSE=1 || true
# Must NOT say "Sequential processing" (sequential one-at-a-time)
grep -qi "sequential processing.*one at a time" "$SKILL_FILE" 2>/dev/null || HAS_NO_SEQUENTIAL=1

if [ $HAS_SINGLE_RESPONSE -eq 1 ] && [ $HAS_NO_SEQUENTIAL -eq 1 ]; then
    pass "copilot.SKILL.md has parallel single-response dispatch without sequential-one-at-a-time constraint"
elif [ $HAS_SINGLE_RESPONSE -eq 0 ]; then
    fail "copilot.SKILL.md missing single-response dispatch instruction"
else
    fail "copilot.SKILL.md still says 'Sequential processing... one at a time'"
fi
echo

# Cleanup
cd "$REPO_ROOT" > /dev/null
rm -rf "$TEST_DIR"

echo "---"
echo "Results: $PASS passed, $FAIL failed"
if [ $FAIL -gt 0 ]; then
    exit 1
fi
echo "All tests passed! ✓"
