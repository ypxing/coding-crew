#!/usr/bin/env bats

# Tests for the tracker template and install destination paths

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export ISSUE_TRACKER="$SCRIPT_DIR/docs/templates/trackers/local.md"
  export TEMPLATE="$SCRIPT_DIR/docs/templates/trackers/local.md"
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
