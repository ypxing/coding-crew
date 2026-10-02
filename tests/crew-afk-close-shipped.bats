#!/usr/bin/env bats

# close-shipped.sh — close a feature's awaiting-merge issues (then its PRD) once a merged PR's
# body names them, without relying on GitHub having linked the `Closes #n` lines. `gh` is
# stubbed on PATH: `pr list` prints $GH_PRS, `issue list` prints $GH_ISSUES, and every call is
# logged to $GH_LOG.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
CLOSE_SHIPPED="$REPO_ROOT/skills/crew-afk/scripts/close-shipped.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  export HOME="$TEMP_DIR/home"
  mkdir -p "$HOME"
  export MAIN_ROOT="$TEMP_DIR/repo"
  mkdir -p "$MAIN_ROOT/.coding-crew/docs" "$TEMP_DIR/install/scripts"
  printf -- '---\ntracker: github\n---\n' > "$MAIN_ROOT/.coding-crew/docs/issue-tracker.md"
  cp "$REPO_ROOT/scripts/tracker/tracker-config.sh" "$TEMP_DIR/install/scripts/"
  unset CREW_TRACKER_CONFIG
  export CREW_INSTALL_DIR="$TEMP_DIR/install"

  export GH_LOG="$TEMP_DIR/gh.log" GH_PRS="$TEMP_DIR/prs.json" GH_ISSUES="$TEMP_DIR/issues.json"
  : > "$GH_LOG"
  echo '[]' > "$GH_PRS"
  echo '[]' > "$GH_ISSUES"
  mkdir -p "$TEMP_DIR/stub"
  cat > "$TEMP_DIR/stub/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "repo view") echo "o/r main" ;;
  "pr list") cat "$GH_PRS" ;;
  "issue list")
    [ -n "${GH_NO_MILESTONE:-}" ] && { echo 'could not add to milestone: not found' >&2; exit 1; }
    cat "$GH_ISSUES" ;;
  "issue view")
    case "$*" in
      *"--json body"*) [ -n "${GH_FAIL_VIEW:-}" ] && { echo nope >&2; exit 1; }; cat "$TEMP_DIR/body.$3" 2>/dev/null || true ;;
      *"--json state"*) cat "$TEMP_DIR/state.$3" 2>/dev/null || echo OPEN ;;
    esac ;;
  "issue close") [ "${GH_FAIL_CLOSE_N:-}" = "$3" ] && { echo denied >&2; exit 1; }; [ -n "${GH_FAIL_CLOSE:-}" ] && { echo denied >&2; exit 1; }; exit 0 ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TEMP_DIR/stub/gh"
  export PATH="$TEMP_DIR/stub:$PATH"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

issue() { # <number> <title> [label…]
  local n=$1 t=$2; shift 2
  jq -c -n --argjson n "$n" --arg t "$t" '{number: $n, title: $t, labels: ($ARGS.positional | map({name: .}))}' --args "$@"
}
issues() { printf '%s\n' "$@" | jq -s . > "$GH_ISSUES"; }
merged_pr() { # <number> <base> <body>
  jq --argjson n "$1" --arg base "$2" --arg body "$3" '. + [{number: $n, baseRefName: $base, body: $body}]' "$GH_PRS" > "$GH_PRS.new"
  mv "$GH_PRS.new" "$GH_PRS"
}

@test "close-shipped: closes each awaiting-merge issue a merged PR names, then the PRD" {
  issues "$(issue 48 'PRD: lease')" "$(issue 49 'lease' awaiting-merge)" "$(issue 50 'blocked label' awaiting-merge)"
  merged_pr 57 main $'Feature (#49, #50).\n\nCloses #49\nfixes: #50\n'
  run bash "$CLOSE_SHIPPED" demo feature/demo
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLOSED: #49 (PR #57)"* ]]
  [[ "$output" == *"CLOSED: #50 (PR #57)"* ]]
  [[ "$output" == *"CLOSED: PRD #48"* ]]
  [[ "$output" == *"SHIPPED: 2"* ]]
  grep -q '^pr list --head feature/demo --state merged' "$GH_LOG"
  grep -q '^issue list --milestone demo --state open' "$GH_LOG"
  grep -q '^issue close 49 --reason completed --comment Shipped in #57' "$GH_LOG"
  grep -q '^issue close 48 --reason completed' "$GH_LOG"
}

@test "close-shipped: an awaiting-merge issue no merged PR names stays open, and so does the PRD" {
  issues "$(issue 48 'PRD: lease')" "$(issue 49 'lease' awaiting-merge)" "$(issue 60 'later work' awaiting-merge)"
  merged_pr 57 main 'Closes #49'
  run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHIPPED: 1"* ]]
  ! grep -q '^issue close 60' "$GH_LOG"
  ! grep -q '^issue close 48' "$GH_LOG"
}

