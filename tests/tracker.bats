#!/usr/bin/env bats
# The tracker CLI's node:test files (tests/tracker/*.test.mjs), one `node --test` per file, so a
# failure names its file; then the local tracker's effect on a real git repo's tree.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

run_node_test() {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  cd "$REPO_ROOT"
  # A temp HOME: a developer's real ~/.coding-crew/config.json must not pick a test's tracker.
  HOME="$BATS_TEST_TMPDIR/home" run node --test "$1"
  if [ "$status" -ne 0 ]; then
    echo "$output" >&3
  fi
  [ "$status" -eq 0 ]
}

@test "tracker: body-format.test.mjs passes" { run_node_test tests/tracker/body-format.test.mjs; }
@test "tracker: tracker-cli-write.test.mjs passes" { run_node_test tests/tracker/tracker-cli-write.test.mjs; }
@test "tracker: tracker-cli.test.mjs passes" { run_node_test tests/tracker/tracker-cli.test.mjs; }
@test "tracker: tracker-config.test.mjs passes" { run_node_test tests/tracker/tracker-config.test.mjs; }
@test "tracker: tracker-factory.test.mjs passes" { run_node_test tests/tracker/tracker-factory.test.mjs; }
@test "tracker: tracker-github.test.mjs passes" { run_node_test tests/tracker/tracker-github.test.mjs; }
@test "tracker: tracker.test.mjs passes" { run_node_test tests/tracker/tracker.test.mjs; }

@test "tracker: every tests/tracker/*.test.mjs has a test above" {
  local f
  for f in "$REPO_ROOT"/tests/tracker/*.test.mjs; do
    grep -qF "run_node_test tests/tracker/$(basename "$f")" "$BATS_TEST_FILENAME" || {
      echo "not run: tests/tracker/$(basename "$f")" >&3; return 1; }
  done
}

# A fresh consuming repo whose .gitignore says nothing about .scratch/, the local tracker the default.
fresh_repo() {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.scratch/feat/.drafts" && cd "$REPO" && git init -q .
  printf '# One\n\nStatus: ready-for-agent\n\n## Acceptance criteria\n\n- [ ] it works\n\n## Blocked by\n\nNone - can start immediately\n' \
    >.scratch/feat/.drafts/01-one.md
  echo '{"01-one.md": []}' >.scratch/feat/.drafts/deps.json
}

@test "tracker: local publish-issues, publish-prd, write-section, tick and mark-done leave a fresh repo's tree clean" {
  fresh_repo
  CLI="$REPO_ROOT/lib/tracker/cli.mjs"
  run node "$CLI" publish-issues --feature-slug feat --drafts .scratch/feat/.drafts
  [ "$status" -eq 0 ] || { echo "$output" >&3; return 1; }
  [ -z "$(git status --porcelain)" ] || { git status --porcelain >&3; return 1; }
  issue="$REPO/.scratch/feat/issues/open/01-one.md"
  printf '# PRD: Feat\n' >"$BATS_TEST_TMPDIR/prd.md" && printf 'why\n' >"$BATS_TEST_TMPDIR/note.md"
  node "$CLI" publish-prd --feature-slug feat --title Feat --body-file "$BATS_TEST_TMPDIR/prd.md"
  node "$CLI" write-section "$issue" --heading Notes --body-file "$BATS_TEST_TMPDIR/note.md"
  node "$CLI" tick "$issue"
  node "$CLI" mark-done "$issue"
  [ -f "$REPO/.scratch/feat/issues/done/01-one.md" ]
  [ -z "$(git status --porcelain)" ] || { git status --porcelain >&3; return 1; }
}

@test "tracker: a local publish leaves an existing .scratch/.gitignore as it is" {
  fresh_repo
  printf 'PRD.md\n' >.scratch/.gitignore
  run node "$REPO_ROOT/lib/tracker/cli.mjs" publish-issues --feature-slug feat --drafts .scratch/feat/.drafts
  [ "$status" -eq 0 ] || { echo "$output" >&3; return 1; }
  [ "$(cat .scratch/.gitignore)" = "PRD.md" ]
}
