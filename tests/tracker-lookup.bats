#!/usr/bin/env bats

# One lookup order for tracker-config.sh / mark-issue-done.sh, in every shell caller:
# $CREW_TRACKER_CONFIG, $CREW_INSTALL_DIR/scripts, $MAIN_ROOT/.coding-crew/scripts,
# $MAIN_ROOT/scripts/tracker, $HOME/.coding-crew/scripts.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
AFK="$REPO_ROOT/skills/crew-afk/scripts"
CALLERS=(
  "$AFK/session-init.sh" "$AFK/close-issue.sh" "$AFK/promote-findings.sh"
  "$AFK/issue-labels.sh" "$AFK/close-shipped.sh"
  "$REPO_ROOT/scripts/tracker/mark-issue-done.sh"
)

setup() {
  TEMP_DIR=$(mktemp -d)
  export TEMP_DIR
  export HOME="$TEMP_DIR/home"
  mkdir -p "$HOME"
  export MAIN_ROOT="$TEMP_DIR/repo"
  mkdir -p "$MAIN_ROOT/.coding-crew/docs"
  cd "$MAIN_ROOT"
  git init -q -b main
  git config user.email t@t
  git config user.name T
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m init
  printf -- '---\ntracker: github\n---\n' > .coding-crew/docs/issue-tracker.md
  unset CREW_INSTALL_DIR CREW_TRACKER_CONFIG CREW_ORCHESTRATED SPRINT_DIR FEATURE_SLUG CREW_RECEIPTS

  STUB="$TEMP_DIR/stub"
  mkdir -p "$STUB"
  export PATH="$STUB:$PATH"
  export GH_LOG="$TEMP_DIR/gh.log"
  : > "$GH_LOG"
  cat > "$STUB/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue view") printf 'Status: ready-for-agent\n\n## Acceptance criteria\n\n- [x] one\n'; exit 0 ;;
esac
exit 0
GH
  chmod +x "$STUB/gh"
  export CREW_FAKE_GH="$STUB/gh"
}

teardown() {
  cd /
  rm -r -f "$TEMP_DIR"
}

install_scripts() { # <dir>
  mkdir -p "$1"
  cp "$REPO_ROOT/scripts/tracker/tracker-config.sh" "$REPO_ROOT/scripts/tracker/mark-issue-done.sh" "$1/"
  # mark-issue-done.sh delegates to the tracker CLI, which installs beside scripts/.
  rm -r -f "$1/../tracker" && cp -R "$REPO_ROOT/tracker" "$1/../tracker"
}

block() { awk '/# BEGIN tracker-lookup/{f=1} f{print} /# END tracker-lookup/{f=0}' "$1"; }

@test "every caller carries the identical lookup block" {
  local ref f
  ref=$(block "${CALLERS[0]}")
  [ -n "$ref" ]
  for f in "${CALLERS[@]}"; do
    [ "$(block "$f")" = "$ref" ] || { echo "drift in $f"; return 1; }
  done
}

@test "CREW_INSTALL_DIR/scripts: session-init succeeds and close-issue labels awaiting-merge" {
  install_scripts "$TEMP_DIR/install/scripts"
  export CREW_INSTALL_DIR="$TEMP_DIR/install"
  run bash "$AFK/session-init.sh" --feature-slug alpha
  echo "$output"
  [ "$status" -eq 0 ]
  CREW_RECEIPTS=off run bash "$AFK/close-issue.sh" 42
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q '^issue edit .*--add-label awaiting-merge' "$GH_LOG"
}

@test "user-level install only: mark-issue-done run directly labels awaiting-merge" {
  install_scripts "$HOME/.coding-crew/scripts"
  run bash "$REPO_ROOT/scripts/tracker/mark-issue-done.sh" 42 --force
  echo "$output"
  [ "$status" -eq 0 ]
  grep -q '^issue edit .*--add-label awaiting-merge' "$GH_LOG"
}

@test "reader found nowhere under tracker: github: session-init exits 1 listing the paths" {
  run bash "$AFK/session-init.sh" --feature-slug alpha
  [ "$status" -eq 1 ]
  [[ "$output" == *"$MAIN_ROOT/.coding-crew/scripts/tracker-config.sh"* ]]
  [[ "$output" == *"$HOME/.coding-crew/scripts/tracker-config.sh"* ]]
}

