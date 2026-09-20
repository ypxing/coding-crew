#!/usr/bin/env bats

# A user-level install has to be enough to run a sprint in any repo.
#
# `README.md` promises it — "Installs to $HOME (user-level, works in any project)" — but
# crew-afk broke that promise twice over, and a Copilot user reported it as the skill
# demanding a per-project install:
#
#   1. `resolveScriptsDir()` searched only the *target repo* (`.pi/skills`, `.github/skills`,
#      …) and this repo's own source tree. A user-level install put the bash mechanism layer
#      in `~/.copilot/skills/crew-afk/scripts`, which was on no candidate list, so the
#      program died with "cannot find crew-afk's scripts/ dir".
#   2. Every launcher ran `node "$(git rev-parse --show-toplevel)/.coding-crew/crew-afk/main.mjs"`,
#      a path that only exists after a *project* install — so a user-level install could not
#      even reach the resolver.
#
# The failure was doubly confusing because the remedy printed by the launcher ("the skill is
# half-installed; re-run ./install.sh <platform> --skill crew-afk") named the skill text,
# which was never missing.
#
# These tests fix the install scope as a contract: user level runs anywhere, project level
# still wins where both exist.

load helpers/render

# path_matches <output> <unix-style-fragment> — true if output contains the fragment with
# either separator style. Node prints resolved paths with the host's native separator
# (backslash on Windows); our expected fragments are written with forward slashes for
# readability, so check both.
path_matches() {
  local out="$1" frag="$2"
  [[ "$out" == *"$frag"* || "$out" == *"${frag//\//\\}"* ]]
}

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
}

setup() {
  FAKE_HOME="$BATS_TEST_TMPDIR/home"
  WORK_REPO="$BATS_TEST_TMPDIR/work"
  mkdir -p "$FAKE_HOME" "$WORK_REPO"
  # install.sh's resolve_dest() redirects a user-scope (.claude/, .copilot/, .pi/agent/,
  # .codex/) install to these when set, the same way the real CLIs do — see install.sh's
  # own comment above resolve_dest(). Left ambient (e.g. this suite running inside a real
  # Claude Code session, where CLAUDE_CONFIG_DIR already points at the real ~/.claude),
  # every "user-level" test below would silently install into that real location instead
  # of $FAKE_HOME and then fail asserting against the empty fake one.
  unset CLAUDE_CONFIG_DIR COPILOT_HOME PI_CODING_AGENT_DIR CODEX_HOME
}

# user_install <platform> — a user-level install into $FAKE_HOME (TARGET_REPO=$HOME)
user_install() {
  env HOME="$FAKE_HOME" TARGET_REPO="$FAKE_HOME" bash "$REPO_ROOT/install.sh" "$1" --skill crew-afk >/dev/null
}

# a git repo with one dispatchable issue and no crew-afk install of its own
work_repo_with_issue() {
  git -C "$WORK_REPO" init -q -b main
  git -C "$WORK_REPO" config user.email t@test
  git -C "$WORK_REPO" config user.name T
  mkdir -p "$WORK_REPO/.scratch/demo/issues/open"
  printf '# widget\n\nStatus: ready-for-agent\n\n## Acceptance criteria\n\n- [ ] exists\n' \
    > "$WORK_REPO/.scratch/demo/issues/open/01-widget.md"
  echo x > "$WORK_REPO/README.md"
  git -C "$WORK_REPO" add -A
  git -C "$WORK_REPO" commit -qm init
}

# ─── resolution ──────────────────────────────────────────────────────────────

@test "user-level install: the orchestrator finds its scripts dir in \$HOME from any repo" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  user_install copilot
  work_repo_with_issue

  # Exactly what the launcher runs, from a repo that has no crew-afk install of its own.
  cd "$WORK_REPO"
  run env HOME="$FAKE_HOME" node "$FAKE_HOME/.coding-crew/crew-afk/main.mjs" plan --platform copilot
  [ "$status" -eq 0 ]
  [[ "$output" == *"widget"* ]]
  path_matches "$output" ".copilot/skills/crew-afk/scripts" || {
    echo "did not resolve the user-level scripts dir:" >&2; echo "$output" >&2; return 1; }
}

