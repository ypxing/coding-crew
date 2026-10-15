#!/usr/bin/env bats

# scripts/smoke-sprint.sh <platform> — the release smoke: the pinned demo repo, a project-level install kept out
# of git, and one crew-afk dispatch whose run must end `ready pr=<n>`. Here the demo repo is a local one
# (CREW_DEMO_DIR laid out like scripts/smoke-sprint/demo/), `gh` is a stub that logs its argv, and
# CREW_SMOKE_DISPATCH stands in for crew-afk.sh: it adds a worktree, writes solve-feature's files there and
# prints the worktree and a short-lived pid, so no agent CLI is called.

load helpers/smoke-demo

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SMOKE="$REPO_ROOT/scripts/smoke-sprint.sh"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  D="$TMPDIR/crew-smoke-claude"

  # No user-level skills but the ones a test puts there: they would shadow the project install.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset $(jq -r '.[].configDirEnv // empty' "$REPO_ROOT/platforms.json" | tr -d '\r')
  make_smoke_demo
  RESULTS="$BATS_TEST_TMPDIR/RESULTS.md"
  printf '| commit | date | platform | result | cost | findings |\n|---|---|---|---|---|---|\n' > "$RESULTS"
  export CREW_SMOKE_RESULTS="$RESULTS"
}

@test "a run that ends ready passes, records one row, and closes its PR and branch" {
  run "$SMOKE" claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"SMOKE: PASS (claude, demo)"* ]]
  [[ "$output" =~ crew-afk-commit:\ [0-9a-f]{40}(-dirty)? ]]
  grep -qxF "dispatch dispatch report-cli --to local (in $D, agent claude)" "$BATS_TEST_TMPDIR/calls"
  grep -qx 'gh pr close 9' "$BATS_TEST_TMPDIR/calls"
  grep -qx 'gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/feature/report-cli' "$BATS_TEST_TMPDIR/calls"
  [ "$(wc -l < "$RESULTS")" -eq 3 ]
  [[ "$(tail -n 1 "$RESULTS")" =~ ^\|\ [0-9a-f]{12}(-dirty)?\ \|\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ \|\ claude\ \|\ PASS\ \|\ \$1\.25\ \|\ 2\ \|$ ]]
}

@test "the smoke repo is the pinned clone with origin kept, the install and feature in place and the tree clean" {
  run "$SMOKE" claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$D" rev-parse HEAD)" = "$PIN" ]
  [ "$(git -C "$D" remote get-url origin)" = "$UP" ]
  [ -f "$D/.claude/skills/crew-afk/scripts/crew-afk.sh" ]
  [ -f "$D/.scratch/report-cli/issues/open/01-one.md" ]
  local p
  for p in .coding-crew/lib .coding-crew/manifest.json .claude/skills; do
    grep -qxF "$p" "$D/.worktreeinclude" || { echo "worktreeinclude lacks $p"; return 1; }
    grep -qxF "$p" "$D/.git/info/exclude" || { echo "exclude lacks $p"; return 1; }
  done
  grep -qxF .worktreeinclude "$D/.git/info/exclude"
  grep -qxF .scratch/ "$D/.git/info/exclude"
  [ -z "$(git -C "$D" status --porcelain)" ]
}

@test "an open PR left from an earlier run is closed and its branch deleted before the dispatch" {
  GH_OPEN_PR=5 run "$SMOKE" claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  close=$(grep -n 'gh pr close 5' "$BATS_TEST_TMPDIR/calls" | cut -d: -f1)
  dispatch=$(grep -n '^dispatch ' "$BATS_TEST_TMPDIR/calls" | cut -d: -f1)
  [ -n "$close" ] && [ "$close" -lt "$dispatch" ]
}

@test "a run that ends needing attention fails, records a FAIL row and leaves its PR open" {
  OUTCOME='needs-attention pr=9' run "$SMOKE" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: "*"needs-attention pr=9"* ]]
  [[ "$output" == *"crew-afk-commit: "* ]]
  [[ "$(tail -n 1 "$RESULTS")" == *"| claude | FAIL |"* ]]
  ! grep -q 'gh pr close 9' "$BATS_TEST_TMPDIR/calls"
}

@test "a check that fails in the run's worktree fails the smoke, naming it" {
  echo 'test -f missing.txt' >> "$DEMO/check"
  run "$SMOKE" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: "*"test -f missing.txt"* ]]
}

@test "a demo repo whose default branch moved past the pin fails before any dispatch" {
  echo two > "$UP/b.txt"
  git -C "$UP" add -A && git -C "$UP" -c user.email=t@t -c user.name=t commit -qm two
  run "$SMOKE" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: demo repo moved: origin/main is $(git -C "$UP" rev-parse HEAD), pinned $PIN"* ]]
  ! grep -q '^dispatch ' "$BATS_TEST_TMPDIR/calls"
}

@test "a second run rebuilds the repo; a directory that is not a smoke repo is refused, not deleted" {
  "$SMOKE" claude >/dev/null
  echo stale > "$D/stale.txt"
  run "$SMOKE" claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$D/stale.txt" ]
  rm -rf "$D" && mkdir -p "$D" && echo keep > "$D/keep.txt"
  run "$SMOKE" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a smoke repo"* ]]
  [ -f "$D/keep.txt" ]
}

@test "a user-level copy of a skill that would shadow the project install fails before any dispatch" {
  mkdir -p "$HOME/.claude/skills/solve-feature"
  echo stale > "$HOME/.claude/skills/solve-feature/SKILL.md"
  run "$SMOKE" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: user-level skills shadow the project install"* ]]
  ! grep -q '^dispatch ' "$BATS_TEST_TMPDIR/calls"
}

@test "an unknown platform is a usage error" {
  run "$SMOKE" nope
  [ "$status" -eq 2 ]
}
