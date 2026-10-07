#!/usr/bin/env bats

# Tests for the tracker template and install destination paths

setup() {
  export SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  export ISSUE_TRACKER="$SCRIPT_DIR/docs/templates/trackers/local.md"
  export TEMPLATE="$SCRIPT_DIR/docs/templates/trackers/local.md"
  export GITHUB_TEMPLATE="$SCRIPT_DIR/docs/templates/trackers/github.md"
}

@test "issue-tracker.md contains the Tracker CLI, Labels and Workspace sections and no Operation sections" {
  grep -q '^## Tracker CLI'              "$ISSUE_TRACKER"
  ! grep -q '^## Operation:'             "$ISSUE_TRACKER"
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

@test "docs/templates/trackers/local.md contains the Tracker CLI, Labels and Workspace sections and no Operation sections" {
  grep -q '^## Tracker CLI'              "$TEMPLATE"
  ! grep -q '^## Operation:'             "$TEMPLATE"
  grep -q '^## Labels'                   "$TEMPLATE"
  grep -q '^## Workspace'                "$TEMPLATE"
}

@test "docs/agents/ directory has been removed from source repo" {
  [ ! -d "$SCRIPT_DIR/docs/agents" ]
}

@test "docs/templates/trackers/github.md exists" {
  [ -f "$GITHUB_TEMPLATE" ]
}

@test "docs/templates/trackers/github.md contains the Tracker CLI, Labels and Workspace sections and no Operation sections" {
  grep -q '^## Tracker CLI'              "$GITHUB_TEMPLATE"
  ! grep -q '^## Operation:'             "$GITHUB_TEMPLATE"
  grep -q '^## Labels'                   "$GITHUB_TEMPLATE"
  grep -q '^## Workspace'                "$GITHUB_TEMPLATE"
}

@test "docs/templates/trackers/github.md's Tracker CLI section lists the CLI ops, not gh calls" {
  local cli
  cli=$(awk '/^## Tracker CLI/{f=1;next} /^## /{f=0} f' "$GITHUB_TEMPLATE")
  for op in fetch prd known publish-issues publish-prd rewrite mark-done; do
    grep -qE "^node \"\\\$TRACKER\" $op( |$)" <<<"$cli"
  done
  ! grep -qE '^gh (issue (create|edit|view)|api)' <<<"$cli"
}

@test "docs/templates/trackers/github.md: done is the awaiting-merge label, wontfix a close-reason" {
  grep -q 'node "$TRACKER" mark-done <number>' "$GITHUB_TEMPLATE"
  grep -q 'awaiting-merge'                 "$GITHUB_TEMPLATE"
  grep -q -- '--reason not-planned'        "$GITHUB_TEMPLATE"
  grep -q 'Closes #<number>'               "$GITHUB_TEMPLATE"
  # mark-done must not close: the work is only on a branch until its PR merges.
  local mark_done
  mark_done=$(awk '/^## Tracker CLI/{f=1;next} /^## /{f=0} f' "$GITHUB_TEMPLATE")
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
