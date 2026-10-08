#!/usr/bin/env bats

# tracker-cli.sh — the one lookup of the tracker CLI (tracker/cli.mjs) in crew-afk's shell scripts,
# sourced by close-issue.sh, close-shipped.sh, issue-labels.sh, promote-findings.sh and
# session-init.sh. Order, first existing file wins: $CREW_TRACKER_CLI, $CREW_INSTALL_DIR/tracker,
# <main-root>/.coding-crew/tracker, <main-root>/tracker (a source checkout),
# $HOME/.coding-crew/tracker. No CLI, no node, or a failing `config` is an error, never local.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK="$REPO_ROOT/skills/crew-afk/scripts"
CALLERS=(close-issue.sh close-shipped.sh issue-labels.sh promote-findings.sh session-init.sh)

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  export HOME="$TEMP_DIR/home"
  mkdir -p "$HOME"
  export MAIN_ROOT="$TEMP_DIR/repo"
  mkdir -p "$MAIN_ROOT/.coding-crew"
  cd "$MAIN_ROOT"
  git init -q -b main
  git config user.email t@t
  git config user.name T
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m init
  printf '{"tracker": {"kind": "github"}}\n' > .coding-crew/config.json
  unset CREW_INSTALL_DIR CREW_TRACKER_CLI CREW_ORCHESTRATED SPRINT_DIR FEATURE_SLUG CREW_RECEIPTS

  STUB="$TEMP_DIR/stub"
  mkdir -p "$STUB"
  ORIG_PATH="$PATH"
  export PATH="$STUB:$PATH"
  export GH_LOG="$TEMP_DIR/gh.log"
  : > "$GH_LOG"
  cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue view") printf 'Status: ready-for-agent\n\n## Acceptance criteria\n\n- [x] one\n'; exit 0 ;;
  "repo view") echo "o/r main"; exit 0 ;;
  "pr list"|"issue list") echo '[]'; exit 0 ;;
esac
exit 0
GH
  chmod +x "$STUB/gh"
  export CREW_FAKE_GH="$STUB/gh"
}

teardown() {
  PATH="$ORIG_PATH"
  cd /
  rm -r -f "$TEMP_DIR"
}

# fake_cli <dir> — a cli.mjs that answers `config` as github and says which copy ran.
fake_cli() {
  mkdir -p "$1"
  printf 'console.error("RAN:%s"); console.log("tracker=github\\nconfigured=yes");\n' "$1" > "$1/cli.mjs"
}

resolve() { # <main-root> — sources the helper and prints what it resolved
  bash -c '. "$1/tracker-cli.sh"; resolve_tracker_cli "$2" || exit $?; echo "CLI=$TRACKER_CLI KIND=$TRACKER_KIND"' _ "$AFK" "$1"
}

# run_caller <script> — one invocation per caller that branches on the tracker kind.
run_caller() {
  case "$1" in
    close-issue.sh) CREW_RECEIPTS=off run bash "$AFK/close-issue.sh" 42 ;;
    close-shipped.sh) run bash "$AFK/close-shipped.sh" demo feature/demo ;;
    issue-labels.sh) run bash "$AFK/issue-labels.sh" claim 7 ;;
    promote-findings.sh) run bash "$AFK/promote-findings.sh" defer --severities actionable \
        --feature-slug demo --branch crew/demo/a --slug a --title "Fix: a" \
        --report "$TEMP_DIR/report.md" --criteria-file "$TEMP_DIR/crit.md" ;;
    session-init.sh) run bash "$AFK/session-init.sh" ;;
  esac
}

@test "no caller carries a lookup of its own: each sources tracker-cli.sh and calls resolve_tracker_cli" {
  local f
  for f in "${CALLERS[@]}"; do
    grep -q 'tracker-cli\.sh"' "$AFK/$f" || { echo "$f does not source tracker-cli.sh"; return 1; }
    grep -q 'resolve_tracker_cli "\$[A-Z_]*" || exit 1' "$AFK/$f" || { echo "$f does not call resolve_tracker_cli"; return 1; }
    ! grep -nE 'cli\.mjs"|tracker-config|TRACKER_CONFIG_|CREW_GITHUB_TRACKER_CLI' "$AFK/$f" || { echo "own lookup in $f"; return 1; }
  done
}

