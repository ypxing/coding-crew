#!/usr/bin/env bats

# The `## For a human` block lives once, in skills/_shared/fragments/human-issue.md, and is
# inlined into to-issues and upgrade-deps. Assertions read the rendered skill bodies.

load helpers/render
load helpers/platforms

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
FRAG="$REPO_ROOT/skills/_shared/fragments/human-issue.md"

