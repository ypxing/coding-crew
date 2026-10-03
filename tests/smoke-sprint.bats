#!/usr/bin/env bats

# scripts/smoke-sprint.sh — the fresh-repo, one-issue crew-afk sprint. Only --setup-only runs here
# (no platform CLI, no API cost): the fixture must install, pass its own tests, lint clean, and
# rebuild from scratch on a second run; a directory that is not a smoke repo is never deleted.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SMOKE="$REPO_ROOT/scripts/smoke-sprint.sh"
  D="$BATS_TEST_TMPDIR/smoke"
}

@test "setup-only builds a committed repo whose fixture tests pass and issues lint clean" {
  run "$SMOKE" claude --dir "$D" --setup-only
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$D" status --porcelain)" ]
  [ -f "$D/.coding-crew/crew-afk/main.mjs" ]
  (cd "$D" && node --test >/dev/null 2>&1)
  run bash "$D/.coding-crew/to-issues/scripts/lint-issues.sh" \
    --issue "$D/.scratch/subtract/issues/open/01-add-sub.md" \
    --deps "$D/.scratch/subtract/issues/issues-deps.json" --prd "$D/.scratch/subtract/PRD.md"
  [ "$status" -eq 0 ]
  [[ "$output" != *WARN* ]]
}

@test "a second run rebuilds the repo from scratch" {
  "$SMOKE" claude --dir "$D" --setup-only
  git -C "$D" branch leftover
  echo stale > "$D/stale.txt"
  run "$SMOKE" claude --dir "$D" --setup-only
  [ "$status" -eq 0 ]
  [ ! -e "$D/stale.txt" ]
  ! git -C "$D" rev-parse -q --verify leftover
}

@test "an existing directory that is not a smoke repo is refused, not deleted" {
  mkdir -p "$D" && echo keep > "$D/keep.txt"
  run "$SMOKE" claude --dir "$D" --setup-only
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a smoke repo"* ]]
  [ -f "$D/keep.txt" ]
}

@test "an unknown platform is a usage error" {
  run "$SMOKE" nope --setup-only
  [ "$status" -eq 2 ]
}