@test "close-shipped: an issue not yet implemented keeps the PRD open, even when the PR names it" {
  issues "$(issue 48 'PRD: lease')" "$(issue 49 'lease' ready-for-agent)"
  merged_pr 57 main 'Closes #49'
  run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHIPPED: 0"* ]]
  ! grep -q '^issue close' "$GH_LOG"
}

@test "close-shipped: no merged PR closes nothing, not even a PRD with no work issues" {
  issues "$(issue 48 'PRD: lease')"
  run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHIPPED: 0"* ]]
  ! grep -q '^issue close' "$GH_LOG"
}

@test "close-shipped: a PR merged into a branch other than the default ships nothing" {
  issues "$(issue 49 'lease' awaiting-merge)"
  merged_pr 57 release 'Closes #49'
  run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 0 ]
  ! grep -q '^issue close' "$GH_LOG"
}

@test "close-shipped: a bare mention is not a closing keyword" {
  issues "$(issue 49 'lease' awaiting-merge)"
  merged_pr 57 main 'Covers #49. Closes #490'
  run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 0 ]
  ! grep -q '^issue close' "$GH_LOG"
}

@test "close-shipped: reads the issue URL and owner/repo#n forms, CRLF bodies included, for this repo only" {
  issues "$(issue 49 'a' awaiting-merge)" "$(issue 50 'b' awaiting-merge)" "$(issue 51 'c' awaiting-merge)"
  merged_pr 57 main $'Closes https://github.com/O/R/issues/49\r\nResolves o/r#50\r\nCloses other/repo#51\r\n'
  run bash "$CLOSE_SHIPPED" demo feature/demo
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLOSED: #49 (PR #57)"* ]]
  [[ "$output" == *"CLOSED: #50 (PR #57)"* ]]
  ! grep -q '^issue close 51' "$GH_LOG"
}

@test "close-shipped: a milestone that does not exist yet is nothing to close" {
  export GH_NO_MILESTONE=1
  run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"SHIPPED: 0"* ]]
}

@test "close-shipped: a failed close exits 1, and the PRD stays open" {
  export GH_FAIL_CLOSE=1
  issues "$(issue 48 'PRD: lease')" "$(issue 49 'lease' awaiting-merge)"
  merged_pr 57 main 'Closes #49'
  run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 1 ]
  [ "$(grep -c '^issue close' "$GH_LOG")" -eq 1 ]
}

@test "close-shipped: tracker local touches nothing" {
  printf -- '---\ntracker: local\n---\n' > "$MAIN_ROOT/.coding-crew/docs/issue-tracker.md"
  run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GH_LOG" ]
}

@test "close-shipped: both arguments are required" {
  run bash "$CLOSE_SHIPPED" demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "close-shipped: closes Origin: issues with the PRD, skips a closed one, names PRD and PR" {
  issues "$(issue 48 'PRD: lease')" "$(issue 49 'lease' awaiting-merge)"
  printf 'Actor: dev\nOrigin: #7, #8\n\nbody\n' > "$TEMP_DIR/body.48"
  echo CLOSED > "$TEMP_DIR/state.8"
  merged_pr 57 main 'Closes #49'
  run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLOSED: origin #7 (PRD #48)"* ]]
  [[ "$output" != *"origin #8"* ]]
  grep -q '^issue close 7 --reason completed --comment Closed with PRD #48, shipped in PR #57' "$GH_LOG"
  ! grep -q '^issue close 8 ' "$GH_LOG"
}

@test "close-shipped: Origin: issues stay open while the PRD stays open" {
  issues "$(issue 48 'PRD: lease')" "$(issue 49 'lease' awaiting-merge)" "$(issue 60 'later' awaiting-merge)"
  printf 'Origin: #7\n' > "$TEMP_DIR/body.48"
  merged_pr 57 main 'Closes #49'
  run bash "$CLOSE_SHIPPED" demo feature/demo
  ! grep -q '^issue close 7 ' "$GH_LOG"
}

@test "close-shipped: a failed Origin close still closes the PRD and exits 1" {
  issues "$(issue 48 'PRD: lease')" "$(issue 49 'lease' awaiting-merge)"
  printf 'Origin: #7\n' > "$TEMP_DIR/body.48"
  merged_pr 57 main 'Closes #49'
  GH_FAIL_CLOSE_N=7 run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh issue close failed for origin #7"* ]]
  [[ "$output" == *"CLOSED: PRD #48"* ]]
}

@test "close-shipped: a failed PRD body read is reported, exit 1, PRD still closes" {
  issues "$(issue 48 'PRD: lease')" "$(issue 49 'lease' awaiting-merge)"
  merged_pr 57 main 'Closes #49'
  GH_FAIL_VIEW=1 run bash "$CLOSE_SHIPPED" demo feature/demo
  [ "$status" -eq 1 ]
  [[ "$output" == *"gh issue view failed for PRD #48"* ]]
  [[ "$output" == *"CLOSED: PRD #48"* ]]
}