@test "lookup order: each candidate wins over every later one, first existing file wins" {
  local cands=(
    "$TEMP_DIR/override/cli.mjs"
    "$TEMP_DIR/install/tracker/cli.mjs"
    "$MAIN_ROOT/.coding-crew/tracker/cli.mjs"
    "$MAIN_ROOT/tracker/cli.mjs"
    "$HOME/.coding-crew/tracker/cli.mjs"
  ) c i
  for c in "${cands[@]}"; do fake_cli "$(dirname "$c")"; done
  export CREW_TRACKER_CLI="${cands[0]}" CREW_INSTALL_DIR="$TEMP_DIR/install"
  for i in 0 1 2 3 4; do
    run resolve "$MAIN_ROOT"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLI=${cands[$i]} KIND=github"* ]]
    rm -f "${cands[$i]}"
  done
}

@test "an unset CREW_TRACKER_CLI or CREW_INSTALL_DIR is skipped, not a candidate" {
  fake_cli "$HOME/.coding-crew/tracker"
  export CREW_TRACKER_CLI="" CREW_INSTALL_DIR=""
  run resolve "$MAIN_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLI=$HOME/.coding-crew/tracker/cli.mjs KIND=github"* ]]
}

@test "the kind is the real CLI's config answer for the main root" {
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  run resolve "$MAIN_ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"KIND=github"* ]]
  printf '{"tracker": {"kind": "local"}}\n' > .coding-crew/config.json
  run resolve "$MAIN_ROOT"
  [[ "$output" == *"KIND=local"* ]]
}

@test "config.json github, no .coding-crew/scripts anywhere: each caller behaves as github" {
  mkdir -p "$TEMP_DIR/install"
  cp -R "$REPO_ROOT/tracker" "$TEMP_DIR/install/tracker"
  export CREW_INSTALL_DIR="$TEMP_DIR/install"
  printf -- '- [ ] fix it\n' > "$TEMP_DIR/crit.md"
  printf '## Branch: crew/demo/a (a)\n\n```json\n{"branch":"crew/demo/a","slug":"a","verdict":"all-met","findings":[{"severity":"HIGH","location":"x:1","criterion":"c"}]}\n```\n' > "$TEMP_DIR/report.md"
  export CREW_REVIEW_ROLLUP="$REPO_ROOT/orchestrator/review-rollup.mjs"
  [ ! -e "$MAIN_ROOT/.coding-crew/scripts" ] && [ ! -e "$HOME/.coding-crew/scripts" ] && [ ! -e "$TEMP_DIR/install/scripts" ]

  run_caller close-issue.sh
  echo "close-issue: $output"
  [ "$status" -eq 0 ]
  grep -q '^issue edit 42 .*--add-label awaiting-merge' "$GH_LOG"

  : > "$GH_LOG"; run_caller close-shipped.sh
  echo "close-shipped: $output"
  grep -q '^repo view' "$GH_LOG"

  : > "$GH_LOG"; run_caller issue-labels.sh
  echo "issue-labels: $output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LABELLED: in-progress #7"* ]]

  : > "$GH_LOG"; run_caller promote-findings.sh
  echo "promote-findings: $output"
  grep -q '^issue create ' "$GH_LOG"

  run_caller session-init.sh
  echo "session-init: $output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"--feature-slug is required under tracker: github"* ]]
}

@test "no cli.mjs anywhere: each caller exits non-zero naming it and re-run install.sh, never local" {
  local f
  for f in "${CALLERS[@]}"; do
    run_caller "$f"
    echo "$f: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"tracker CLI (.coding-crew/tracker/cli.mjs) not found — re-run install.sh"* ]]
  done
  [ ! -s "$GH_LOG" ]
}

