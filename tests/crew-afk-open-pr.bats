#!/usr/bin/env bats

# open-pr.sh — push the feature branch, then create or update its PR. A real bare repo is
# the remote; `gh` is stubbed on PATH and keeps the one PR it knows in $GH_PR (a JSON file),
# so a create followed by an edit behaves like the real thing.

OPEN_PR="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)/skills/crew-afk/scripts/open-pr.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  git init -q --bare "$TEMP_DIR/remote.git"
  export MAIN_ROOT="$TEMP_DIR/repo"
  git init -q -b main "$MAIN_ROOT"
  cd "$MAIN_ROOT"
  git config user.email t@test
  git config user.name T
  git commit -q --allow-empty -m init
  git remote add origin "$TEMP_DIR/remote.git"
  git push -q origin main
  git checkout -q -b feature/demo
  git commit -q --allow-empty -m "issue work"

  export FEATURE_BRANCH=feature/demo FEATURE_SLUG=demo
  unset TRACE_LOG
  export GH_LOG="$TEMP_DIR/gh.log" GH_PR="$TEMP_DIR/pr.json"
  : > "$GH_LOG"

  mkdir -p "$TEMP_DIR/stub"
  cat > "$TEMP_DIR/stub/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
arg() { local k=$1; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { echo "$2"; return; }; shift; done; }
case "$1 $2" in
  "pr view")
    [ -f "$GH_PR" ] || { echo "no pull requests found" >&2; exit 1; }
    cat "$GH_PR" ;;
  "pr create")
    [[ -n "${GH_DRAFT_UNSUPPORTED:-}" && "$*" == *--draft* ]] && { echo "Draft pull requests are not supported in this repository" >&2; exit 1; }
    [ -z "${GH_CREATE_FAIL:-}" ] || { echo "HTTP 502: bad gateway" >&2; exit 1; }
    jq -n --rawfile body "$(arg --body-file "$@")" --arg title "$(arg --title "$@")" --argjson d "$([[ "$*" == *--draft* ]] && echo true || echo false)" \
      '{url: "https://github.com/o/r/pull/7", state: "OPEN", body: $body, title: $title, isDraft: $d}' > "$GH_PR"
    echo "https://github.com/o/r/pull/7" ;;
  "pr ready")
    [ -z "${GH_READY_FAIL:-}" ] || { echo "ready boom" >&2; exit 1; }
    if [[ "$*" == *--undo* ]]; then d=true; else d=false; fi
    jq --argjson d "$d" '.isDraft = $d' "$GH_PR" > "$GH_PR.new" && mv "$GH_PR.new" "$GH_PR" ;;
  "label create") exit 0 ;;
  "pr edit")
    [[ "$*" == *--body-file* ]] || exit 0
    jq --rawfile body "$(arg --body-file "$@")" '.body = $body' "$GH_PR" > "$GH_PR.new" && mv "$GH_PR.new" "$GH_PR"
    [[ "$*" == *--title* ]] || exit 0
    jq --arg title "$(arg --title "$@")" '.title = $title' "$GH_PR" > "$GH_PR.new" && mv "$GH_PR.new" "$GH_PR" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$TEMP_DIR/stub/gh"
  export PATH="$TEMP_DIR/stub:$PATH"

  printf 'Closes #1\nCloses #2\n' > "$TEMP_DIR/closes.txt"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

pr_body() { jq -r .body "$GH_PR"; }

@test "open-pr: pushes the feature branch and creates a PR whose body closes the issues" {
  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR: https://github.com/o/r/pull/7"* ]]
  [ "$(git -C "$TEMP_DIR/remote.git" rev-parse feature/demo)" = "$(git rev-parse HEAD)" ]
  grep -q '^pr create --head feature/demo --title demo' "$GH_LOG"
  pr_body | grep -qx 'Closes #1'
  pr_body | grep -qx 'Closes #2'
}

@test "open-pr: a re-run replaces only crew-afk's block and keeps what a human wrote" {
  bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt" >/dev/null
  jq --arg b "Human summary.

$(pr_body)

Reviewer notes." '.body = $b' "$GH_PR" > "$GH_PR.new" && mv "$GH_PR.new" "$GH_PR"
  printf 'Closes #1\nCloses #2\nCloses #3\n' > "$TEMP_DIR/closes.txt"

  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -eq 0 ]
  grep -q '^pr edit feature/demo' "$GH_LOG"
  [ "$(grep -c '^pr create' "$GH_LOG")" -eq 1 ]
  pr_body | grep -qx 'Human summary.'
  pr_body | grep -qx 'Reviewer notes.'
  pr_body | grep -qx 'Closes #3'
  [ "$(pr_body | grep -c 'crew-afk:begin')" -eq 1 ]
}

