#!/usr/bin/env bats

# The launcher cutovers: crew-afk's orchestrator is a program, and every cut-over
# platform's SKILL.md is a launcher for it (pi, then codex).
#
# What these tests protect is the boundary. A launcher that starts re-describing the
# pipeline is a second orchestrator, which is exactly the drift the shared-body work was
# meant to end — and a program that ships without its runtime, or with its test suite, is
# either dead on arrival or installed weight no agent runs.
#
# The behaviour the deleted prose described is asserted against the code in
# tests/orchestrator/*.test.mjs, not here. Every body assertion runs over
# AFK_LAUNCHER_VARIANTS (every orchestrator/platforms.json entry), so a new platform needs no edit here
# and no copy of this file.

load helpers/render
load helpers/platforms

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
}

setup() {
  AFK_DIR="$REPO_ROOT/skills/crew-afk"
}

launcher_body() {
  afk_variant "$1"
}

# ─── the launchers ───────────────────────────────────────────────────────────

@test "launcher: at least one platform is cut over (the list is not silently empty)" {
  [ "${#AFK_LAUNCHER_VARIANTS[@]}" -ge 1 ]
}

@test "launcher: the four platforms render from one shared body, with no per-platform SKILL.md" {
  [ -f "$AFK_DIR/SKILL.md" ]
  for p in "${PLATFORMS[@]}"; do
    [ ! -e "$AFK_DIR/$p.SKILL.md" ] || { echo "$p.SKILL.md still exists" >&2; return 1; }
    [ -f "$(launcher_body "$p")" ] || { echo "$p does not render" >&2; return 1; }
    ! grep -q '{{' "$(launcher_body "$p")"
  done
}

@test "launcher: it launches the program for its own platform and does not orchestrate" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    body="$(launcher_body "$p")"
    # The path is resolved into a variable (repo copy, else the user-level install), so what
    # is asserted is that it runs *that* program for its own platform, not a literal path.
    grep -q 'coding-crew/crew-afk/main.mjs' "$body" || {
      echo "$p does not resolve the orchestrator's main.mjs" >&2; return 1; }
    grep -q "node \"\$CREW_AFK\" run --platform $p" "$body" || {
      echo "$p does not launch the orchestrator with --platform $p" >&2; return 1; }
    grep -qi 'you do not orchestrate' "$body"
  done
}

@test "launcher: the program lookup falls back to the main checkout's copy before the user-level install, for a linked worktree" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    body="$(launcher_body "$p")"
    fallback='[ -f "$CREW_AFK" ] || CREW_AFK="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")/.coding-crew/crew-afk/main.mjs"'
    grep -qF -- "$fallback" "$body" || { echo "$p: no main-checkout fallback line" >&2; return 1; }
    toplevel="$(grep -nF 'git rev-parse --show-toplevel)/.coding-crew/crew-afk/main.mjs' "$body" | head -1 | cut -d: -f1)"
    common="$(grep -nF -- "$fallback" "$body" | head -1 | cut -d: -f1)"
    home="$(grep -nF '$HOME/.coding-crew/crew-afk/main.mjs' "$body" | head -1 | cut -d: -f1)"
    [ -n "$toplevel" ] && [ -n "$home" ]
    [ "$toplevel" -lt "$common" ] && [ "$common" -lt "$home" ] || { echo "$p: lookup order is not toplevel, main checkout, \$HOME" >&2; return 1; }
  done
}

@test "launcher: step 2 is one instruction for every mode, with no pane-host carve-out" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    body="$(launcher_body "$p")"
    step="$(awk '/^2\. /{on=1} /^3\. /{on=0} on' "$body")"
    [ -n "$step" ] || { echo "$p: no step 2" >&2; return 1; }
    grep -qi "completion notification" <<<"$step" || { echo "$p: step 2 does not wait for the completion notification" >&2; return 1; }
    ! grep -qi "orca" <<<"$step" || { echo "$p: step 2 names orca" >&2; return 1; }
    ! grep -qi "herdr" <<<"$step" || { echo "$p: step 2 names herdr" >&2; return 1; }
    ! grep -q "PANE-HOST" "$body" || { echo "$p: the launcher still reads PANE-HOST" >&2; return 1; }
  done
}

@test "launcher: it stays a launcher - no pipeline, no state, no receipts prose" {
  # Each of these was a step the body used to perform. Naming the pipeline once, as the
  # program's contract, is fine; issuing its commands is not.
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    body="$(launcher_body "$p")"
    for banned in state.sh receipts.sh merge-branches.sh close-issue.sh \
                  promote-findings.sh verify-worktree.sh ensure-deps.sh 'git worktree add'; do
      if grep -q "$banned" "$body"; then
        echo "$p launcher names $banned — it is describing the pipeline again" >&2
        return 1
      fi
    done
  done
}

@test "launcher: it is under the launcher word budget (it replaced ~2,400)" {
  local words
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    words=$(wc -w < "$(launcher_body "$p")")
    [ "$words" -lt "$AFK_LAUNCHER_WORD_BUDGET" ] || { echo "$p launcher is $words words" >&2; return 1; }
  done
}

@test "launcher: it maps every exit code the program can return" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    for code in 0 2 3 1; do
      grep -q "\`$code\`" "$(launcher_body "$p")" || {
        echo "$p leaves exit code $code unexplained" >&2; return 1; }
    done
  done
}

@test "launcher: it forbids finishing a failed sprint by hand" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    body="$(launcher_body "$p")"
    grep -qi 'never finish the sprint by hand' "$body"
    grep -qi 'receipt gates' "$body"
  done
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
  # Node prints the scripts dir with the host's native separator (backslash on Windows).
  [[ "$output" == *".pi/skills/crew-afk/scripts"* || "$output" == *".pi\\skills\\crew-afk\\scripts"* ]]
}

@test "launcher: no platform ships a bash dispatcher" {
  [ ! -e "$REPO_ROOT/skills/crew-afk/scripts/dispatch-agent.sh" ]
  [ ! -e "$REPO_ROOT/skills/crew-afk/scripts/dispatch-codex-agent.sh" ]
}
