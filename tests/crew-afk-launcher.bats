#!/usr/bin/env bats

# The pi cutover: crew-afk's orchestrator is a program, and pi's SKILL.md is a launcher.
#
# What these tests protect is the boundary. A launcher that starts re-describing the
# pipeline is a second orchestrator, which is exactly the drift the shared-body work was
# meant to end — and a program that ships without its runtime, or with its test suite, is
# either dead on arrival or installed weight no agent runs.
#
# The behaviour the deleted prose described is asserted against the code in
# tests/orchestrator/*.test.mjs, not here.

load helpers/render

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
}

setup() {
  AFK_DIR="$REPO_ROOT/skills/crew-afk"
  BODY="$AFK_DIR/pi.SKILL.md"
}

# ─── the launcher ────────────────────────────────────────────────────────────

@test "launcher: pi has its own body and no longer renders the shared prose one" {
  [ -f "$BODY" ]
  run jq -r '.skills["crew-afk"].body.pi // "none"' "$REPO_ROOT/registry.json"
  [ "$output" = "none" ]
}

@test "launcher: it launches the program and says it does not orchestrate" {
  grep -q 'main.mjs" run --platform pi' "$BODY"
  grep -qi 'you do not orchestrate' "$BODY"
}

@test "launcher: it stays a launcher — no pipeline, no state, no receipts prose" {
  # Each of these was a step the body used to perform. Naming the pipeline once, as the
  # program's contract, is fine; issuing its commands is not.
  ! grep -q 'state.sh' "$BODY"
  ! grep -q 'receipts.sh' "$BODY"
  ! grep -q 'merge-branches.sh' "$BODY"
  ! grep -q 'close-issue.sh' "$BODY"
  ! grep -q 'promote-findings.sh' "$BODY"
  ! grep -q 'verify-worktree.sh' "$BODY"
  ! grep -q 'git worktree add' "$BODY"
}

@test "launcher: it is under 500 words (it replaced ~2,400)" {
  local words
  words=$(wc -w < "$BODY")
  [ "$words" -lt 500 ] || { echo "pi launcher is $words words" >&2; return 1; }
}

@test "launcher: it maps every exit code the program can return" {
  for code in 0 2 3 1; do
    grep -q "\`$code\`" "$BODY" || { echo "exit code $code unexplained" >&2; return 1; }
  done
}

@test "launcher: it forbids finishing a failed sprint by hand" {
  grep -qi 'never finish the sprint by hand' "$BODY"
  grep -qi 'receipt gates' "$BODY"
}

@test "launcher: pi's dispatcher script is still shipped (the adapter runs it)" {
  run jq -r '.skills["crew-afk"]["platform-files"].pi[]' "$REPO_ROOT/registry.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scripts/dispatch-agent.sh"* ]]
}

# ─── the program's install ───────────────────────────────────────────────────

@test "assets: registry declares the orchestrator at a platform-neutral path" {
  run jq -r '.skills["crew-afk"].assets.source' "$REPO_ROOT/registry.json"
  [ "$output" = "orchestrator" ]
  run jq -r '.skills["crew-afk"].assets.dest' "$REPO_ROOT/registry.json"
  [ "$output" = ".coding-crew/crew-afk" ]
}

@test "assets: install ships the runtime and nothing else" {
  local target="$BATS_TEST_TMPDIR/target"
  mkdir -p "$target"
  git -C "$target" init -q -b main
  TARGET_REPO="$target" run bash "$REPO_ROOT/install.sh" pi --skill crew-afk
  [ "$status" -eq 0 ]

  [ -f "$target/.coding-crew/crew-afk/main.mjs" ]
  [ -f "$target/.coding-crew/crew-afk/lib/pipeline.mjs" ]
  [ -f "$target/.coding-crew/crew-afk/lib/dispatch.mjs" ]
  # A test suite in a consumer repo is installed weight no agent runs.
  [ ! -d "$target/.coding-crew/crew-afk/test" ]
  run bash -c "find '$target/.coding-crew/crew-afk' -name '*.test.mjs' | wc -l"
  [ "$(echo "$output" | tr -d ' ')" = "0" ]
}

@test "assets: the orchestrator installs once, not once per platform" {
  local target="$BATS_TEST_TMPDIR/target-all"
  mkdir -p "$target"
  git -C "$target" init -q -b main
  TARGET_REPO="$target" run bash "$REPO_ROOT/install.sh" all --skill crew-afk
  [ "$status" -eq 0 ]
  # One copy, at the neutral path — not one per platform skill dir.
  run bash -c "find '$target' -name 'main.mjs' -path '*crew-afk*' | wc -l"
  [ "$(echo "$output" | tr -d ' ')" = "1" ]
}

@test "assets: install overwrites a stale orchestrator" {
  local target="$BATS_TEST_TMPDIR/target-stale"
  mkdir -p "$target/.coding-crew/crew-afk"
  git -C "$target" init -q -b main
  echo "stale" > "$target/.coding-crew/crew-afk/main.mjs"
  TARGET_REPO="$target" run bash "$REPO_ROOT/install.sh" pi --skill crew-afk
  [ "$status" -eq 0 ]
  ! grep -q '^stale$' "$target/.coding-crew/crew-afk/main.mjs"
}

@test "assets: uninstall removes the orchestrator" {
  local target="$BATS_TEST_TMPDIR/target-uninstall"
  mkdir -p "$target"
  git -C "$target" init -q -b main
  TARGET_REPO="$target" bash "$REPO_ROOT/install.sh" pi --skill crew-afk >/dev/null
  [ -f "$target/.coding-crew/crew-afk/main.mjs" ]
  TARGET_REPO="$target" run bash "$REPO_ROOT/uninstall.sh" --skill crew-afk
  [ "$status" -eq 0 ]
  [ ! -d "$target/.coding-crew/crew-afk" ]
}

@test "assets: the installed orchestrator resolves its own scripts dir" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  local target="$BATS_TEST_TMPDIR/target-run"
  mkdir -p "$target"
  git -C "$target" init -q -b main
  git -C "$target" config user.email t@test
  git -C "$target" config user.name T
  TARGET_REPO="$target" bash "$REPO_ROOT/install.sh" pi --skill crew-afk >/dev/null
  echo "x" > "$target/README.md"
  git -C "$target" add -A
  git -C "$target" commit -qm init
  mkdir -p "$target/.scratch/demo/issues/open"
  printf '# widget\n\nStatus: ready-for-agent\n\n## Acceptance criteria\n\n- [ ] exists\n' \
    > "$target/.scratch/demo/issues/open/01-widget.md"
  cd "$target"
  run node .coding-crew/crew-afk/main.mjs plan --platform pi
  [ "$status" -eq 0 ]
  [[ "$output" == *"widget"* ]]
  # It found the bash mechanism layer inside the installed skill, unaided.
  [[ "$output" == *".pi/skills/crew-afk/scripts"* ]]
}
