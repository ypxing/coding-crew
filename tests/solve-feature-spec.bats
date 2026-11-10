#!/usr/bin/env bats

# solve-feature.sh start --spec <file> --issue <n>: a host's one spec file published as the one-issue local feature
# issue-<n>, through the real local tracker (the node stub is removed), with CREW_PUBLISH=false. Setup and the other
# stubs: helpers/solve-feature.bash.

load helpers/solve-feature
bats_require_minimum_version 1.5.0

SCRATCH=.coding-crew/scratch/issue-13

# spec_setup — the real tracker CLI in place of the stub; CREW_PUBLISH=false; a spec file outside the checkout.
spec_setup() {
  cp -R "$REPO_ROOT/lib/tracker/." "$LIB/tracker/"
  rm "$STUB/node"
  export CREW_PUBLISH=false
  SPEC="$TEMP_DIR/spec.md"
  printf '# Add login\n\n## What to build\n\nA login form.\n\n## Acceptance criteria\n\n- [ ] logs in\n' > "$SPEC"
}
# no_tracker_config — the repo commits no .coding-crew/config.json.
no_tracker_config() {
  git rm -q .coding-crew/config.json && git commit -q -m "no tracker config" && git push -q origin main
}
cli() { node "$LIB/tracker/cli.mjs" "$@"; }

@test "start --spec with no user or tracker config and CREW_PUBLISH=false publishes issue-13 locally: next hands out 01-issue-13.md, nothing pushed, no PR call, a clean tree" {
  spec_setup; no_tracker_config
  [ ! -e "$HOME/.coding-crew/config.json" ]
  run bash "$SCRIPT" start --spec "$SPEC" --issue 13 --branch b
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "${lines[0]}" = slug=issue-13 ] || { echo "$output"; return 1; }
  [ "$(out branch)" = b ]
  run bash "$SCRIPT" next issue-13
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(basename "$output")" = 01-issue-13.md ] || { echo "$output"; return 1; }
  [ "$(head -n1 "$output")" = "# Add login" ]
  [ "$(git ls-remote --heads origin | cut -f2)" = refs/heads/main ]
  ! grep -q '^pr ' "$STATE/gh.log" 2>/dev/null || false
  [ -z "$(git status --porcelain)" ] || { git status --porcelain; return 1; }
}

@test "start --spec drops the spec's Blocked by section: one naming a draft filename and an issue number still publishes, and next hands it out" {
  spec_setup; no_tracker_config
  printf '\n## Blocked by\n\n- 01-other.md\n- #12\n' >> "$SPEC"
  run bash "$SCRIPT" start --spec "$SPEC" --issue 13 --branch b
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" next issue-13
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(basename "$output")" = 01-issue-13.md ]
  ! grep -qi 'blocked by' "$output" || false
  grep -qxF "A login form." "$output"
}

@test "start --spec drops the Blocked by section of a spec file with CRLF line endings too" {
  spec_setup; no_tracker_config
  printf '\n## Blocked by\n\n- 01-other.md\n' >> "$SPEC"
  awk '{ printf "%s\r\n", $0 }' "$SPEC" > "$SPEC.crlf" && mv "$SPEC.crlf" "$SPEC"
  run bash "$SCRIPT" start --spec "$SPEC" --issue 13 --branch b
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" next issue-13
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  ! grep -qi 'blocked by' "$output" || false
}

@test "a second start --spec for the same issue after the first was closed republishes the file's current text, and next hands it out" {
  spec_setup; no_tracker_config
  run bash "$SCRIPT" start --spec "$SPEC" --issue 13 --branch b
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" next issue-13; [ "$status" -eq 0 ]
  local ref="$output"
  cli tick "$ref" >/dev/null && cli mark-done "$ref" >/dev/null
  [ -z "$(ls "$SCRATCH/issues/open")" ]
  printf '# Add login\n\n## What to build\n\nA login form, second take.\n' > "$SPEC"
  run bash "$SCRIPT" start --spec "$SPEC" --issue 13 --branch b
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(ls "$SCRATCH/issues/open")" = 01-issue-13.md ]
  [ ! -d "$SCRATCH/issues/done" ] || [ -z "$(ls "$SCRATCH/issues/done")" ]
  grep -qxF "A login form, second take." "$SCRATCH/issues/open/01-issue-13.md"
  run bash "$SCRIPT" next issue-13
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$output" = "$ref" ]
}

@test "start --spec stops naming .coding-crew/scratch/issue-13/ when it has no marker of an earlier start --spec, and changes nothing under it" {
  spec_setup; no_tracker_config
  # Someone's feature, as the local tracker publishes one: its scratch/.gitignore keeps the tree clean.
  mkdir -p "$SCRATCH/issues/open" && echo '*' > .coding-crew/scratch/.gitignore
  printf '# Someone else\n\nStatus: ready-for-agent\n' > "$SCRATCH/issues/open/01-mine.md"
  echo '{}' > "$SCRATCH/issues/issues-deps.json"
  local before; before=$(cd "$SCRATCH" && find . -type f -exec cksum {} + | sort)
  run bash "$SCRIPT" start --spec "$SPEC" --issue 13 --branch b
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *".coding-crew/scratch/issue-13"* ]] || { echo "$output"; return 1; }
  [ "$(cd "$SCRATCH" && find . -type f -exec cksum {} + | sort)" = "$before" ]
}

