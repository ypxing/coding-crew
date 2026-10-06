#!/usr/bin/env bats

# Tests for squash-commits.sh reading completed_slugs from sprint-state.json

SQUASH_SCRIPT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/squash-commits.sh"

setup() {
  export TEMP_DIR=$(mktemp -d)
  cd "$TEMP_DIR"

  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  git commit --allow-empty -m "initial"

  export FEATURE_SLUG="test-feature"
  mkdir -p ".scratch/$FEATURE_SLUG/issues/done"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

_write_state() {
  local branch="$1" base_sha="$2"
  mkdir -p ".scratch/$FEATURE_SLUG"
  echo "{}" | jq \
    --arg branch "$branch" \
    --arg sha "$base_sha" \
    '.branches[$branch] = {base_sha: $sha}' \
    > ".scratch/$FEATURE_SLUG/sprint-state.json"
}

_add_slug_to_state() {
  local slug="$1"
  local state=".scratch/$FEATURE_SLUG/sprint-state.json"
  jq --arg slug "$slug" '.completed_slugs += [$slug]' "$state" > "$state.tmp" && mv "$state.tmp" "$state"
}

_write_issue() {
  local slug="$1" title="$2"
  cat > ".scratch/$FEATURE_SLUG/issues/done/01-${slug}.md" <<EOF
Status: done

## What to build

${title}

## Acceptance criteria

- [x] Done
EOF
}

@test "squash-commits reads completed_slugs from sprint-state.json" {
  local base_sha
  base_sha=$(git rev-parse HEAD)

  git checkout -q -b "feature/$FEATURE_SLUG"
  echo "change1" > work.txt && git add work.txt && git commit -q -m "work commit"

  _write_state "feature/$FEATURE_SLUG" "$base_sha"
  _add_slug_to_state "my-issue"
  _write_issue "my-issue" "My issue title"

  run bash "$SQUASH_SCRIPT"
  [ "$status" -eq 0 ]

  # Squashed commit body should contain issue bullet
  run git log -1 --format="%B"
  [[ "$output" == *"My issue title"* ]]
}

# The label was built with GNU sed's \b and \u, which BSD sed (macOS) ignores — the
# subject came out as "test feature: …" there.
@test "squash-commits title-cases the feature slug on every platform" {
  local base_sha
  base_sha=$(git rev-parse HEAD)

  git checkout -q -b "feature/$FEATURE_SLUG"
  echo "change1" > work.txt && git add work.txt && git commit -q -m "work commit"

  _write_state "feature/$FEATURE_SLUG" "$base_sha"
  _add_slug_to_state "my-issue"
  _write_issue "my-issue" "My issue title"

  run bash "$SQUASH_SCRIPT"
  [ "$status" -eq 0 ]

  [ "$(git log -1 --format=%s)" = "Test Feature: My issue title" ]
}

@test "squash-commits produces non-empty commit body with two slugs" {
  local base_sha
  base_sha=$(git rev-parse HEAD)

  git checkout -q -b "feature/$FEATURE_SLUG"
  echo "change1" > work1.txt && git add work1.txt && git commit -q -m "work 1"
  echo "change2" > work2.txt && git add work2.txt && git commit -q -m "work 2"

  _write_state "feature/$FEATURE_SLUG" "$base_sha"
  _add_slug_to_state "first-issue"
  _add_slug_to_state "second-issue"
  _write_issue "first-issue" "First issue title"
  _write_issue "second-issue" "Second issue title"

  run bash "$SQUASH_SCRIPT"
  [ "$status" -eq 0 ]

  run git log -1 --format="%B"
  [[ "$output" == *"First issue title"* ]]
  [[ "$output" == *"Second issue title"* ]]
}

@test "squash-commits skips when no completed_slugs in state" {
  local base_sha
  base_sha=$(git rev-parse HEAD)

  git checkout -q -b "feature/$FEATURE_SLUG"
  git commit --allow-empty -m "work"

  _write_state "feature/$FEATURE_SLUG" "$base_sha"
  # No completed_slugs written

  run bash "$SQUASH_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No completed issues"* ]]
}

@test "--no-squash flag still skips squash" {
  local base_sha
  base_sha=$(git rev-parse HEAD)

  git checkout -q -b "feature/$FEATURE_SLUG"
  git commit --allow-empty -m "work"

  _write_state "feature/$FEATURE_SLUG" "$base_sha"
  _add_slug_to_state "some-issue"

  run bash "$SQUASH_SCRIPT" --no-squash
  [ "$status" -eq 0 ]
  [[ "$output" == *"Skipping squash"* ]]
}

@test "a squash commit refused by a hook restores the branch tip instead of leaving the work staged" {
  local base_sha orig_tip
  base_sha=$(git rev-parse HEAD)

  git checkout -q -b "feature/$FEATURE_SLUG"
  echo "change1" > work.txt && git add work.txt && git commit -q -m "work commit"
  orig_tip=$(git rev-parse HEAD)

  _write_state "feature/$FEATURE_SLUG" "$base_sha"
  _add_slug_to_state "my-issue"
  _write_issue "my-issue" "My issue title"

  printf '#!/bin/sh\necho "commit-msg: rejected" >&2\nexit 1\n' > .git/hooks/commit-msg
  chmod +x .git/hooks/commit-msg

  run bash "$SQUASH_SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"branch restored to $orig_tip"* ]]

  [ "$(git rev-parse HEAD)" = "$orig_tip" ]
  [ -z "$(git status --porcelain --untracked-files=no)" ]
  # The state's base is untouched, so a re-run squashes the same range.
  [ "$(jq -r --arg b "feature/$FEATURE_SLUG" '.branches[$b].base_sha' ".scratch/$FEATURE_SLUG/sprint-state.json")" = "$base_sha" ]
}

# The trailer is the caller's to choose (loop.mjs passes the coder runtime's adapter coAuthor).
@test "--co-author adds that trailer to the squash commit" {
  local base_sha
  base_sha=$(git rev-parse HEAD)

  git checkout -q -b "feature/$FEATURE_SLUG"
  echo "change1" > work.txt && git add work.txt && git commit -q -m "work commit"

  _write_state "feature/$FEATURE_SLUG" "$base_sha"
  _add_slug_to_state "my-issue"
  _write_issue "my-issue" "My issue title"

  run bash "$SQUASH_SCRIPT" --co-author "Co-authored-by: Codex <noreply@openai.com>"
  [ "$status" -eq 0 ]

  [ "$(git log -1 --format='%(trailers:key=Co-authored-by,valueonly)' | sed '/^$/d')" = "Codex <noreply@openai.com>" ]
}

@test "with no --co-author the squash commit carries no trailer" {
  local base_sha
  base_sha=$(git rev-parse HEAD)

  git checkout -q -b "feature/$FEATURE_SLUG"
  echo "change1" > work.txt && git add work.txt && git commit -q -m "work commit"

  _write_state "feature/$FEATURE_SLUG" "$base_sha"
  _add_slug_to_state "my-issue"
  _write_issue "my-issue" "My issue title"

  run bash "$SQUASH_SCRIPT"
  [ "$status" -eq 0 ]

  run git log -1 --format="%B"
  [[ "$output" == *"My issue title"* ]]
  [[ "$output" != *"Co-authored-by"* ]]
}

@test "--platform is an unknown flag" {
  run bash "$SQUASH_SCRIPT" --platform claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown flag: --platform"* ]]
}
