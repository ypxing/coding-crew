#!/bin/bash
# Test script for feature branch detection logic in solve-issue Step 0
# Tests branch detection, slug extraction, and JIRA flag parsing

set -e

# Setup test environment
TEST_DIR=$(mktemp -d)
cd "$TEST_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"

# Create main branch with initial commit
echo "test" > file.txt
git add file.txt
git commit -q -m "Initial commit"
git branch -M main

echo "Testing branch detection logic..."
echo

# Helper function to extract issue slug from filename
extract_issue_slug() {
    local issue_path="$1"
    basename "$issue_path" | sed 's/^[0-9]*-//' | sed 's/\.md$//'
}

# Helper function to detect default branch
detect_default_branch() {
    local default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    if [ -z "$default_branch" ]; then
        echo "main"
    else
        echo "$default_branch"
    fi
}

# Helper function to parse --jira flag
parse_jira_flag() {
    local args="$1"
    if [[ "$args" =~ --jira[[:space:]]+([A-Z]+-[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Helper function to build branch name
build_branch_name() {
    local issue_slug="$1"
    local jira_ticket="$2"
    if [ -n "$jira_ticket" ]; then
        echo "feature/$jira_ticket-$issue_slug"
    else
        echo "feature/$issue_slug"
    fi
}

# Test 1: Extract issue slug from filename
echo "Test 1: Extract issue slug from filename"
result=$(extract_issue_slug "/path/to/01-solve-issue-feature-branch-detection.md")
expected="solve-issue-feature-branch-detection"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Extracted '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 2: Detect default branch (fallback to main when no origin)
echo "Test 2: Detect default branch (fallback to main)"
result=$(detect_default_branch)
expected="main"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Default branch is '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 3: Parse --jira flag
echo "Test 3: Parse --jira flag"
result=$(parse_jira_flag ".scratch/test/issues/01-test.md --jira PROJ-123")
expected="PROJ-123"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Parsed JIRA ticket '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 4: Parse --jira flag with no JIRA
echo "Test 4: Parse --jira flag when not present"
result=$(parse_jira_flag ".scratch/test/issues/01-test.md")
expected=""
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: No JIRA ticket found"
else
    echo "✗ FAIL: Expected empty string, got '$result'"
    exit 1
fi
echo

# Test 5: Build branch name without JIRA
echo "Test 5: Build branch name without JIRA"
result=$(build_branch_name "solve-issue-feature-branch-detection" "")
expected="feature/solve-issue-feature-branch-detection"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Branch name is '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 6: Build branch name with JIRA
echo "Test 6: Build branch name with JIRA"
result=$(build_branch_name "solve-issue-feature-branch-detection" "PROJ-123")
expected="feature/PROJ-123-solve-issue-feature-branch-detection"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Branch name is '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 7: Branch creation when on default branch
echo "Test 7: Create new branch when on default branch"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(detect_default_branch)
if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
    NEW_BRANCH="feature/test-branch"
    git checkout -b "$NEW_BRANCH" 2>&1 > /dev/null
    RESULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$RESULT_BRANCH" = "$NEW_BRANCH" ]; then
        echo "✓ PASS: Created and switched to '$NEW_BRANCH'"
    else
        echo "✗ FAIL: Expected '$NEW_BRANCH', got '$RESULT_BRANCH'"
        exit 1
    fi
else
    echo "✗ FAIL: Should start on default branch"
    exit 1
fi
echo

# Test 8: Switch to existing branch
echo "Test 8: Switch to existing branch when it already exists"
git checkout main -q
EXISTING_BRANCH="feature/test-branch"
if git rev-parse --verify "$EXISTING_BRANCH" >/dev/null 2>&1; then
    git checkout "$EXISTING_BRANCH" -q
    RESULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$RESULT_BRANCH" = "$EXISTING_BRANCH" ]; then
        echo "✓ PASS: Switched to existing branch '$EXISTING_BRANCH'"
    else
        echo "✗ FAIL: Expected '$EXISTING_BRANCH', got '$RESULT_BRANCH'"
        exit 1
    fi
else
    echo "✗ FAIL: Test branch should exist from Test 7"
    exit 1
fi
echo

# Test 9: Continue when already on non-default branch
echo "Test 9: Continue when already on non-default branch"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(detect_default_branch)
if [ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]; then
    echo "✓ PASS: Already on non-default branch '$CURRENT_BRANCH', no action needed"
else
    echo "✗ FAIL: Should be on non-default branch"
    exit 1
fi
echo

# Cleanup
cd - > /dev/null
rm -rf "$TEST_DIR"

echo "All tests passed! ✓"

# Test 10: Invalid JIRA ticket format (Finding #1)
echo "Test 10: Reject invalid JIRA ticket formats"
invalid_jira="--jira INVALID"
result=$(parse_jira_flag "$invalid_jira")
if [ -z "$result" ]; then
    echo "  ✓ Invalid JIRA format rejected"
else
    echo "  ✗ Invalid JIRA format accepted: $result"
    exit 1
fi

invalid_jira2="--jira 123-ABC"
result2=$(parse_jira_flag "$invalid_jira2")
if [ -z "$result2" ]; then
    echo "  ✓ Invalid JIRA format (number-letters) rejected"
else
    echo "  ✗ Invalid JIRA format accepted: $result2"
    exit 1
fi

echo