@test "start --spec's stop on a directory no --rebuild made names it in the outcome line, for a host that reads only result.json" {
  spec_setup; no_tracker_config
  mkdir -p "$SCRATCH/issues/open" && echo '*' > .coding-crew/scratch/.gitignore
  printf '# Someone else\n\nStatus: ready-for-agent\n' > "$SCRATCH/issues/open/01-mine.md"
  run bash "$SCRIPT" start --spec "$SPEC" --issue 13 --branch b
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$(cat .coding-crew/solve-feature/outcome)" == "stopped: start failed: "*".coding-crew/scratch/issue-13"* ]] || {
    cat .coding-crew/solve-feature/outcome; return 1; }
}

@test "publish-spec.sh names no tracker path:the rebuild is the tracker CLI's publish-issues --rebuild" {
  run grep -n scratch "$REPO_ROOT/skills/solve-feature/scripts/publish-spec.sh"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  grep -q -- 'publish-issues .*--rebuild' "$REPO_ROOT/skills/solve-feature/scripts/publish-spec.sh"
}

@test "start --spec usage errors exit 2; a missing spec, one with no title, an untracked one in the checkout or the run's own spec.md exit 1 and publish nothing" {
  spec_setup; no_tracker_config
  local args
  for args in "--spec $SPEC" "--issue 13" "feat --spec $SPEC --issue 13" "--spec $SPEC --issue 1a" "--spec $SPEC --issue -1"; do
    run bash "$SCRIPT" start $args
    [ "$status" -eq 2 ] || { echo "'$args': status $status: $output"; return 1; }
    [[ "$output" == *usage:* ]] || { echo "'$args': $output"; return 1; }
  done
  run bash "$SCRIPT" start --spec "$TEMP_DIR/none.md" --issue 13
  [ "$status" -eq 1 ]; [[ "$output" == *"$TEMP_DIR/none.md"* ]] || { echo "$output"; return 1; }
  printf 'no title here\n' > "$TEMP_DIR/untitled.md"
  run bash "$SCRIPT" start --spec "$TEMP_DIR/untitled.md" --issue 13
  [ "$status" -eq 1 ]; [[ "$output" == *"$TEMP_DIR/untitled.md"* ]] || { echo "$output"; return 1; }
  cp "$SPEC" inside.md
  run bash "$SCRIPT" start --spec inside.md --issue 13
  [ "$status" -eq 1 ]; [[ "$output" == *"working tree is not clean"* ]] || { echo "$output"; return 1; }
  rm inside.md
  mkdir -p .coding-crew/solve-feature && cp "$SPEC" .coding-crew/solve-feature/spec.md
  run bash "$SCRIPT" start --spec .coding-crew/solve-feature/spec.md --issue 13
  [ "$status" -eq 1 ]; [[ "$output" == *".coding-crew/solve-feature/spec.md"*"own"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"unbound variable"* ]] || { echo "$output"; return 1; }
  [ "$(jq -r .status .coding-crew/solve-feature/result.json)" = stopped ]
  [ ! -e .coding-crew/scratch/issue-13 ]
  [ "$(git branch --show-current)" = main ]
}

@test "with a project tracker of github, CREW_TRACKER=local publishes locally with no gh issue call; without it start --spec stops naming CREW_TRACKER=local and creates nothing" {
  spec_setup
  [ "$(jq -r .tracker.kind .coding-crew/config.json)" = github ]
  [ "$(CREW_TRACKER=local cli config)" = "$(printf 'tracker=local\nconfigured=yes')" ]
  run bash "$SCRIPT" start --spec "$SPEC" --issue 13 --branch b
  [ "$status" -eq 1 ] || { echo "exit $status: $output"; return 1; }
  [[ "$output" == *"CREW_TRACKER=local"* ]] || { echo "$output"; return 1; }
  [ ! -e .coding-crew/scratch ]
  CREW_TRACKER=local run bash "$SCRIPT" start --spec "$SPEC" --issue 13 --branch b
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -f "$SCRATCH/issues/open/01-issue-13.md" ]
  ! grep -q '^issue' "$STATE/gh.log" 2>/dev/null || false
}

@test "start --spec --review-since on a branch holding earlier [01-issue-13] commits keeps them, and sync prints review-base=<sha>" {
  spec_setup; no_tracker_config
  git checkout -q -b b && echo w > w.txt && git add w.txt && git commit -q -m "[01-issue-13] work"
  local sha; sha=$(git rev-parse HEAD)
  git checkout -q main
  run bash "$SCRIPT" start --spec "$SPEC" --issue 13 --branch b --review-since "$sha"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git branch --show-current)" = b ]
  git merge-base --is-ancestor "$sha" HEAD
  [ "$(git log -1 --format=%s "$sha")" = "[01-issue-13] work" ]
  run bash "$SCRIPT" sync issue-13 b
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(out review-base)" = "$sha" ] || { echo "$output"; return 1; }
}

@test "start <slug> without --spec prints no slug= line" {
  run bash "$SCRIPT" start feat
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" != *slug=* ]] || { echo "$output"; return 1; }
}