@test "project install wins over user-level when CREW_INSTALL_DIR is unset" {
  install_scripts "$MAIN_ROOT/.coding-crew/scripts"
  install_scripts "$HOME/.coding-crew/scripts"
  printf 'echo PROJECT-READER >&2\n' >> "$MAIN_ROOT/.coding-crew/scripts/tracker-config.sh"
  run bash "$REPO_ROOT/scripts/tracker/mark-issue-done.sh" 42 --force
  [[ "$output" == *PROJECT-READER* ]]
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

@test "a caller stopping at the first hit never breaks the lookup's pipe" {
  # Every caller reads the candidates through `< <(...)` and breaks on the first hit, which
  # can close the pipe while the list is still being written. With SIGPIPE ignored (as on CI
  # runners) a write into it must not leave "write error: Broken pipe" on stderr. Here the
  # reader is gone before the first write, so that case happens on every run.
  export CREW_TRACKER_CONFIG="$REPO_ROOT/scripts/tracker/tracker-config.sh" CREW_INSTALL_DIR="$TEMP_DIR/i"
  run bash -c "$(block "${CALLERS[0]}")"'
    trap "" PIPE
    { sleep 0.5; tracker_config_candidates /r; } | true'
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "issue-labels.sh block: adds blocked and removes in-progress in one edit, keeps ready-for-agent" {
  install_scripts "$TEMP_DIR/install/scripts"; export CREW_INSTALL_DIR="$TEMP_DIR/install"
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
  install_scripts "$TEMP_DIR/install/scripts"; export CREW_INSTALL_DIR="$TEMP_DIR/install"
  run bash "$AFK/issue-labels.sh" claim 7
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LABELLED: in-progress #7"* ]]
  grep -q '^label create in-progress .*--force' "$GH_LOG"
  grep -q '^issue edit 7 --add-label in-progress$' "$GH_LOG"
}

@test "issue-labels.sh release: removes in-progress and nothing else" {
  install_scripts "$TEMP_DIR/install/scripts"; export CREW_INSTALL_DIR="$TEMP_DIR/install"
  run bash "$AFK/issue-labels.sh" release 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"RELEASED: in-progress #7"* ]]
  grep -q '^issue edit 7 --remove-label in-progress$' "$GH_LOG"
}

@test "issue-labels.sh sweep: removes in-progress from every milestone issue that carries it" {
  install_scripts "$TEMP_DIR/install/scripts"; export CREW_INSTALL_DIR="$TEMP_DIR/install"
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
  install_scripts "$TEMP_DIR/install/scripts"; export CREW_INSTALL_DIR="$TEMP_DIR/install"
  printf '#!/usr/bin/env bash\necho "no milestone found" >&2; exit 1\n' > "$STUB/gh"
  run bash "$AFK/issue-labels.sh" sweep demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"SWEPT: 0"* ]]
}

@test "issue-labels.sh claim/release/sweep: tracker local touches nothing" {
  printf -- '---\ntracker: local\n---\n' > .coding-crew/docs/issue-tracker.md
  install_scripts "$TEMP_DIR/install/scripts"; export CREW_INSTALL_DIR="$TEMP_DIR/install"
  for c in "claim 7" "release 7" "sweep demo"; do
    run bash "$AFK/issue-labels.sh" $c
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ ! -s "$GH_LOG" ]
}

@test "issue-labels.sh block: tracker local touches nothing" {
  printf -- '---\ntracker: local\n---\n' > .coding-crew/docs/issue-tracker.md
  install_scripts "$TEMP_DIR/install/scripts"; export CREW_INSTALL_DIR="$TEMP_DIR/install"
  run bash "$AFK/issue-labels.sh" block 7
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$GH_LOG" ]
}

@test "issue-labels.sh block: a failing gh exits 1" {
  printf '#!/usr/bin/env bash\necho boom >&2; exit 1\n' > "$STUB/gh"
  install_scripts "$TEMP_DIR/install/scripts"; export CREW_INSTALL_DIR="$TEMP_DIR/install"
  run bash "$AFK/issue-labels.sh" block 7
  [ "$status" -eq 1 ]
}
