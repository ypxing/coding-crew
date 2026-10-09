#!/usr/bin/env bats

# The `## For a human` block lives once, in skills/_shared/fragments/human-issue.md, and is
# inlined into to-issues and upgrade-deps. Assertions read the rendered skill bodies.

load helpers/render
load helpers/platforms

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
FRAG="$REPO_ROOT/skills/_shared/fragments/human-issue.md"

@test "fragment names the five parts, Check/Undo, and both kinds" {
  for t in 'Why a person' 'What changes' 'Steps' 'If skipped or done wrong' 'Done when' 'Check:' 'Undo:' '## Interfaces' 'ready-for-agent'; do
    grep -qF "$t" "$FRAG"
  done
  grep -q 'Kind A' "$FRAG"; grep -q 'Kind B' "$FRAG"
}

@test "to-issues renders the fragment for every platform" {
  for p in "${PLATFORMS[@]}"; do
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

@test "every rendered to-issues and upgrade-deps ends a Kind A issue's Steps with Mark it done" {
  local r runs=()
  for r in "${PLATFORMS[@]}"; do runs+=("to-issues $r"); done
  runs+=("upgrade-deps claude")
  for r in "${runs[@]}"; do
    # shellcheck disable=SC2086
    run rendered_skill $r
    [ "$status" -eq 0 ]
    grep -qF '"Mark it done"' "$output"
    grep -qF 'runs `node .coding-crew/tracker/cli.mjs mark-done <n>` from the repo root when the `cli.mjs` you located under Tracker Configuration is inside this repo or its main checkout' "$output"
    grep -qF 'else `node ~/.coding-crew/tracker/cli.mjs mark-done <n>` (local tracker: the issue file path instead of `<n>`)' "$output"
    grep -qF 'never the absolute path you located' "$output"
    ! grep -qE 'mark-issue-done\.sh|tracker-config\.sh' "$output"
    grep -qF '`Check:` the command exits 0 and prints no `REFUSED` line' "$output"
    grep -qF '`Undo:` follow "Reopen an issue" in the tracker doc `.coding-crew/tracker/docs/<kind>.md`' "$output"
    if grep -qE 'awaiting-merge|issues/(open|done)' <(sed -n '/Kind A/p' "$output"); then echo "forbidden text matched (line 55 of human-issue-shared.bats)" >&2; return 1; fi
  done
}

@test "the fragment says criteria are written unticked, and its example ends Steps with Mark it done" {
  run rendered_skill to-issues claude
  grep -qF 'Write acceptance criteria unticked (`- [ ]`)' "$output"
  steps=$(awk '/^````markdown/{f=1;next} /^````$/{f=0} f' "$FRAG" | awk '/^### Steps/{f=1;next} /^###/{f=0} f')
  last=$(grep -E '^[0-9]+\. ' <<<"$steps" | tail -1)
  [[ "$last" == *"Mark it done"* ]]
  grep -qF 'node .coding-crew/tracker/cli.mjs mark-done 42' <<<"$(sed -n '/Mark it done/,$p' <<<"$steps")"
  [[ "$last" == *'Undo: follow "Reopen an issue" in `.coding-crew/tracker/docs/<kind>.md`'* ]]
  [[ "$last" != *awaiting-merge* && "$last" != *issues/* ]]
}

@test "no rendered skill body names the retired tracker wrappers" {
  local s
  for s in $(jq -r '.skills | keys[]' "$REPO_ROOT/registry.json"); do
    run rendered_skill "$s" claude
    [ "$status" -eq 0 ]
    ! grep -qE 'mark-issue-done\.sh|tracker-config\.sh' <<<"$output" || { echo "named in $s"; return 1; }
  done
}

@test "the fragment's example lints with no output" {
  d="$BATS_TEST_TMPDIR/issues"; mkdir -p "$d"
  awk '/^````markdown/{f=1;next} /^````$/{f=0} f' "$FRAG" > "$d/1-example.md"
  run bash "$REPO_ROOT/skills/to-issues/scripts/lint-issues.sh" --issue "$d/1-example.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
