#!/usr/bin/env bats

# tracker-config.sh — the bash equivalent of orchestrator/lib/tracker-config.mjs's
# readTrackerConfig(mainRoot): reads {tracker, repo} from the optional YAML front
# matter atop .coding-crew/docs/issue-tracker.md, sourceable by other scripts.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
  SCRIPT="$REPO_ROOT/scripts/tracker/tracker-config.sh"
  TEMP_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

write_doc() {
  mkdir -p "$TEMP_DIR/.coding-crew/docs"
  printf '%s' "$1" > "$TEMP_DIR/.coding-crew/docs/issue-tracker.md"
}

@test "tracker-config.sh defaults to local with no repo when the doc is absent entirely" {
  source "$SCRIPT"
  read_tracker_config "$TEMP_DIR"
  [ "$TRACKER_CONFIG_TRACKER" = "local" ]
  [ "$TRACKER_CONFIG_REPO" = "" ]
}

@test "tracker-config.sh defaults to local when the doc exists with no front matter" {
  write_doc $'# Issue tracker: Local Markdown\n\nIssues live in `.scratch/`.\n'
  source "$SCRIPT"
  read_tracker_config "$TEMP_DIR"
  [ "$TRACKER_CONFIG_TRACKER" = "local" ]
  [ "$TRACKER_CONFIG_REPO" = "" ]
}

@test "tracker-config.sh reads tracker: local from front matter" {
  write_doc $'---\ntracker: local\n---\n\n# Issue tracker\n'
  source "$SCRIPT"
  read_tracker_config "$TEMP_DIR"
  [ "$TRACKER_CONFIG_TRACKER" = "local" ]
  [ "$TRACKER_CONFIG_REPO" = "" ]
}

@test "tracker-config.sh reads tracker: github with a repo override" {
  write_doc $'---\ntracker: github\nrepo: owner/name\n---\n\n# Issue tracker\n'
  source "$SCRIPT"
  read_tracker_config "$TEMP_DIR"
  [ "$TRACKER_CONFIG_TRACKER" = "github" ]
  [ "$TRACKER_CONFIG_REPO" = "owner/name" ]
}

@test "tracker-config.sh reads tracker: github with no repo line as empty repo" {
  write_doc $'---\ntracker: github\n---\n\n# Issue tracker\n'
  source "$SCRIPT"
  read_tracker_config "$TEMP_DIR"
  [ "$TRACKER_CONFIG_TRACKER" = "github" ]
  [ "$TRACKER_CONFIG_REPO" = "" ]
}

@test "tracker-config.sh run directly prints tracker and repo" {
  write_doc $'---\ntracker: github\nrepo: owner/name\n---\n\n# Issue tracker\n'
  run bash "$SCRIPT" "$TEMP_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracker=github"* ]]
  [[ "$output" == *"repo=owner/name"* ]]
}
