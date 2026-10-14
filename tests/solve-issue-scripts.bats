#!/usr/bin/env bats

# solve-issue's own scripts: preflight.sh (Steps 0, 1, 1.5 and 7's facts in one call) and
# run-checks.sh (Step 5's cached checks, each through the checks library's run.sh).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
RUN_CHECKS="$REPO_ROOT/lib/checks/run-checks.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  # solve-issue's scripts/ as install.sh lays it out: its own scripts, and the checks library linked in.
  mkdir -p "$TEMP_DIR/skill/scripts"
  cp "$REPO_ROOT"/skills/solve-issue/scripts/*.sh "$TEMP_DIR/skill/scripts/"
  ln -s "$REPO_ROOT/lib/checks" "$TEMP_DIR/skill/scripts/checks"
  PREFLIGHT="$TEMP_DIR/skill/scripts/preflight.sh"
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK/.scratch/feat/issues/open" "$WORK/.scratch/feat/issues/done"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.email t@test
  git -C "$WORK" config user.name T
  git -C "$WORK" commit -q --allow-empty -m init
  git -C "$WORK" checkout -q -b feature
  ISSUE="$WORK/.scratch/feat/issues/open/02-second.md"
}

teardown() {
  rm -rf "$TEMP_DIR"
}

_issue() {
  printf '# Second\n\n## Context Documents\n\n%s\n\n## Blocked by\n\n%s\n\n## Acceptance criteria\n\n- [ ] x\n' "$1" "$2" > "$ISSUE"
}

_preflight() {
  run bash "$PREFLIGHT" --project-root "$WORK" --issue "$ISSUE"
}

# ─── preflight.sh ────────────────────────────────────────────────────────────

@test "preflight: stops on the default branch before anything else" {
  git -C "$WORK" checkout -q main
  _issue "" "None - can start immediately"
  _preflight
  [ "$status" -eq 1 ]
  [ "$output" = "BLOCKED: on default branch (main) — create or switch to a feature branch first" ]
}

@test "preflight: a Blocked-by file missing from done/ blocks, by file name" {
  _issue "" '- Issue 01: `.scratch/feat/issues/open/01-first.md`'
  _preflight
  [ "$status" -eq 1 ]
  [ "$output" = "BLOCKED: depends on 01-first.md which is not yet done" ]
  touch "$WORK/.scratch/feat/issues/done/01-first.md"
  _preflight
  [ "$status" -eq 0 ]
  [[ "$output" == OK* ]]
}

@test "preflight: 'None' and GitHub issue numbers name no file to wait for" {
  _issue "" "None - can start immediately"
  _preflight
  [ "$status" -eq 0 ]
  _issue "" "- Issue #12"
  _preflight
  [ "$status" -eq 0 ]
}

@test "preflight: a PRD under .scratch is found in the checkout that holds the issue, not --project-root" {
  mkdir -p "$TEMP_DIR/wt"
  touch "$WORK/.scratch/feat/PRD.md"
  _issue "" "None"
  run bash "$PREFLIGHT" --project-root "$TEMP_DIR/wt" --issue "$ISSUE"
  [[ "$output" == *"PRD=$WORK/.scratch/feat/PRD.md"* ]]
}

@test "preflight: a relative issue ref in a linked worktree resolves in the main checkout, where .scratch/ lives" {
  git -C "$WORK" worktree add -q -b wt-branch "$TEMP_DIR/wt"
  touch "$WORK/.scratch/feat/PRD.md"
  _issue "" '- Issue 01: `.scratch/feat/issues/open/01-first.md`'
  run bash -c 'cd "$1" && bash "$2" --project-root "$1" --issue .scratch/feat/issues/open/02-second.md' _ "$TEMP_DIR/wt" "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [ "$output" = "BLOCKED: depends on 01-first.md which is not yet done" ]
  touch "$WORK/.scratch/feat/issues/done/01-first.md"
  run bash -c 'cd "$1" && bash "$2" --project-root "$1" --issue .scratch/feat/issues/open/02-second.md' _ "$TEMP_DIR/wt" "$PREFLIGHT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRD=$WORK/.scratch/feat/PRD.md"* ]]
}

@test "preflight: --main-root is an unknown argument" {
  _issue "" "None"
  run bash "$PREFLIGHT" --project-root "$WORK" --main-root "$WORK" --issue "$ISSUE"
  [ "$status" -eq 2 ]
}

@test "preflight: the PRD comes from Context Documents first, then the feature slug" {
  mkdir -p "$WORK/docs"
  touch "$WORK/docs/prd.md" "$WORK/.scratch/feat/PRD.md"
  _issue '- PRD: `docs/prd.md`' "None"
  _preflight
  [[ "$output" == *"PRD=$WORK/docs/prd.md"* ]]
  _issue "" "None"
  _preflight
  [[ "$output" == *"PRD=$WORK/.scratch/feat/PRD.md"* ]]
  rm "$WORK/.scratch/feat/PRD.md"
  _preflight
  [[ "$output" == *$'\nPRD=\n'* ]]
}

@test "preflight: finds the checks library through its scripts/checks link, and reports the slug" {
  _issue "" "None"
  _preflight
  [[ "$output" == *"ISSUE_SLUG=02-second"* ]]
  [ "${lines[${#lines[@]}-1]}" = "DEP_SCRIPTS=$TEMP_DIR/skill/scripts/checks" ]
  rm "$TEMP_DIR/skill/scripts/checks"
  _preflight
  [ "${lines[${#lines[@]}-1]}" = "DEP_SCRIPTS=" ]
}

# ─── run-checks.sh ───────────────────────────────────────────────────────────

_cache() {
  mkdir -p "$WORK/.coding-crew"
  printf '%s\n' "$1" > "$WORK/.coding-crew/dev-commands.json"
}

@test "run-checks: no cache means DISCOVER, exit 3" {
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 3 ]
  [ "$output" = DISCOVER ]
}

@test "run-checks: runs typecheck, lint, test, then the extra checks, and reports null as NOT RUN" {
  _cache '{"test": "echo T", "lint": null, "coverage": "echo C", "install": "echo I", "typecheck": "echo Y", "install_mode": "host"}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"typecheck: pass"*"lint: NOT RUN: no command found"*"test: pass"*"coverage: pass"*"CHECKS: pass" ]]
  # install is not a check
  [[ "$output" != *"=== install"* ]]
}

@test "run-checks: each check writes its log through a pipe, and reports its own exit code" {
  # a log file on overlayfs can hang a bats load error forever (#266); a pipe never does
  _cache '{"typecheck": null, "lint": "if [ -p /dev/stdout ]; then echo PIPED; else echo FILE; fi; exit 3", "test": "echo T"}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PIPED"*"lint: fail (exit 3)"*"test: pass"*"CHECKS: fail" ]] || { echo "$output"; return 1; }
  log="$(printf '%s\n' "$output" | sed -n 's/^lint: log: //p')"
  grep -qx PIPED "$log"
}

@test "run-checks: one failing check fails the run and does not hide the rest" {
  _cache '{"typecheck": "exit 4", "lint": "echo L", "test": "echo T"}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"typecheck: fail (exit 4)"*"lint: pass"*"test: pass"*"CHECKS: fail" ]]
}

@test "run-checks: a worktree runs its own committed checks, not the main checkout's" {
  _cache '{"test": "pwd -P", "lint": null, "typecheck": null}'
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m cache
  git -C "$WORK" worktree add -q "$TEMP_DIR/wt" -b wt-branch
  _cache '{"test": "echo main-checkout", "lint": null, "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$TEMP_DIR/wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(cd "$TEMP_DIR/wt" && pwd -P)"* ]]
  [[ "$output" != *main-checkout* ]]
  rm -rf "$TEMP_DIR/wt/.coding-crew"
  run bash "$RUN_CHECKS" --project-root "$TEMP_DIR/wt"
  [ "$status" -eq 3 ]
  [ "$output" = DISCOVER ]
}

# A check must leave the tree as it found it.
_committed_src() {
  mkdir -p "$WORK/src"
  printf 'a = 1\n' > "$WORK/src/app.py"
  printf 'coverage/\n.coding-crew/\n' > "$WORK/.gitignore"
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m src
}

@test "run-checks: a check that edits a tracked file fails, naming the file" {
  _committed_src
  _cache '{"test": "true", "lint": "echo fixed >> src/app.py", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lint: modified files: src/app.py — the check rewrote them: run it, commit the result, and re-run"* ]]
  [[ "$output" == *"lint: fail"*"test: pass"*"CHECKS: fail" ]]
}

@test "run-checks: an ignored file written by a check, or dirt already there, is not a modification" {
  _committed_src
  printf 'b = 2\n' >> "$WORK/src/app.py"
  _cache '{"test": "mkdir -p coverage && echo 90 > coverage/lcov.info", "lint": "true", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" != *"modified files"* ]]
}

# ─── check-requires.sh ───────────────────────────────────────────────────────
# An issue's `## Requires`: what its checks need that the install does not guarantee, as one
# command per bullet. A sprint once paid two coders $6 to rediscover an unset license token.

CHECK_REQUIRES="$REPO_ROOT/skills/solve-issue/scripts/check-requires.sh"

_requires_issue() {  # <file> <command>...
  local f="$1"; shift
  { printf '# X\n\n## Requires\n\n'; for c in "$@"; do printf -- '- `%s`\n' "$c"; done
    printf '\n## Acceptance criteria\n\n- [ ] `false` is not a requirement\n'; } > "$f"
}

@test "check-requires: every command passing is a pass per command, exit 0" {
  _requires_issue "$TEMP_DIR/a.md" "true" "test -d ."
  run bash "$CHECK_REQUIRES" --project-root "$WORK" --issue "$TEMP_DIR/a.md"
  [ "$status" -eq 0 ]
  [ "$output" = "REQUIRE: pass $TEMP_DIR/a.md true"$'\n'"REQUIRE: pass $TEMP_DIR/a.md test -d ." ]
}

@test "check-requires: a failing command fails with its exit and output tail, from the project root" {
  _requires_issue "$TEMP_DIR/a.md" 'pwd -P; echo License activation failed; exit 3'
  run bash "$CHECK_REQUIRES" --project-root "$WORK" --issue "$TEMP_DIR/a.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REQUIRE: fail $TEMP_DIR/a.md pwd -P; echo License activation failed; exit 3"* ]]
  [[ "$output" == *"  exit 3"* ]]
  [[ "$output" == *"  | $(cd "$WORK" && pwd -P)"* ]]
  [[ "$output" == *"  | License activation failed"* ]]
}

@test "check-requires: an issue with no Requires section passes silently" {
  printf '# X\n\n## Acceptance criteria\n\n- [ ] `false`\n' > "$TEMP_DIR/a.md"
  run bash "$CHECK_REQUIRES" --project-root "$WORK" --issue "$TEMP_DIR/a.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check-requires: a command two issues share runs once, and both get its verdict" {
  _requires_issue "$TEMP_DIR/a.md" "echo x >> $TEMP_DIR/ran; exit 1"
  _requires_issue "$TEMP_DIR/b.md" "echo x >> $TEMP_DIR/ran; exit 1" "true"
  run bash "$CHECK_REQUIRES" --project-root "$WORK" --issue "$TEMP_DIR/a.md" --issue "$TEMP_DIR/b.md"
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$TEMP_DIR/ran" | tr -d ' ')" = 1 ]
  [[ "$output" == *"REQUIRE: fail $TEMP_DIR/a.md echo x"* ]]
  [[ "$output" == *"REQUIRE: fail $TEMP_DIR/b.md echo x"* ]]
  [[ "$output" == *"REQUIRE: pass $TEMP_DIR/b.md true"* ]]
}

@test "check-requires: a command past --timeout fails as timed out" {
  _requires_issue "$TEMP_DIR/a.md" "sleep 30"
  run bash "$CHECK_REQUIRES" --project-root "$WORK" --issue "$TEMP_DIR/a.md" --timeout 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"REQUIRE: fail $TEMP_DIR/a.md sleep 30"*"timed out after 1s"* ]]
}

# A PATH with every command but timeout/gtimeout: the fallback stock macOS takes.
_path_without_timeout() {
  local bin="$TEMP_DIR/no-timeout-bin" dir f
  mkdir -p "$bin"
  IFS=: read -ra dirs <<< "$PATH"
  for dir in "${dirs[@]}"; do
    for f in "$dir"/*; do
      case "${f##*/}" in timeout|gtimeout) continue ;; esac
      [ -x "$f" ] && [ ! -e "$bin/${f##*/}" ] && ln -s "$f" "$bin/${f##*/}"
    done
  done
  printf '%s' "$bin"
}