@test "user-level install: every platform's user-level scripts dir is a candidate" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  work_repo_with_issue
  cd "$WORK_REPO"

  local expected
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    rm -rf "$FAKE_HOME"; mkdir -p "$FAKE_HOME"
    user_install "$p"
    case "$p" in
      pi)      expected=".pi/agent/skills/crew-afk/scripts" ;;
      copilot) expected=".copilot/skills/crew-afk/scripts" ;;
      claude)  expected=".claude/skills/crew-afk/scripts" ;;
      codex)   expected=".agents/skills/crew-afk/scripts" ;;
    esac
    run env HOME="$FAKE_HOME" node "$FAKE_HOME/.coding-crew/crew-afk/main.mjs" plan --platform "$p"
    [ "$status" -eq 0 ]
    path_matches "$output" "$expected" || {
      echo "$p: expected scripts under $expected, got:" >&2; echo "$output" >&2; return 1; }
  done
}

@test "user-level install: a project install still wins over the \$HOME copy" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  user_install pi
  work_repo_with_issue
  TARGET_REPO="$WORK_REPO" bash "$REPO_ROOT/install.sh" pi --skill crew-afk >/dev/null

  cd "$WORK_REPO"
  run env HOME="$FAKE_HOME" node .coding-crew/crew-afk/main.mjs plan --platform pi
  [ "$status" -eq 0 ]
  # Resolve expected_project from node's own cwd, not a bash-string round trip through an
  # env var: main.mjs's own mainRoot comes from `git rev-parse --show-toplevel`, spawned
  # from the same cwd this test already `cd`s into above, so matching that cwd-based
  # resolution (rather than reconstructing the path from $WORK_REPO passed as an env var,
  # which MSYS can convert differently — short 8.3 names, separator style) is what actually
  # mirrors the real invocation on Windows.
  local expected_project expected_home
  expected_project="$(node -e 'console.log(require("path").resolve(".pi/skills/crew-afk/scripts"))')"
  expected_home="$(FAKE_HOME="$FAKE_HOME" node -e 'console.log(require("path").resolve(process.env.FAKE_HOME, ".pi"))')"
  # The repo's own copy, not $HOME's: a project install is what a repo pins deliberately.
  [[ "$output" == *"$expected_project"* ]] || {
    echo "project install did not take priority:" >&2; echo "$output" >&2; return 1; }
  [[ "$output" != *"$expected_home"* ]]
}

@test "user-level install: CREW_SCRIPTS still overrides both" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  user_install pi
  work_repo_with_issue
  local override="$BATS_TEST_TMPDIR/override"
  cp -R "$FAKE_HOME/.pi/agent/skills/crew-afk/scripts" "$override"

  cd "$WORK_REPO"
  run env HOME="$FAKE_HOME" CREW_SCRIPTS="$override" \
    node "$FAKE_HOME/.coding-crew/crew-afk/main.mjs" plan --platform pi
  [ "$status" -eq 0 ]
  # Compare against Node's own path.resolve() of CREW_SCRIPTS, not the raw bash string:
  # resolveScriptsDir() calls resolve() on it verbatim, and on Windows that string can
  # differ from bash's own (MSYS env-var path mangling, 8.3 short names in %TEMP%) even
  # though both name the same directory.
  local expected
  expected="$(env HOME="$FAKE_HOME" CREW_SCRIPTS="$override" \
    node -e 'console.log(require("path").resolve(process.env.CREW_SCRIPTS))')"
  [[ "$output" == *"$expected"* ]]
}

# ─── the launcher's own path ──────────────────────────────────────────────────

@test "launcher: it falls back to the user-level orchestrator when the repo has no copy" {
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    body="$REPO_ROOT/skills/crew-afk/$p.SKILL.md"
    grep -q 'HOME/.coding-crew/crew-afk/main.mjs' "$body" || {
      echo "$p launcher cannot reach a user-level install" >&2; return 1; }
  done
}

@test "launcher: the missing-scripts remedy names the install scope, not 'half-installed'" {
  # The old wording sent a user who had installed user-level back to the same install.
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    body="$REPO_ROOT/skills/crew-afk/$p.SKILL.md"
    ! grep -q 'half-installed' "$body" || {
      echo "$p still calls a scope problem a half-install" >&2; return 1; }
    grep -q 'TARGET_REPO=\$HOME' "$body" || {
      echo "$p does not tell the user how to install user-level" >&2; return 1; }
  done
}

@test "launcher: the rendered body runs the same resolved path" {
  # Rendering is what a consumer receives; the fallback must survive it.
  for p in "${AFK_LAUNCHER_VARIANTS[@]}"; do
    grep -q 'HOME/.coding-crew/crew-afk/main.mjs' "$(afk_variant "$p")"
  done
}
