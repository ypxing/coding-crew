#!/usr/bin/env bats

# scripts/smoke-crew-afk.sh <platform> — the release smoke: the pinned demo repo, a project-level install kept out
# of git, and one crew-afk dispatch whose run must end `ready pr=<n>`. Here the demo repo is a local one
# (CREW_DEMO_DIR laid out like scripts/smoke-crew-afk/demo/), `gh` is a stub that logs its argv, and
# CREW_SMOKE_DISPATCH stands in for crew-afk.sh: its dispatch adds a worktree, writes solve-feature's files there
# and prints the worktree and a short-lived pid, so no agent CLI is called; its wait prints the status line.

load helpers/smoke-demo

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SMOKE="$REPO_ROOT/scripts/smoke-crew-afk.sh"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  D="$TMPDIR/crew-smoke-claude"

  # No user-level skills but the ones a test puts there: they would shadow the project install.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  unset $(jq -r '.[].configDirEnv // empty' "$REPO_ROOT/platforms.json" | tr -d '\r')
  make_smoke_demo
  RESULTS="$BATS_TEST_TMPDIR/RESULTS.md"
  printf '| commit | date | platform | route | result | cost | findings |\n|---|---|---|---|---|---|---|\n' > "$RESULTS"
  export CREW_SMOKE_RESULTS="$RESULTS"
}

@test "a run that ends ready passes, records one row, and closes its PR and branch" {
  run "$SMOKE" claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"SMOKE: PASS (claude, demo)"* ]]
  [[ "$output" =~ crew-afk-commit:\ [0-9a-f]{40}(-dirty)? ]]
  grep -qxF "dispatch dispatch report-cli --to local -- claude -p /solve-feature report-cli --output-format json --dangerously-skip-permissions (in $D)" "$BATS_TEST_TMPDIR/calls"
  grep -qx 'wait report-cli' "$BATS_TEST_TMPDIR/calls"
  grep -qx 'gh pr close 9' "$BATS_TEST_TMPDIR/calls"
  grep -qx 'gh api -X DELETE repos/{owner}/{repo}/git/refs/heads/feature/report-cli' "$BATS_TEST_TMPDIR/calls"
  [ "$(wc -l < "$RESULTS")" -eq 3 ]
  [[ "$(tail -n 1 "$RESULTS")" =~ ^\|\ [0-9a-f]{12}(-dirty)?\ \|\ [0-9]{4}-[0-9]{2}-[0-9]{2}\ \|\ claude\ \|\ install\ \|\ PASS\ \|\ \$1\.25\ \|\ 2\ \|$ ]]
}

@test "each platform in platforms.json dispatches its own headless launch command after --" {
  local p want
  for p in $(jq -r 'keys[]' "$REPO_ROOT/platforms.json" | tr -d '\r'); do
    case "$p" in
      # JSON last, so the run's log ends with the result whose cost fills the RESULTS cost column.
      claude) want=$'claude\n-p\n/solve-feature report-cli\n--output-format\njson\n--dangerously-skip-permissions' ;;
      copilot) want=$'copilot\n-p\nUse the solve-feature skill on report-cli\n--allow-all' ;;
      codex) want=$'codex\nexec\n--dangerously-bypass-approvals-and-sandbox\nUse the solve-feature skill on report-cli' ;;
      pi) want=$'pi\n-p\n/skill:solve-feature report-cli' ;;
      *) echo "no expected argv for $p"; return 1 ;;
    esac
    run "$SMOKE" "$p"
    [ "$status" -eq 0 ] || { echo "$p: $output"; return 1; }
    [ "$(sed '1,/^--$/d' "$BATS_TEST_TMPDIR/dispatch-argv")" = "$want" ] || { echo "$p:"; cat "$BATS_TEST_TMPDIR/dispatch-argv"; return 1; }
    [ "$(sed -n '1,/^--$/p' "$BATS_TEST_TMPDIR/dispatch-argv")" = $'dispatch\nreport-cli\n--to\nlocal\n--' ]
  done
}

