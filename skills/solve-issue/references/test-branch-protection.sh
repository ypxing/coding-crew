#!/bin/bash
# Test script for branch protection logic in address-pr-comments and address-code-review Step 0
# Tests that default branch detection and blocking works correctly

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

echo "Testing branch protection logic..."
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

# Helper function to check if on default branch
check_default_branch() {
    local current_branch=$(git rev-parse --abbrev-ref HEAD)
    local default_branch=$(detect_default_branch)
    
    if [ "$current_branch" = "$default_branch" ]; then
        echo "ERROR: Cannot run on default branch ($default_branch). Switch to your PR branch first: git checkout <branch-name>"
        return 1
    fi
    return 0
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

# Test 2: Block when on default branch (main)
echo "Test 2: Block when on default branch (main)"
if check_default_branch 2>&1 | grep -q "ERROR: Cannot run on default branch"; then
    echo "✓ PASS: Blocked execution on main branch"
else
    echo "✗ FAIL: Should have blocked execution on main branch"
    exit 1
fi
echo

# Test 3: Allow when on feature branch
echo "Test 3: Allow when on feature branch"
git checkout -b feature/test-pr -q
if check_default_branch 2>/dev/null; then
    echo "✓ PASS: Allowed execution on feature branch"
else
    echo "✗ FAIL: Should allow execution on feature branch"
    exit 1
fi
echo

# Test 4: Block when on master (alternative default branch name)
echo "Test 4: Block when on master (alternative default branch)"
git checkout -b master -q main
# Simulate origin/HEAD pointing to master
mkdir -p .git/refs/remotes/origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
if check_default_branch 2>&1 | grep -q "ERROR: Cannot run on default branch"; then
    echo "✓ PASS: Blocked execution on master branch"
else
    echo "✗ FAIL: Should have blocked execution on master branch"
    exit 1
fi
echo

# Test 5: Allow on different feature branch
echo "Test 5: Allow on different feature branch"
git checkout -b feature/another-pr -q
if check_default_branch 2>/dev/null; then
    echo "✓ PASS: Allowed execution on another feature branch"
else
    echo "✗ FAIL: Should allow execution on another feature branch"
    exit 1
fi
echo

# Cleanup
cd - > /dev/null
rm -rf "$TEST_DIR"

echo "All tests passed! ✓"