@test "check-requires: a timeout stops the command's own children too, with or without timeout(1)" {
  local path paths=("$PATH")
  # Not on Git Bash: it always ships timeout(1), and its `ln -s` copies each file, so mirroring
  # a PATH that includes System32 never finishes — that is what hung the Windows shard.
  case "$OSTYPE" in msys*|cygwin*) ;; *) paths+=("$(_path_without_timeout)") ;; esac
  for path in "${paths[@]}"; do
    rm -f "$TEMP_DIR/pid"
    _requires_issue "$TEMP_DIR/a.md" "sleep 31 & echo \$! > $TEMP_DIR/pid; wait"
    PATH="$path" run bash "$CHECK_REQUIRES" --project-root "$WORK" --issue "$TEMP_DIR/a.md" --timeout 1
    [ "$status" -eq 1 ]
    [[ "$output" == *"timed out after 1s"* ]]
    sleep 1
    ! kill -0 "$(cat "$TEMP_DIR/pid")" 2>/dev/null
  done
}

@test "preflight: a failing Requires command blocks a direct run" {
  { printf '# Second\n\n## Requires\n\n- `echo no token; exit 1`\n\n## Blocked by\n\nNone\n'; } > "$ISSUE"
  _preflight
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == "BLOCKED: requires: echo no token; exit 1" ]]
  [[ "$output" == *"  | no token"* ]]
}