@test "no node on PATH: each caller exits non-zero naming Node and re-run install.sh" {
  local d n=0 newpath="" t f
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  # Every tool on PATH but node: each PATH directory holding a node is mirrored without it.
  while IFS= read -r d; do
    if [ -n "$d" ] && [ -e "$d/node" ]; then
      n=$((n + 1)); mkdir -p "$TEMP_DIR/nonode$n"
      for t in "$d"/*; do
        [ "$(basename "$t")" = node ] || ln -s "$t" "$TEMP_DIR/nonode$n/$(basename "$t")" 2>/dev/null || true
      done
      d="$TEMP_DIR/nonode$n"
    fi
    newpath="${newpath:+$newpath:}$d"
  done <<< "$(printf '%s' "$PATH" | tr ':' '\n')"
  PATH="$newpath"
  run command -v node
  [ "$status" -ne 0 ]
  for f in "${CALLERS[@]}"; do
    run_caller "$f"
    echo "$f: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"the tracker CLI needs Node (node not found on PATH)"*"re-run install.sh"* ]]
  done
  [ ! -s "$GH_LOG" ]
}

@test "an invalid config.json: each caller exits non-zero with the CLI's stderr" {
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  printf '{ not json\n' > .coding-crew/config.json
  local expected f
  expected="$(node "$CREW_TRACKER_CLI" config --main-root "$MAIN_ROOT" 2>&1 >/dev/null)" || true
  [ -n "$expected" ]
  for f in "${CALLERS[@]}"; do
    run_caller "$f"
    echo "$f: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$expected"* ]]
  done
  [ ! -s "$GH_LOG" ]
}

@test "tracker templates' tracker CLI lookup works for project and user-level installs" {
  local t where lookup
  for t in github local; do
    # The section's first bash block is the lookup; the op lines follow in the next one.
    lookup=$(awk '/^## Tracker CLI/{f=1;next} /^## /{f=0} f' "$REPO_ROOT/tracker/docs/$t.md" |
      awk '/^```bash/{b=1;next} /^```/{if(b)exit} b')
    [ -n "$lookup" ]
    for where in "$MAIN_ROOT/.coding-crew/tracker" "$HOME/.coding-crew/tracker"; do
      rm -r -f "$MAIN_ROOT/.coding-crew/tracker" "$HOME/.coding-crew/tracker"
      mkdir -p "$where"
      printf 'console.log("RAN:%s " + process.argv.slice(2).join(" "));\n' "$where" > "$where/cli.mjs"
      run bash -c "cd '$MAIN_ROOT' && $lookup
node \"\$TRACKER\" mark-done 1"
      [ "$status" -eq 0 ]
      [[ "$output" == *"RAN:$where mark-done 1"* ]]
    done
  done
}

@test "issue-labels.sh block: adds blocked and removes in-progress in one edit, keeps ready-for-agent" {
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  run bash "$AFK/issue-labels.sh" block 7
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LABELLED: blocked #7"* ]]
  grep -q '^label create blocked .*--force' "$GH_LOG"
  grep -q '^issue edit 7 --add-label blocked --remove-label in-progress$' "$GH_LOG"
  [ "$(grep -c '^issue edit' "$GH_LOG")" -eq 1 ]
  ! grep -q 'ready-for-agent' "$GH_LOG"
}

@test "issue-labels.sh claim: creates in-progress and adds it" {
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  run bash "$AFK/issue-labels.sh" claim 7
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LABELLED: in-progress #7"* ]]
  grep -q '^label create in-progress .*--force' "$GH_LOG"
  grep -q '^issue edit 7 --add-label in-progress$' "$GH_LOG"
}

@test "issue-labels.sh release: removes in-progress and nothing else" {
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  run bash "$AFK/issue-labels.sh" release 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELEASED: in-progress #7"* ]]
  grep -q '^issue edit 7 --remove-label in-progress$' "$GH_LOG"
}

@test "issue-labels.sh sweep: removes in-progress from every milestone issue that carries it" {
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1 $2" = "issue list" ]; then printf '3\n5\n'; fi
exit 0
GH
  run bash "$AFK/issue-labels.sh" sweep demo
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SWEPT: 2"* ]]
  grep -q '^issue list .*--milestone demo --label in-progress --state all' "$GH_LOG"
  grep -q '^issue edit 3 --remove-label in-progress$' "$GH_LOG"
  grep -q '^issue edit 5 --remove-label in-progress$' "$GH_LOG"
}

@test "issue-labels.sh sweep: a milestone that does not exist yet is nothing to sweep" {
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  printf '#!/usr/bin/env bash\necho "no milestone found" >&2; exit 1\n' > "$STUB/gh"
  run bash "$AFK/issue-labels.sh" sweep demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"SWEPT: 0"* ]]
}

@test "issue-labels.sh claim/release/sweep: tracker local touches nothing" {
  printf '{"tracker": {"kind": "local"}}\n' > .coding-crew/config.json
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  for c in "claim 7" "release 7" "sweep demo"; do
    run bash "$AFK/issue-labels.sh" $c
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ ! -s "$GH_LOG" ]
}

@test "issue-labels.sh block: tracker local touches nothing" {
  printf '{"tracker": {"kind": "local"}}\n' > .coding-crew/config.json
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  run bash "$AFK/issue-labels.sh" block 7
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GH_LOG" ]
}

@test "issue-labels.sh block: a failing gh exits 1" {
  printf '#!/usr/bin/env bash\necho boom >&2; exit 1\n' > "$STUB/gh"
  export CREW_TRACKER_CLI="$REPO_ROOT/tracker/cli.mjs"
  run bash "$AFK/issue-labels.sh" block 7
  [ "$status" -eq 1 ]
}
