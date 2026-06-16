#!/bin/bash
# Test script for commit message format in solve-issue Step 6
# Tests issue slug extraction and commit message formatting

set -e

echo "Testing commit message format logic..."
echo

# Helper function to extract issue slug from filename
extract_issue_slug() {
    local issue_path="$1"
    basename "$issue_path" | sed 's/\.md$//'
}

# Test 1: Extract issue slug from filename with leading digits
echo "Test 1: Extract issue slug from filename with leading digits"
result=$(extract_issue_slug "/path/to/01-auth-logout.md")
expected="01-auth-logout"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Extracted '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 2: Extract issue slug from filename without leading digits
echo "Test 2: Extract issue slug from filename without leading digits"
result=$(extract_issue_slug "/path/to/add-user-profile.md")
expected="add-user-profile"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Extracted '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 3: Extract issue slug from filename with multiple digits
echo "Test 3: Extract issue slug from filename with multiple digits"
result=$(extract_issue_slug "/path/to/123-complex-feature-name.md")
expected="123-complex-feature-name"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Extracted '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 4: Build commit message with slug prefix
echo "Test 4: Build commit message with slug prefix"
ISSUE_SLUG="01-auth-logout"
ISSUE_TITLE="Add user logout endpoint"
COMMIT_MSG="[$ISSUE_SLUG] $ISSUE_TITLE"
expected="[01-auth-logout] Add user logout endpoint"
if [ "$COMMIT_MSG" = "$expected" ]; then
    echo "✓ PASS: Commit message is '$COMMIT_MSG'"
else
    echo "✗ FAIL: Expected '$expected', got '$COMMIT_MSG'"
    exit 1
fi
echo

# Test 5: Build commit message with body and trailer
echo "Test 5: Build commit message with body and trailer"
ISSUE_SLUG="02-user-profile"
ISSUE_TITLE="Implement user profile page"
COMMIT_BODY="- Used React hooks for state management"
CO_AUTHOR="Co-authored-by: Claude <claude@anthropic.com>"

FULL_MSG="[$ISSUE_SLUG] $ISSUE_TITLE

$COMMIT_BODY

$CO_AUTHOR"

if echo "$FULL_MSG" | grep -q "^\[02-user-profile\] Implement user profile page"; then
    echo "✓ PASS: Commit message has correct header"
else
    echo "✗ FAIL: Commit message header incorrect"
    exit 1
fi

if echo "$FULL_MSG" | grep -q "Co-authored-by: Claude"; then
    echo "✓ PASS: Commit message has Co-authored-by trailer"
else
    echo "✗ FAIL: Commit message missing Co-authored-by trailer"
    exit 1
fi
echo

# Test 6: Extract slug from real issue filename
echo "Test 6: Extract slug from real issue filename"
result=$(extract_issue_slug ".scratch/auto-squash-commits/issues/03-solve-issue-commit-format.md")
expected="03-solve-issue-commit-format"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Extracted '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

echo "All tests passed! ✓"