@test "a wait line with no cost records ? in the cost column" {
  WAIT_COST= run "$SMOKE" claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$(tail -n 1 "$RESULTS")" == *"| claude | install | PASS | ? | 2 |" ]]
}

@test "the smoke script reads no cost from run.log and has no wait loop of its own" {
  ! grep -nE 'run\.log.*jq|jq.*run\.log|kill -0' "$SMOKE" || false
  grep -qF '"${DISPATCH[@]}" wait "$SLUG"' "$SMOKE"
}

@test "the smoke repo is the pinned clone with origin kept, the install and feature in place and the tree clean" {
  run "$SMOKE" claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(git -C "$D" rev-parse HEAD)" = "$PIN" ]
  [ "$(git -C "$D" remote get-url origin)" = "$UP" ]
  [ -f "$D/.claude/skills/crew-afk/scripts/crew-afk.sh" ]
  [ -f "$D/.scratch/report-cli/issues/open/01-one.md" ]
  local p
  for p in .coding-crew/lib .coding-crew/manifest.json .claude/skills; do
    grep -qxF "$p" "$D/.worktreeinclude" || { echo "worktreeinclude lacks $p"; return 1; }
    grep -qxF "$p" "$D/.git/info/exclude" || { echo "exclude lacks $p"; return 1; }
  done
  grep -qxF .worktreeinclude "$D/.git/info/exclude"
  grep -qxF .scratch/ "$D/.git/info/exclude"
  [ -z "$(git -C "$D" status --porcelain)" ]
}

@test "an open PR left from an earlier run is closed and its branch deleted before the dispatch" {
  GH_OPEN_PR=5 run "$SMOKE" claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  close=$(grep -n 'gh pr close 5' "$BATS_TEST_TMPDIR/calls" | cut -d: -f1)
  dispatch=$(grep -n '^dispatch ' "$BATS_TEST_TMPDIR/calls" | cut -d: -f1)
  [ -n "$close" ] && [ "$close" -lt "$dispatch" ]
}

@test "a run that ends needing attention fails, records a FAIL row and leaves its PR open" {
  OUTCOME='needs-attention pr=9' run "$SMOKE" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: "*"needs-attention pr=9"* ]]
  [[ "$output" == *"crew-afk-commit: "* ]]
  [[ "$(tail -n 1 "$RESULTS")" == *"| claude | install | FAIL |"* ]]
  ! grep -q 'gh pr close 9' "$BATS_TEST_TMPDIR/calls"
}

@test "a check that fails in the run's worktree fails the smoke, naming it" {
  echo 'test -f missing.txt' >> "$DEMO/check"
  run "$SMOKE" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: "*"test -f missing.txt"* ]]
}

@test "a demo repo whose default branch moved past the pin fails before any dispatch" {
  echo two > "$UP/b.txt"
  git -C "$UP" add -A && git -C "$UP" -c user.email=t@t -c user.name=t commit -qm two
  run "$SMOKE" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: demo repo moved: origin/main is $(git -C "$UP" rev-parse HEAD), pinned $PIN"* ]]
  ! grep -q '^dispatch ' "$BATS_TEST_TMPDIR/calls"
}

@test "a second run rebuilds the repo; a directory that is not a smoke repo is refused, not deleted" {
  "$SMOKE" claude >/dev/null
  echo stale > "$D/stale.txt"
  run "$SMOKE" claude
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$D/stale.txt" ]
  rm -rf "$D" && mkdir -p "$D" && echo keep > "$D/keep.txt"
  run "$SMOKE" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a smoke repo"* ]]
  [ -f "$D/keep.txt" ]
}

