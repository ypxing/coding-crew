#!/bin/bash
# Test script for afk-run sprint state tracking
# Tests state file creation, base_sha recording, and state persistence across sprints

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

echo "Testing afk-run sprint state tracking..."
echo

# Helper function to init state file
init_sprint_state() {
    local feature_slug="$1"
    local current_branch="$2"
    local base_sha="$3"
    local state_file=".scratch/$feature_slug/sprint-state.json"
    
    mkdir -p ".scratch/$feature_slug"
    
    # Check if state file exists
    if [ ! -f "$state_file" ]; then
        # Create new state file with initial branch entry
        echo "{}" | jq --arg branch "$current_branch" \
                        --arg sha "$base_sha" \
                        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                        '.branches[$branch] = {base_sha: $sha, created_at: $timestamp}' \
                        > "$state_file"
    else
        # Read existing state, add/update current branch entry
        jq --arg branch "$current_branch" \
           --arg sha "$base_sha" \
           --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           '.branches[$branch] = {base_sha: $sha, created_at: $timestamp}' \
           "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    fi
}

# Helper function to read base_sha from state file
read_base_sha() {
    local feature_slug="$1"
    local current_branch="$2"
    local state_file=".scratch/$feature_slug/sprint-state.json"
    
    if [ -f "$state_file" ]; then
        jq -r ".branches[\"$current_branch\"].base_sha // empty" "$state_file"
    fi
}

# Helper function to update base_sha after squash
update_base_sha() {
    local feature_slug="$1"
    local current_branch="$2"
    local new_sha="$3"
    local state_file=".scratch/$feature_slug/sprint-state.json"
    
    if [ -f "$state_file" ]; then
        jq --arg branch "$current_branch" \
           --arg sha "$new_sha" \
           '.branches[$branch].base_sha = $sha' \
           "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    fi
}

# Test 1: Create state file for first sprint
echo "Test 1: Create state file for first sprint"
git checkout -b feature/user-logout -q
FEATURE_SLUG="user-logout"
CURRENT_BRANCH="feature/user-logout"
BASE_SHA=$(git rev-parse HEAD)

init_sprint_state "$FEATURE_SLUG" "$CURRENT_BRANCH" "$BASE_SHA"

if [ -f ".scratch/$FEATURE_SLUG/sprint-state.json" ]; then
    echo "✓ PASS: State file created"
else
    echo "✗ FAIL: State file not created"
    exit 1
fi
echo

# Test 2: Verify state file structure
echo "Test 2: Verify state file structure contains branches object"
result=$(jq -r 'has("branches")' ".scratch/$FEATURE_SLUG/sprint-state.json")
if [ "$result" = "true" ]; then
    echo "✓ PASS: State file has branches object"
else
    echo "✗ FAIL: State file missing branches object"
    exit 1
fi
echo

# Test 3: Verify branch entry in state file
echo "Test 3: Verify branch entry exists with base_sha"
result=$(jq -r ".branches[\"$CURRENT_BRANCH\"] | has(\"base_sha\")" ".scratch/$FEATURE_SLUG/sprint-state.json")
if [ "$result" = "true" ]; then
    echo "✓ PASS: Branch entry has base_sha"
else
    echo "✗ FAIL: Branch entry missing base_sha"
    exit 1
fi
echo

# Test 4: Verify branch entry has created_at
echo "Test 4: Verify branch entry has created_at timestamp"
result=$(jq -r ".branches[\"$CURRENT_BRANCH\"] | has(\"created_at\")" ".scratch/$FEATURE_SLUG/sprint-state.json")
if [ "$result" = "true" ]; then
    echo "✓ PASS: Branch entry has created_at"
else
    echo "✗ FAIL: Branch entry missing created_at"
    exit 1
fi
echo

