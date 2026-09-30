#!/usr/bin/env bats

# Tests for the tracker template and install destination paths

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export ISSUE_TRACKER="$SCRIPT_DIR/docs/templates/trackers/local.md"
  export TEMPLATE="$SCRIPT_DIR/docs/templates/trackers/local.md"
  export GITHUB_TEMPLATE="$SCRIPT_DIR/docs/templates/trackers/github.md"
}

@test "issue-tracker.md contains all seven required sections" {
  grep -q '^## Operation: list'          "$ISSUE_TRACKER"
  grep -q '^## Operation: fetch'         "$ISSUE_TRACKER"
  grep -q '^## Operation: publish'       "$ISSUE_TRACKER"
  grep -q '^## Operation: mark-done'     "$ISSUE_TRACKER"
  grep -q '^## Operation: status-update' "$ISSUE_TRACKER"
  grep -q '^## Labels'                   "$ISSUE_TRACKER"
  grep -q '^## Workspace'               "$ISSUE_TRACKER"
}

@test "issue-tracker.md Labels section contains all six canonical labels" {
  grep -q 'needs-triage'    "$ISSUE_TRACKER"
  grep -q 'needs-info'      "$ISSUE_TRACKER"
  grep -q 'ready-for-agent' "$ISSUE_TRACKER"
  grep -q 'ready-for-human' "$ISSUE_TRACKER"
  grep -q 'wontfix'         "$ISSUE_TRACKER"
  grep -q 'done'            "$ISSUE_TRACKER"
}

@test "issue-tracker.md Workspace section explains slug to .scratch mapping" {
  # Extract content after ## Workspace heading and verify it mentions .scratch/<slug>
  local workspace_content
  workspace_content=$(awk '/^## Workspace/{found=1} found{print}' "$ISSUE_TRACKER")
  echo "$workspace_content" | grep -q '\.scratch/'
  echo "$workspace_content" | grep -qE 'slug|feature'
}

@test "docs/templates/trackers/ directory exists" {
  [ -d "$SCRIPT_DIR/docs/templates/trackers" ]
}

@test "docs/templates/trackers/local.md exists" {
  [ -f "$TEMPLATE" ]
}

@test "docs/templates/trackers/local.md contains all seven required sections" {
  grep -q '^## Operation: list'          "$TEMPLATE"
  grep -q '^## Operation: fetch'         "$TEMPLATE"
  grep -q '^## Operation: publish'       "$TEMPLATE"
  grep -q '^## Operation: mark-done'     "$TEMPLATE"
  grep -q '^## Operation: status-update' "$TEMPLATE"
  grep -q '^## Labels'                   "$TEMPLATE"
  grep -q '^## Workspace'                "$TEMPLATE"
}

@test "docs/agents/ directory has been removed from source repo" {
  [ ! -d "$SCRIPT_DIR/docs/agents" ]
}

@test "docs/templates/trackers/github.md exists" {
  [ -f "$GITHUB_TEMPLATE" ]
}

@test "docs/templates/trackers/github.md contains all seven required sections" {
  grep -q '^## Operation: list'          "$GITHUB_TEMPLATE"
  grep -q '^## Operation: fetch'         "$GITHUB_TEMPLATE"
  grep -q '^## Operation: publish'       "$GITHUB_TEMPLATE"
  grep -q '^## Operation: mark-done'     "$GITHUB_TEMPLATE"
  grep -q '^## Operation: status-update' "$GITHUB_TEMPLATE"
  grep -q '^## Labels'                   "$GITHUB_TEMPLATE"
  grep -q '^## Workspace'                "$GITHUB_TEMPLATE"
}

@test "docs/templates/trackers/github.md operations are described in terms of gh issue/gh api" {
  grep -q 'gh issue' "$GITHUB_TEMPLATE"
  grep -q 'gh api'   "$GITHUB_TEMPLATE"
}

@test "docs/templates/trackers/github.md: done is the awaiting-merge label, wontfix a close-reason" {
  grep -q 'bash "$MD" <number>'   "$GITHUB_TEMPLATE"
  grep -q 'awaiting-merge'                 "$GITHUB_TEMPLATE"
  grep -q -- '--reason not-planned'        "$GITHUB_TEMPLATE"
  grep -q 'Closes #<number>'               "$GITHUB_TEMPLATE"
  # mark-done must not close: the work is only on a branch until its PR merges.
  local mark_done
  mark_done=$(awk '/^## Operation: mark-done/{f=1;next} /^## /{f=0} f' "$GITHUB_TEMPLATE")
  ! echo "$mark_done" | grep -q '^gh issue close'
}

@test "docs/templates/trackers/github.md Labels section lists the five real GitHub labels" {
  grep -q 'awaiting-merge'  "$GITHUB_TEMPLATE"
  grep -q 'needs-triage'    "$GITHUB_TEMPLATE"
  grep -q 'needs-info'      "$GITHUB_TEMPLATE"
  grep -q 'ready-for-agent' "$GITHUB_TEMPLATE"
  grep -q 'ready-for-human' "$GITHUB_TEMPLATE"
}

@test "both tracker templates document the ## Requires section" {
  grep -q '## Requires' "$TEMPLATE"
  grep -q 'Exit 0 means satisfied' "$TEMPLATE"
  grep -q '## Requires' "$GITHUB_TEMPLATE"
  grep -q 'exit 0 = satisfied' "$GITHUB_TEMPLATE"
}
