#!/bin/bash
# Test script for afk-run Session Init feature branch setup
# Tests branch detection, first issue slug extraction, JIRA flag parsing, and directory creation

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

echo "Testing afk-run Session Init feature branch setup..."
echo

# Helper function to detect default branch
detect_default_branch() {
    local default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    if [ -z "$default_branch" ]; then
        echo "main"
    else
        echo "$default_branch"
    fi
}

# Helper function to parse --jira flag from invocation
parse_jira_flag() {
    local invocation="$1"
    if [[ "$invocation" =~ --jira[[:space:]]+([A-Z]+-[0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# Helper function to extract first ready issue slug
# In real use, this reads from .scratch/*/issues/*.md files
# For testing, we simulate by passing the issue path
extract_first_issue_slug() {
    local issue_path="$1"
    basename "$issue_path" | sed 's/^[0-9]*-//' | sed 's/\.md$//'
}

# Helper function to build branch name from first issue
build_branch_name_from_first_issue() {
    local first_issue_path="$1"
    local jira_ticket="$2"
    local issue_slug=$(extract_first_issue_slug "$first_issue_path")
    
    if [ -n "$jira_ticket" ]; then
        echo "feature/$jira_ticket-$issue_slug"
    else
        echo "feature/$issue_slug"
    fi
}

# Helper function to derive feature-slug from branch name
derive_feature_slug() {
    local branch_name="$1"
    # Strip 'feature/' prefix
    local slug="${branch_name#feature/}"
    # Strip JIRA prefix pattern (e.g., PROJ-123-)
    slug=$(echo "$slug" | sed 's/^[A-Z]*-[0-9]*-//')
    echo "$slug"
}

# Helper function to create scratch directory structure
create_scratch_structure() {
    local feature_slug="$1"
    mkdir -p ".scratch/$feature_slug/issues"
}

# Test 1: Detect default branch (fallback to main when no origin)
echo "Test 1: Detect default branch (fallback to main)"
result=$(detect_default_branch)
expected="main"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Default branch is '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 2: Parse --jira flag from invocation
echo "Test 2: Parse --jira flag from invocation"
result=$(parse_jira_flag "/afk-run --jira PROJ-123")
expected="PROJ-123"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Parsed JIRA ticket '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 3: Parse invocation without --jira flag
echo "Test 3: Parse invocation without --jira flag"
result=$(parse_jira_flag "/afk-run")
expected=""
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: No JIRA ticket found"
else
    echo "✗ FAIL: Expected empty string, got '$result'"
    exit 1
fi
echo

# Test 4: Extract first issue slug from filename
echo "Test 4: Extract first issue slug from filename"
result=$(extract_first_issue_slug ".scratch/auth/issues/01-user-logout.md")
expected="user-logout"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Extracted slug '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 5: Build branch name without JIRA
echo "Test 5: Build branch name from first issue without JIRA"
result=$(build_branch_name_from_first_issue ".scratch/auth/issues/01-user-logout.md" "")
expected="feature/user-logout"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Branch name is '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 6: Build branch name with JIRA
echo "Test 6: Build branch name from first issue with JIRA"
result=$(build_branch_name_from_first_issue ".scratch/auth/issues/01-user-logout.md" "PROJ-123")
expected="feature/PROJ-123-user-logout"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Branch name is '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 7: Derive feature-slug from branch without JIRA
echo "Test 7: Derive feature-slug from branch without JIRA"
result=$(derive_feature_slug "feature/user-logout")
expected="user-logout"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Feature slug is '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 8: Derive feature-slug from branch with JIRA
echo "Test 8: Derive feature-slug from branch with JIRA"
result=$(derive_feature_slug "feature/PROJ-123-user-logout")
expected="user-logout"
if [ "$result" = "$expected" ]; then
    echo "✓ PASS: Feature slug is '$result'"
else
    echo "✗ FAIL: Expected '$expected', got '$result'"
    exit 1
fi
echo

# Test 9: Create scratch directory structure
echo "Test 9: Create .scratch/<feature-slug>/issues/ directory"
create_scratch_structure "user-logout"
if [ -d ".scratch/user-logout/issues" ]; then
    echo "✓ PASS: Directory .scratch/user-logout/issues created"
else
    echo "✗ FAIL: Directory .scratch/user-logout/issues not created"
    exit 1
fi
echo

# Test 10: Branch creation when on default branch
echo "Test 10: Create new branch when on default branch"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
DEFAULT_BRANCH=$(detect_default_branch)
if [ "$CURRENT_BRANCH" = "$DEFAULT_BRANCH" ]; then
    NEW_BRANCH="feature/user-logout"
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

# Test 11: Switch to existing branch
echo "Test 11: Switch to existing branch when it already exists"
git checkout main -q
EXISTING_BRANCH="feature/user-logout"
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
    echo "✗ FAIL: Test branch should exist from Test 10"
    exit 1
fi
echo

# Test 12: Continue when already on non-default branch
echo "Test 12: Continue when already on non-default branch"
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