# Test 5: Read base_sha from state file
echo "Test 5: Read base_sha from state file"
result=$(read_base_sha "$FEATURE_SLUG" "$CURRENT_BRANCH")
if [ "$result" = "$BASE_SHA" ]; then
    echo "✓ PASS: Read base_sha correctly: $result"
else
    echo "✗ FAIL: Expected '$BASE_SHA', got '$result'"
    exit 1
fi
echo

# Test 6: Update base_sha after squash
echo "Test 6: Update base_sha after squash"
echo "change" > file2.txt
git add file2.txt
git commit -q -m "Second commit"
NEW_SHA=$(git rev-parse HEAD)

update_base_sha "$FEATURE_SLUG" "$CURRENT_BRANCH" "$NEW_SHA"
result=$(read_base_sha "$FEATURE_SLUG" "$CURRENT_BRANCH")
if [ "$result" = "$NEW_SHA" ]; then
    echo "✓ PASS: Updated base_sha correctly: $result"
else
    echo "✗ FAIL: Expected '$NEW_SHA', got '$result'"
    exit 1
fi
echo

# Test 7: Add second branch to existing state file
echo "Test 7: Add second branch to existing state file"
git checkout main -q
git checkout -b feature/user-profile -q
SECOND_BRANCH="feature/user-profile"
SECOND_SHA=$(git rev-parse HEAD)

init_sprint_state "$FEATURE_SLUG" "$SECOND_BRANCH" "$SECOND_SHA"

# Verify first branch still exists
result=$(jq -r ".branches[\"$CURRENT_BRANCH\"].base_sha" ".scratch/$FEATURE_SLUG/sprint-state.json")
if [ "$result" = "$NEW_SHA" ]; then
    echo "✓ PASS: First branch entry preserved"
else
    echo "✗ FAIL: First branch entry lost or changed"
    exit 1
fi

# Verify second branch exists
result=$(jq -r ".branches[\"$SECOND_BRANCH\"].base_sha" ".scratch/$FEATURE_SLUG/sprint-state.json")
if [ "$result" = "$SECOND_SHA" ]; then
    echo "✓ PASS: Second branch entry added"
else
    echo "✗ FAIL: Second branch entry not added correctly"
    exit 1
fi
echo

# Test 8: Handle missing state file gracefully
echo "Test 8: Handle missing state file gracefully when reading"
result=$(read_base_sha "nonexistent-feature" "some-branch")
if [ -z "$result" ]; then
    echo "✓ PASS: Returns empty string for missing state file"
else
    echo "✗ FAIL: Should return empty string, got '$result'"
    exit 1
fi
echo

# Test 9: Handle missing branch in existing state file
echo "Test 9: Handle missing branch in existing state file"
result=$(read_base_sha "$FEATURE_SLUG" "nonexistent-branch")
if [ -z "$result" ]; then
    echo "✓ PASS: Returns empty string for missing branch"
else
    echo "✗ FAIL: Should return empty string, got '$result'"
    exit 1
fi
echo

# Test 10: State file with JIRA-prefixed branch
echo "Test 10: State file with JIRA-prefixed branch"
git checkout main -q
git checkout -b feature/PROJ-123-payment-flow -q
JIRA_BRANCH="feature/PROJ-123-payment-flow"
# Feature-slug should be derived: strip feature/ and JIRA prefix
JIRA_FEATURE_SLUG="payment-flow"
JIRA_SHA=$(git rev-parse HEAD)

init_sprint_state "$JIRA_FEATURE_SLUG" "$JIRA_BRANCH" "$JIRA_SHA"

result=$(read_base_sha "$JIRA_FEATURE_SLUG" "$JIRA_BRANCH")
if [ "$result" = "$JIRA_SHA" ]; then
    echo "✓ PASS: JIRA-prefixed branch state stored correctly"
else
    echo "✗ FAIL: Expected '$JIRA_SHA', got '$result'"
    exit 1
fi
echo

# Cleanup
cd - > /dev/null
rm -rf "$TEST_DIR"

echo "All tests passed! ✓"
