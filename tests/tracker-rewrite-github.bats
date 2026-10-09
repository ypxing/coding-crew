#!/usr/bin/env bats

# cli.mjs rewrite — github backend.
#
# rewrite sets the slice's status as the issue's only triage label: it reads the issue's labels,
# then removes every other triage label the issue carries in the same `gh issue edit` that adds the
# status. `gh` is stubbed on PATH: these tests pin argument shape and exit codes.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  export MAIN_ROOT="$TEMP_DIR"

  mkdir -p "$MAIN_ROOT/.coding-crew/docs"
  cat > "$MAIN_ROOT/.coding-crew/docs/issue-tracker.md" <<'EOF'
---
tracker: github
---

# Issue tracker: GitHub Issues
EOF
  cp -R "$REPO_ROOT/tracker" "$MAIN_ROOT/.coding-crew/tracker"
  unset CREW_TRACKER_CLI CREW_INSTALL_DIR

  STUB="$TEMP_DIR/.stub"
  mkdir -p "$STUB"
  export PATH="$STUB:$PATH"

  GH_LOG="$TEMP_DIR/gh.log"
  GH_LABELS="$TEMP_DIR/labels.txt"
  export GH_LOG GH_LABELS
  : > "$GH_LOG"
  : > "$GH_LABELS"

  printf '# Title\n\nStatus: needs-triage\n\nBody text.\n' > "$TEMP_DIR/body.md"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

# stub_gh [view-exit] [view-stderr] — logs every call; `issue view` prints $GH_LABELS (one label
# per line) or fails with the given exit and stderr; the milestone api calls succeed.
stub_gh() {
  local view_rc="${1:-0}" view_err="${2:-}"
  cat > "$STUB/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_LOG"
case "\$1 \$2" in
  "issue view")
    if [ $view_rc -ne 0 ]; then printf '%s\n' "$view_err" >&2; exit $view_rc; fi
    cat "$GH_LABELS"
    exit 0
    ;;
  "issue edit") exit 0 ;;
esac
if [ "\$1" = "api" ]; then printf '5\topen\tfeat\n'; exit 0; fi
exit 1
EOF
  chmod +x "$STUB/gh"
  export CREW_FAKE_GH="$STUB/gh"
}

rewrite() {
  node "$MAIN_ROOT/.coding-crew/tracker/cli.mjs" rewrite 42 --body-file "$TEMP_DIR/body.md" \
    --status "$1" --feature-slug feat --main-root "$MAIN_ROOT"
}

edit_call() { grep '^issue edit' "$GH_LOG" || true; }

@test "rewrite (github): ready-for-agent replaces needs-info as the only triage label" {
  stub_gh
  printf 'needs-info\n' > "$GH_LABELS"

  run rewrite ready-for-agent
  [ "$status" -eq 0 ]
  call="$(edit_call)"
  [[ "$call" == *"--remove-label needs-info"* ]]
  [[ "$call" == *"--add-label ready-for-agent"* ]]
  [[ "$call" != *"--remove-label needs-triage"* ]]
  [[ "$call" != *"--remove-label ready-for-human"* ]]
}

@test "rewrite (github): ready-for-human replaces ready-for-agent" {
  stub_gh
  printf 'ready-for-agent\n' > "$GH_LABELS"

  run rewrite ready-for-human
  [ "$status" -eq 0 ]
  call="$(edit_call)"
  [[ "$call" == *"--remove-label ready-for-agent"* ]]
  [[ "$call" == *"--add-label ready-for-human"* ]]
}

@test "rewrite (github): needs-triage still comes off" {
  stub_gh
  printf 'needs-triage\n' > "$GH_LABELS"

  run rewrite ready-for-agent
  [ "$status" -eq 0 ]
  [[ "$(edit_call)" == *"--remove-label needs-triage"* ]]
}

@test "rewrite (github): a non-triage label is never removed" {
  stub_gh
  printf 'needs-design\nblocked\nneeds-info\n' > "$GH_LABELS"

  run rewrite ready-for-agent
  [ "$status" -eq 0 ]
  call="$(edit_call)"
  [[ "$call" != *"needs-design"* ]]
  [[ "$call" != *"blocked"* ]]
}

@test "rewrite (github): names no --remove-label when the issue carries no other triage label" {
  stub_gh
  printf 'needs-design\n' > "$GH_LABELS"

  run rewrite ready-for-agent
  [ "$status" -eq 0 ]
  call="$(edit_call)"
  [[ "$call" != *"--remove-label"* ]]
  [[ "$call" == *"--add-label ready-for-agent"* ]]
}

@test "rewrite (github): an issue already carrying the status does not have it removed" {
  stub_gh
  printf 'ready-for-agent\nneeds-info\n' > "$GH_LABELS"

  run rewrite ready-for-agent
  [ "$status" -eq 0 ]
  call="$(edit_call)"
  [[ "$call" != *"--remove-label ready-for-agent"* ]]
  [[ "$call" == *"--remove-label needs-info"* ]]
}

@test "rewrite (github): a label read on a missing issue exits 3" {
  stub_gh 1 "GraphQL: Could not resolve to an issue or pull request with the number of 42."

  run rewrite ready-for-agent
  [ "$status" -eq 3 ]
  [ -z "$(edit_call)" ]
}

@test "rewrite (github): any other label-read failure exits 1 with gh's stderr" {
  stub_gh 1 "HTTP 502: bad gateway"

  run rewrite ready-for-agent
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 502: bad gateway"* ]]
  [ -z "$(edit_call)" ]
}