@test "open-pr: a CRLF body (edited in GitHub's web UI) still has its block replaced" {
  bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt" >/dev/null
  jq --arg b "$(printf 'Human summary.\n\n%s\n\nReviewer notes.' "$(pr_body)" | sed 's/$/\r/')" \
    '.body = $b' "$GH_PR" > "$GH_PR.new" && mv "$GH_PR.new" "$GH_PR"
  printf 'Closes #1\nCloses #2\nCloses #3\n' > "$TEMP_DIR/closes.txt"

  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -eq 0 ]
  pr_body | tr -d '\r' | grep -qx 'Human summary.'
  pr_body | tr -d '\r' | grep -qx 'Reviewer notes.'
  pr_body | grep -qx 'Closes #3'
  [ "$(pr_body | grep -c 'crew-afk:begin')" -eq 1 ]
}

@test "open-pr: an open PR without the block gets it appended" {
  jq -n '{url: "https://github.com/o/r/pull/7", state: "OPEN", body: "Opened by hand."}' > "$GH_PR"

  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -eq 0 ]
  pr_body | grep -qx 'Opened by hand.'
  pr_body | grep -qx 'Closes #1'
}

@test "open-pr: a merged PR for the branch is not edited - a new one is created" {
  jq -n '{url: "https://github.com/o/r/pull/3", state: "MERGED", body: "old"}' > "$GH_PR"

  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -eq 0 ]
  grep -q '^pr create' "$GH_LOG"
  ! grep -q '^pr edit.*--body-file' "$GH_LOG"
}

@test "open-pr: a rejected push fails before any PR call, and never forces" {
  # The remote's branch has a commit this one lacks: a plain push is non-fast-forward.
  git push -q origin feature/demo
  git commit -q --amend --allow-empty -m "rewritten"

  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git push failed"* ]]
  ! grep -q '^pr ' "$GH_LOG"
}

# crew-rework is parked: an optional template a human installs and labels for, so open-pr
# never arms it.
@test "open-pr: a new PR gets no crew-rework label" {
  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -eq 0 ]
  ! grep -q 'crew-rework' "$GH_LOG"
}

@test "open-pr: an updated PR gets no crew-rework label" {
  jq -n '{url: "https://github.com/o/r/pull/7", state: "OPEN", body: "Opened by hand."}' > "$GH_PR"
  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -eq 0 ]
  ! grep -q 'crew-rework' "$GH_LOG"
}

@test "open-pr: --body-file opens the block, above the sprint line and the closing lines" {
  printf '## Summary\n\nWhat changed.\n' > "$TEMP_DIR/body.md"
  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt" --body-file "$TEMP_DIR/body.md"
  [ "$status" -eq 0 ]
  [ "$(pr_body | sed -n 2p)" = "## Summary" ]
  pr_body | grep -qx 'What changed.'
  [ "$(pr_body | grep -n '^## Summary' | cut -d: -f1)" -lt "$(pr_body | grep -n '^Implemented by' | cut -d: -f1)" ]
  [ "$(pr_body | grep -n '^Implemented by' | cut -d: -f1)" -lt "$(pr_body | grep -n '^Closes #1' | cut -d: -f1)" ]
}

@test "open-pr: a marker line inside --body-file is dropped, so a re-run still finds the block's end" {
  printf '## Summary\n\n<!-- crew-afk:end -->\ntail\n' > "$TEMP_DIR/body.md"
  bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt" --body-file "$TEMP_DIR/body.md" >/dev/null
  [ "$(pr_body | grep -c 'crew-afk:end')" -eq 1 ]
  jq --arg b "$(pr_body)

Reviewer notes." '.body = $b' "$GH_PR" > "$GH_PR.new" && mv "$GH_PR.new" "$GH_PR"

  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt" --body-file "$TEMP_DIR/body.md"
  [ "$status" -eq 0 ]
  pr_body | grep -qx 'Reviewer notes.'
  [ "$(pr_body | grep -c '^tail$')" -eq 1 ]
}

@test "open-pr: --title names a new PR; an open one keeps a title a human gave it" {
  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt" --title "Single full check"
  [ "$status" -eq 0 ]
  grep -q '^pr create --head feature/demo --title Single full check' "$GH_LOG"
  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt" --title "Other"
  [ "$status" -eq 0 ]
  ! grep -q -- '--title Other' "$GH_LOG"
  [ "$(jq -r .title "$GH_PR")" = "Single full check" ]
}

