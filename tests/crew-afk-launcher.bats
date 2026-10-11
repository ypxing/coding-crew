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

# ─── the launcher's program lookup ──────────────────────────────────────────

# run_lookup <platform> <dir> — runs the body's launch block (the one setting CREW_AFK) in <dir> with node stubbed to print the path it got.
run_lookup() {
  local block
  block="$(awk '/^```bash$/{f=1; b=""; next} f && /^```$/{f=0; if (b ~ /CREW_AFK=/) { printf "%s", b; exit } next} f {b = b $0 "\n"}' "$(launcher_body "$1")")"
  run bash -c "cd '$2' && node() { printf '%s\n' \"\$1\"; }; $block"
}

@test "launcher: the program lookup tries the repo, then the main checkout, then the user-level install" {
  local home="$BATS_TEST_TMPDIR/home" main="$BATS_TEST_TMPDIR/main" wt="$BATS_TEST_TMPDIR/wt"
  mkdir -p "$home" "$main"
  git -C "$main" init -q -b main
  git -C "$main" -c user.email=t@test -c user.name=T commit -q --allow-empty -m init
  git -C "$main" worktree add -q "$wt"
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    HOME="$home" run_lookup "$p" "$wt"
    [ "$output" = "$home/.coding-crew/crew-afk/main.mjs" ] || { echo "$p: no copy → $output" >&2; return 1; }

    mkdir -p "$main/.coding-crew/crew-afk" && touch "$main/.coding-crew/crew-afk/main.mjs"
    HOME="$home" run_lookup "$p" "$wt"
    [ "$output" = "$main/.coding-crew/crew-afk/main.mjs" ] || { echo "$p: worktree → $output" >&2; return 1; }

    mkdir -p "$wt/.coding-crew/crew-afk" && touch "$wt/.coding-crew/crew-afk/main.mjs"
    HOME="$home" run_lookup "$p" "$wt"
    [ "$output" = "$wt/.coding-crew/crew-afk/main.mjs" ] || { echo "$p: own copy → $output" >&2; return 1; }
    rm -r "$main/.coding-crew" "$wt/.coding-crew"
  done
}

@test "launcher: copilot pre-approves the shell, so an unattended sprint never stalls on a permission prompt" {
  run grep -m1 '^allowed-tools:' "$(launcher_body copilot)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"shell"* ]]
}
