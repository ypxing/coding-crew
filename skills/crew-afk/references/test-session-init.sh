#!/bin/bash
# Integration test script for session-init.sh
# Tests: issues/open/ creation, traces/ creation, session-start-sha, traces archiving, .gitignore warning

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Locate session-init.sh relative to this script
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_INIT="$SCRIPT_DIR/../scripts/session-init.sh"

if [ ! -f "$SESSION_INIT" ]; then
    echo "ERROR: session-init.sh not found at $SESSION_INIT"
    exit 1
fi

# ---------------------------------------------------------------------------
# Setup — temp git repo with cleanup trap
# ---------------------------------------------------------------------------
TEST_DIR=$(mktemp -d)
FEATURE_SLUG="test-feature"

trap 'rm -rf "$TEST_DIR"' EXIT

cd "$TEST_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"
git branch -M main
echo ".scratch" > .gitignore
git add .gitignore
git commit -q -m "Add .gitignore"
mkdir -p ".claude"

# Create a dummy issue
mkdir -p ".scratch/$FEATURE_SLUG/issues/open"
cat > ".scratch/$FEATURE_SLUG/issues/open/01-test.md" <<'EOF'
Status: ready-for-agent

## What to build

Test issue.
EOF

echo "Testing session-init.sh..."
echo

# ---------------------------------------------------------------------------
# Assertion 1: issues/open/ is created under .scratch/<feature-slug>/
# ---------------------------------------------------------------------------
echo "Assertion 1: issues/open/ is created under .scratch/<feature-slug>/"
bash "$SESSION_INIT" --feature-slug "$FEATURE_SLUG" > /dev/null 2>&1

if [ -d ".scratch/$FEATURE_SLUG/issues/open" ]; then
    pass "issues/open/ exists under .scratch/$FEATURE_SLUG/"
else
    fail "issues/open/ not found under .scratch/$FEATURE_SLUG/"
fi
echo

# ---------------------------------------------------------------------------
# Assertion 2: traces/ is created under .scratch/<feature-slug>/
# ---------------------------------------------------------------------------
echo "Assertion 2: traces/ is created under .scratch/<feature-slug>/"
if [ -d ".scratch/$FEATURE_SLUG/traces" ]; then
    pass "traces/ exists under .scratch/$FEATURE_SLUG/"
else
    fail "traces/ not found under .scratch/$FEATURE_SLUG/"
fi
echo

# ---------------------------------------------------------------------------
# Assertion 3: session-start-sha exists and contains a valid git SHA
# ---------------------------------------------------------------------------
echo "Assertion 3: session-start-sha exists under .scratch/<feature-slug>/ and contains a valid SHA"
SHA_FILE=".scratch/$FEATURE_SLUG/session-start-sha"
if [ -f "$SHA_FILE" ]; then
    SHA_CONTENT=$(cat "$SHA_FILE" | tr -d '[:space:]')
    EXPECTED_SHA=$(git rev-parse HEAD)
    if echo "$SHA_CONTENT" | grep -qE '^[0-9a-f]{40}$'; then
        pass "session-start-sha contains a valid 40-char hex SHA: $SHA_CONTENT"
    else
        fail "session-start-sha content '$SHA_CONTENT' is not a valid SHA"
    fi
    if [ "$SHA_CONTENT" = "$EXPECTED_SHA" ]; then
        pass "session-start-sha matches HEAD: $SHA_CONTENT"
    else
        fail "session-start-sha '$SHA_CONTENT' does not match HEAD '$EXPECTED_SHA'"
    fi
else
    fail "session-start-sha not found at $SHA_FILE"
fi
echo

# ---------------------------------------------------------------------------
# Assertion 4: Re-run archives previous traces/ as traces-<timestamp>/ (not deleted)
# ---------------------------------------------------------------------------
echo "Assertion 4: Re-run archives previous traces/ as traces-<timestamp>/ (not deleted)"
# Add a file to the current traces/ so we can verify it gets archived
echo "old log entry" > ".scratch/$FEATURE_SLUG/traces/worker.log"

bash "$SESSION_INIT" --feature-slug "$FEATURE_SLUG" > /dev/null 2>&1

ARCHIVED=$(find ".scratch/$FEATURE_SLUG" -maxdepth 1 -type d -name "traces-*" 2>/dev/null | head -n 1)
if [ -n "$ARCHIVED" ]; then
    pass "Previous traces/ was archived as $(basename "$ARCHIVED")"
else
    fail "Previous traces/ was not archived as traces-<timestamp>/"
fi

if [ -f "$ARCHIVED/worker.log" ]; then
    pass "Archived traces/ still contains old log file (not deleted)"
else
    fail "Archived traces/ is missing old log file (content was lost)"
fi

if [ -d ".scratch/$FEATURE_SLUG/traces" ]; then
    pass "Fresh traces/ was created after archiving"
else
    fail "Fresh traces/ was not created after archiving"
fi
echo

# ---------------------------------------------------------------------------
# Assertion 5: WARNING printed when .scratch is not in .gitignore
# ---------------------------------------------------------------------------
echo "Assertion 5: WARNING printed when .scratch is not in .gitignore"
WARN_DIR=$(mktemp -d)
cd "$WARN_DIR"
git init -q
git config user.email "test@example.com"
git config user.name "Test User"
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"
git branch -M main
mkdir -p ".claude"
# No .gitignore — .scratch is not covered

OUTPUT=$(bash "$SESSION_INIT" --feature-slug "warn-test" 2>&1)
if echo "$OUTPUT" | grep -q "WARNING"; then
    pass "WARNING is printed when .scratch is not gitignored"
else
    fail "No WARNING emitted when .scratch is not in .gitignore"
fi

# Cleanup warn dir — back to TEST_DIR (which also gets cleaned by trap)
cd "$TEST_DIR"
rm -rf "$WARN_DIR"
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
