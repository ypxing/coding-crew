#!/bin/bash
# Test script for blocked dependency path check in solve-issue Step 1
# Tests that dependency check uses /../done/ path (issues/open/ layout)

set -e

PASS=0
FAIL=0

pass() { echo "✓ PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "✗ FAIL: $1"; FAIL=$((FAIL+1)); }

echo "Testing blocked dependency path logic..."
echo

# Helper: resolve dependency done path from issue path (the logic in SKILL.md)
resolve_dep_done_path_old() {
  local issue_path="$1"
  local dep_filename="$2"
  echo "$(dirname "$issue_path")/done/$dep_filename"
}

resolve_dep_done_path_new() {
  local issue_path="$1"
  local dep_filename="$2"
  echo "$(dirname "$issue_path")/../done/$dep_filename"
}

# Test 1: Old path (issues/<NN>-slug.md flat layout) — for reference only
echo "Test 1: Old flat layout path resolves correctly"
issue_path="/repo/.scratch/feature/issues/03-my-issue.md"
dep="01-dep-issue.md"
result=$(resolve_dep_done_path_old "$issue_path" "$dep")
expected="/repo/.scratch/feature/issues/done/01-dep-issue.md"
if [ "$result" = "$expected" ]; then
  pass "Old path: '$result'"
else
  fail "Old path: expected '$expected', got '$result'"
fi
echo

# Test 2: New path (issues/open/<NN>-slug.md layout) — the fixed check
echo "Test 2: New open/ layout path contains /../done/ segment"
issue_path="/repo/.scratch/feature/issues/open/03-my-issue.md"
dep="01-dep-issue.md"
result=$(resolve_dep_done_path_new "$issue_path" "$dep")
# The path must contain /../done/ so it navigates from open/ to the sibling done/
if [[ "$result" == *"/../done/"* ]]; then
  pass "New path contains /../done/ segment: '$result'"
else
  fail "New path: expected /../done/ segment, got '$result'"
fi
echo

# Test 3: Old logic fails for new layout (cross-check that old is wrong)
echo "Test 3: Old logic gives wrong path for open/ layout"
issue_path="/repo/.scratch/feature/issues/open/03-my-issue.md"
dep="01-dep-issue.md"
result=$(resolve_dep_done_path_old "$issue_path" "$dep")
wrong_expected="/repo/.scratch/feature/issues/open/done/01-dep-issue.md"
if [ "$result" = "$wrong_expected" ]; then
  pass "Old logic gives wrong nested path (confirmed bug): '$result'"
else
  fail "Unexpected: '$result'"
fi
echo

# Test 4: Actual filesystem check — dep in done/ is found with new path
echo "Test 4: ls check works with new path when dep is in done/"
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/issues/open"
mkdir -p "$TEST_DIR/issues/done"
echo "Status: done" > "$TEST_DIR/issues/done/01-dep.md"

ISSUE_PATH="$TEST_DIR/issues/open/02-current.md"
DEP_FILE="01-dep.md"
DONE_PATH="$(dirname "$ISSUE_PATH")/../done/$DEP_FILE"

if ls "$DONE_PATH" 2>/dev/null; then
  pass "Dep found at new path: '$DONE_PATH'"
else
  fail "Dep NOT found at new path: '$DONE_PATH'"
fi
echo

# Test 5: ls check fails with old path when dep is in done/
echo "Test 5: ls check fails with old path for open/ layout"
OLD_DONE_PATH="$(dirname "$ISSUE_PATH")/done/$DEP_FILE"
if ls "$OLD_DONE_PATH" 2>/dev/null; then
  fail "Old path incorrectly found dep (unexpected): '$OLD_DONE_PATH'"
else
  pass "Old path correctly fails to find dep (wrong dir): '$OLD_DONE_PATH'"
fi
echo

# Test 6: mark-done must NOT use hardcoded mv to done/ but delegate to tracker
echo "Test 6: SKILL.md mark-done section does NOT hardcode mv to done/"
SKILL_FILE="$(dirname "$0")/../SKILL.md"
if grep -q 'mkdir -p "$(dirname <issue-path>)/done"' "$SKILL_FILE"; then
  fail "SKILL.md still has hardcoded mkdir/mv to done/ in mark-done (not delegated to tracker)"
else
  pass "SKILL.md does not hardcode mkdir/mv to done/ in mark-done"
fi
echo

# Test 7: SKILL.md blocked-by check uses /../done/ path
echo "Test 7: SKILL.md blocked-by check uses /../done/ path"
if grep -q '"$(dirname "\$ISSUE_PATH")/../done/<dep-filename>"' "$SKILL_FILE"; then
  pass "SKILL.md uses correct /../done/ path in blocked-by check"
else
  fail "SKILL.md does NOT use /../done/ path in blocked-by check"
fi
echo

# Test 8: SKILL.md mark-done delegates to tracker operation
echo "Test 8: SKILL.md mark-done section references tracker mark-done operation"
if grep -q "mark-done.*operation\|tracker.*mark-done\|Execute.*mark-done\|invoke.*mark-done" "$SKILL_FILE"; then
  pass "SKILL.md mark-done references tracker operation"
else
  fail "SKILL.md mark-done does not reference tracker operation"
fi
echo

# Cleanup
rm -rf "$TEST_DIR"

echo "---"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "All tests passed! ✓"