@test "a user-level copy of a skill that would shadow the project install fails before any dispatch" {
  mkdir -p "$HOME/.claude/skills/solve-feature"
  echo stale > "$HOME/.claude/skills/solve-feature/SKILL.md"
  run "$SMOKE" claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: user-level skills shadow the project install"* ]]
  ! grep -q '^dispatch ' "$BATS_TEST_TMPDIR/calls"
}

@test "an unknown platform or route is a usage error" {
  run "$SMOKE" nope
  [ "$status" -eq 2 ]
  run "$SMOKE" claude --via pip
  [ "$status" -eq 2 ]
  run "$SMOKE" claude --via
  [ "$status" -eq 2 ]
}

@test "--via install is the default route: install.sh, no npx" {
  run "$SMOKE" claude --via install
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"SMOKE: PASS (claude, demo)"* ]]
  ! grep -q '^npx ' "$BATS_TEST_TMPDIR/calls"
  [ -L "$D/.claude/skills/solve-issue/scripts/tracker" ]
  [[ "$(tail -n 1 "$RESULTS")" == *"| claude | install | PASS |"* ]]
}

@test "--via npx installs with npx skills add into the demo repo, keeps it clean and passes unchanged" {
  run "$SMOKE" claude --via npx
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *$'\nSMOKE: PASS (claude, demo)' ]]
  grep -qxF "npx -y skills@1.7.2 add $REPO_ROOT -a claude-code -y (in $D) DISABLE_TELEMETRY=1" "$BATS_TEST_TMPDIR/calls"
  [ ! -e "$D/.coding-crew/manifest.json" ]
  grep -qxF .claude/skills "$D/.worktreeinclude"
  local p
  for p in .claude/skills skills-lock.json .worktreeinclude .scratch/; do
    grep -qxF "$p" "$D/.git/info/exclude" || { echo "exclude lacks $p"; return 1; }
  done
  [ -z "$(git -C "$D" status --porcelain)" ]
  grep -qxF "dispatch dispatch report-cli --to local -- claude -p /solve-feature report-cli --output-format json --dangerously-skip-permissions (in $D)" "$BATS_TEST_TMPDIR/calls"
  [[ "$(tail -n 1 "$RESULTS")" == *"| claude | npx | PASS |"* ]]
}

@test "--via npx passes each platform its npx skills agent id and excludes the dir that agent reads" {
  local p agent dir
  for p in $(jq -r 'keys[]' "$REPO_ROOT/platforms.json" | tr -d '\r'); do
    case "$p" in
      claude) agent=claude-code dir=.claude/skills ;;
      copilot) agent=github-copilot dir=.agents/skills ;;
      codex) agent=codex dir=.agents/skills ;;
      pi) agent=pi dir=.agents/skills ;;
      *) echo "no expected agent id for $p"; return 1 ;;
    esac
    run "$SMOKE" "$p" --via npx
    [ "$status" -eq 0 ] || { echo "$p: $output"; return 1; }
    grep -qF "npx -y skills@1.7.2 add $REPO_ROOT -a $agent -y (in $TMPDIR/crew-smoke-$p)" "$BATS_TEST_TMPDIR/calls" || { echo "$p"; cat "$BATS_TEST_TMPDIR/calls"; return 1; }
    grep -qxF "$dir" "$TMPDIR/crew-smoke-$p/.git/info/exclude" || { echo "$p: exclude lacks $dir"; return 1; }
    [[ "$output" == *"SMOKE: PASS ($p, demo)"* ]]
  done
}

@test "--via npx fails before any dispatch when a user-level copy would shadow the project install" {
  mkdir -p "$HOME/.claude/skills/solve-issue"
  echo stale > "$HOME/.claude/skills/solve-issue/SKILL.md"
  run "$SMOKE" claude --via npx
  [ "$status" -eq 1 ]
  [[ "$output" == *"SMOKE: FAIL: user-level skills shadow the project install"*"$HOME/.claude/skills/solve-issue"* ]]
  ! grep -q '^dispatch ' "$BATS_TEST_TMPDIR/calls"
}
