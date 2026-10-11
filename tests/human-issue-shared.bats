#!/usr/bin/env bats

# The `## For a human` block lives once, in skills/_shared/fragments/human-issue.md, and is
# inlined into to-issues and upgrade-deps. Assertions read the rendered skill bodies.

load helpers/render
load helpers/platforms

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
FRAG="$REPO_ROOT/skills/_shared/fragments/human-issue.md"

@test "the fragment's example lints with no output" {
  d="$BATS_TEST_TMPDIR/issues"; mkdir -p "$d"
  awk '/^````markdown/{f=1;next} /^````$/{f=0} f' "$FRAG" > "$d/1-example.md"
  run bash "$REPO_ROOT/skills/to-issues/scripts/lint-issues.sh" --issue "$d/1-example.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
