#!/usr/bin/env bats

# The `## For a human` block lives once, in skills/_shared/fragments/human-issue.md, and is
# inlined into to-issues and upgrade-deps. Assertions read the rendered skill bodies.

load helpers/render

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
FRAG="$REPO_ROOT/skills/_shared/fragments/human-issue.md"

@test "fragment names the five parts, Check/Undo, and both kinds" {
  for t in 'Why a person' 'What changes' 'Steps' 'If skipped or done wrong' 'Done when' 'Check:' 'Undo:' '## Interfaces' 'ready-for-agent'; do
    grep -qF "$t" "$FRAG"
  done
  grep -q 'Kind A' "$FRAG"; grep -q 'Kind B' "$FRAG"
}

@test "to-issues renders the fragment for every platform" {
  for p in claude copilot pi codex; do
    run rendered_skill to-issues "$p"
    [ "$status" -eq 0 ]
    grep -qF 'Kind A — the whole task is a person' "$output"
    ! grep -q '{{FRAGMENT' "$output"
  done
}

@test "to-issues routes the HITL reason and failing Requires output into Why a person" {
  run rendered_skill to-issues claude
  grep -qF "becomes the block's \`### Why a person\`" "$output" || grep -qF "block's \`### Why a person\`" "$output"
  grep -qF 'the failing command and its output go in `### Why a person`' "$output"
}

@test "upgrade-deps renders the fragment" {
  run rendered_skill upgrade-deps claude
  grep -qF 'Kind B — agent work blocked on a person' "$output"
  ! grep -q '{{FRAGMENT' "$output"
}

@test "the fragment's example lints with no For a human WARN" {
  d="$BATS_TEST_TMPDIR/issues"; mkdir -p "$d"
  awk '/^````markdown/{f=1;next} /^````$/{f=0} f' "$FRAG" > "$d/1-example.md"
  run bash "$REPO_ROOT/skills/to-issues/scripts/lint-issues.sh" --issue "$d/1-example.md"
  [ "$status" -eq 0 ]
  ! grep -q 'For a human' <<<"$output"
}