@test "open-pr: an open PR still titled with the slug (the old default) gets --title" {
  jq -n '{url: "https://github.com/o/r/pull/7", state: "OPEN", body: "", title: "demo"}' > "$GH_PR"
  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt" --title "Run the full suite once per branch"
  [ "$status" -eq 0 ]
  [ "$(jq -r .title "$GH_PR")" = "Run the full suite once per branch" ]
}

@test "open-pr: no --title leaves an open PR's title alone" {
  jq -n '{url: "https://github.com/o/r/pull/7", state: "OPEN", body: "", title: "demo"}' > "$GH_PR"
  run bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -eq 0 ]
  ! grep -q -- '--title' "$GH_LOG"
}

@test "open-pr --draft: a new PR is created as a draft" {
  run bash "$OPEN_PR" --draft --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -eq 0 ]
  grep -q '^pr create --draft ' "$GH_LOG"
  [[ "$output" == *"PR-STATE: draft"* ]]
}

@test "open-pr --draft: an open ready PR is converted to draft" {
  bash "$OPEN_PR"
  run bash "$OPEN_PR" --draft
  [ "$status" -eq 0 ]
  grep -q '^pr ready --undo' "$GH_LOG"
  [ "$(jq -r .isDraft "$GH_PR")" = true ]
}

@test "open-pr without --draft: an open draft PR is marked ready; a new one is created ready" {
  run bash "$OPEN_PR"
  ! grep -q -- '--draft' "$GH_LOG"
  [[ "$output" == *"PR-STATE: ready"* ]]
  bash "$OPEN_PR" --draft
  run bash "$OPEN_PR"
  [ "$status" -eq 0 ]
  grep -qx 'pr ready feature/demo' "$GH_LOG"
  [ "$(jq -r .isDraft "$GH_PR")" = false ]
}

@test "open-pr: a failed gh pr ready is reported and does not fail the script" {
  bash "$OPEN_PR"
  GH_READY_FAIL=1 run bash "$OPEN_PR" --draft
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR-STATE-FAILED: gh pr ready --undo failed: ready boom"* ]]
  [[ "$output" == *"PR-STATE: ready"* ]]
}

@test "open-pr --draft where drafts are unsupported: the PR is created ready and the failure is reported" {
  GH_DRAFT_UNSUPPORTED=1 run bash "$OPEN_PR" --draft --closes-file "$TEMP_DIR/closes.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR: https://github.com/o/r/pull/7"* ]]
  [[ "$output" == *"PR-STATE: ready"* ]]
  [[ "$output" == *"PR-STATE-FAILED: gh pr create --draft failed: Draft pull requests are not supported"* ]]
}

@test "open-pr --no-push --draft: an open ready PR becomes a draft; its body and closing lines stay; nothing is pushed" {
  bash "$OPEN_PR" --closes-file "$TEMP_DIR/closes.txt"
  body_before=$(jq -r .body "$GH_PR")
  before=$(git ls-remote origin refs/heads/feature/demo | cut -f1)
  git commit -q --allow-empty -m "red work"
  run bash "$OPEN_PR" --no-push --draft
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR-STATE: draft"* ]]
  [ "$(jq -r .isDraft "$GH_PR")" = true ]
  [ "$(jq -r .body "$GH_PR")" = "$body_before" ]
  [[ "$body_before" == *"Closes #1"* ]]
  [ "$(git ls-remote origin refs/heads/feature/demo | cut -f1)" = "$before" ]
}

@test "open-pr --draft: a create that fails for another reason fails the script, not a ready PR" {
  GH_CREATE_FAIL=1 run bash "$OPEN_PR" --draft
  [ "$status" -ne 0 ]
  ! grep -q '^pr create --head' "$GH_LOG"
}

@test "open-pr --no-push with no open PR creates none" {
  run bash "$OPEN_PR" --no-push --draft
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR: none"* ]]
  ! grep -q '^pr create' "$GH_LOG"
}

@test "open-pr --note-file: the note is inside the markers and text outside survives" {
  bash "$OPEN_PR"
  jq '.body = "intro\n\n" + .body + "\n\noutro"' "$GH_PR" > "$GH_PR.n" && mv "$GH_PR.n" "$GH_PR"
  printf '**Not green:** x\n- 01-a\n' > "$TEMP_DIR/note.md"
  run bash "$OPEN_PR" --draft --note-file "$TEMP_DIR/note.md"
  [ "$status" -eq 0 ]
  pr_body | sed -n '/crew-afk:begin/,/crew-afk:end/p' | grep -qx -- '- 01-a'
  pr_body | grep -qx intro
  pr_body | grep -qx outro
  bash "$OPEN_PR"
  ! pr_body | grep -q -- '- 01-a'
}
