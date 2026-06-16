#!/bin/bash
# Test script for config parsing precedence in solve-issue skill
# Tests the three-level precedence: CLI flags > config file > default

set -e

PROJECT_ROOT="/Users/yunpengxing/repo/shared/temp/ai-agents"
MAIN_ROOT="$PROJECT_ROOT"
CONFIG_FILE="$MAIN_ROOT/docs/agents/sprint-config.md"

echo "Testing config parsing precedence..."
echo

# Helper function to parse commit preference (mimics Step 6 logic)
parse_commit_preference() {
    local args="$1"
    local SHOULD_COMMIT="yes"  # default
    
    # 1. Check for flags in invocation
    if [[ "$args" == *"--no-commit"* ]]; then
        SHOULD_COMMIT="no"
    elif [[ "$args" == *"--commit"* ]]; then
        SHOULD_COMMIT="yes"
    # 2. Check config file
    elif [ -f "$CONFIG_FILE" ]; then
        CONFIG_VALUE=$(grep "^auto_commit:" "$CONFIG_FILE" 2>/dev/null | awk '{print $2}' || echo "")
        if [ "$CONFIG_VALUE" = "no" ]; then
            SHOULD_COMMIT="no"
        fi
    fi
    # 3. Default remains "yes" from initial assignment
    
    echo "$SHOULD_COMMIT"
}

# Test 1: Default (no flag, no config change)
echo "Test 1: Default behavior (no flag, config=yes)"
result=$(parse_commit_preference "")
if [ "$result" = "yes" ]; then
    echo "✓ PASS: Default is 'yes'"
else
    echo "✗ FAIL: Expected 'yes', got '$result'"
    exit 1
fi
echo

# Test 2: --no-commit flag overrides config
echo "Test 2: --no-commit flag overrides config"
result=$(parse_commit_preference "--no-commit")
if [ "$result" = "no" ]; then
    echo "✓ PASS: --no-commit flag returns 'no'"
else
    echo "✗ FAIL: Expected 'no', got '$result'"
    exit 1
fi
echo

# Test 3: --commit flag overrides config
echo "Test 3: --commit flag explicitly sets 'yes'"
result=$(parse_commit_preference "--commit")
if [ "$result" = "yes" ]; then
    echo "✓ PASS: --commit flag returns 'yes'"
else
    echo "✗ FAIL: Expected 'yes', got '$result'"
    exit 1
fi
echo

# Test 4: Config file with auto_commit: no (without flag override)
echo "Test 4: Config file precedence (auto_commit: no)"
# Backup original config
cp "$CONFIG_FILE" "$CONFIG_FILE.backup"
# Set config to no
sed -i 's/^auto_commit: yes/auto_commit: no/' "$CONFIG_FILE"
result=$(parse_commit_preference "")
# Restore original config
mv "$CONFIG_FILE.backup" "$CONFIG_FILE"

if [ "$result" = "no" ]; then
    echo "✓ PASS: Config file 'auto_commit: no' returns 'no'"
else
    echo "✗ FAIL: Expected 'no', got '$result'"
    exit 1
fi
echo

# Test 5: Flag overrides config (--commit with auto_commit: no)
echo "Test 5: --commit flag overrides auto_commit: no"
# Backup and modify config
cp "$CONFIG_FILE" "$CONFIG_FILE.backup"
sed -i 's/^auto_commit: yes/auto_commit: no/' "$CONFIG_FILE"
result=$(parse_commit_preference "--commit")
# Restore config
mv "$CONFIG_FILE.backup" "$CONFIG_FILE"

if [ "$result" = "yes" ]; then
    echo "✓ PASS: --commit flag overrides config 'no' to 'yes'"
else
    echo "✗ FAIL: Expected 'yes', got '$result'"
    exit 1
fi
echo

# Test 6: Flag with path argument
echo "Test 6: Flag parsing with issue path"
result=$(parse_commit_preference ".scratch/test/issues/01-test.md --no-commit")
if [ "$result" = "no" ]; then
    echo "✓ PASS: Parses --no-commit with path argument"
else
    echo "✗ FAIL: Expected 'no', got '$result'"
    exit 1
fi
echo

echo "All tests passed! ✓"
