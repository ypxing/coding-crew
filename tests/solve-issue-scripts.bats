#!/usr/bin/env bats

# solve-issue's own scripts: preflight.sh (Steps 0, 1, 1.5 and 7's facts in one call) and
# run-checks.sh (Step 5's cached checks, each through dep-install's run.sh).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
PREFLIGHT="$REPO_ROOT/skills/solve-issue/scripts/preflight.sh"
RUN_CHECKS="$REPO_ROOT/skills/solve-issue/scripts/run-checks.sh"
DEP_SCRIPTS="$REPO_ROOT/skills/dep-install/scripts"

setup() {
  TEMP_DIR=$(mktemp -d)
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK/.scratch/feat/issues/open" "$WORK/.scratch/feat/issues/done"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.email t@test
  git -C "$WORK" config user.name T
  git -C "$WORK" commit -q --allow-empty -m init
  git -C "$WORK" checkout -q -b feature
  ISSUE="$WORK/.scratch/feat/issues/open/02-second.md"
  unset CREW_ORCHESTRATED MAIN_ROOT CREW_INSTALL_DIR
}

teardown() {
  rm -rf "$TEMP_DIR"
}

_issue() {
  printf '# Second\n\n## Context Documents\n\n%s\n\n## Blocked by\n\n%s\n\n## Acceptance criteria\n\n- [ ] x\n' "$1" "$2" > "$ISSUE"
}

_preflight() {
  run bash "$PREFLIGHT" --project-root "$WORK" --main-root "$WORK" --issue "$ISSUE"
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

@test "preflight: ORCHESTRATED from the env var or a sprint marker on disk" {
  _issue "" "None"
  _preflight
  [[ "$output" == *"ORCHESTRATED=0"* ]]
  CREW_ORCHESTRATED=1 _preflight
  [[ "$output" == *"ORCHESTRATED=1"* ]]
  touch "$WORK/.scratch/feat/.orchestrated"
  _preflight
  [[ "$output" == *"ORCHESTRATED=1"* ]]
}

@test "preflight: finds dep-install's scripts as a sibling skill, and reports the slug" {
  _issue "" "None"
  _preflight
  [[ "$output" == *"ISSUE_SLUG=02-second"* ]]
  [[ "$output" == *"DEP_SCRIPTS=$DEP_SCRIPTS"* ]]
}

@test "preflight: a sprint's CREW_INSTALL_DIR is used before any other copy" {
  # The orchestrator resolved the install once; the coder uses that copy, not whichever it finds.
  mkdir -p "$TEMP_DIR/install/dep-install"
  cp -R "$DEP_SCRIPTS" "$TEMP_DIR/install/dep-install/scripts"
  _issue "" "None"
  CREW_INSTALL_DIR="$TEMP_DIR/install" _preflight
  [[ "$output" == *"DEP_SCRIPTS=$(cd "$TEMP_DIR/install/dep-install/scripts" && pwd)"* ]]
}

# ─── run-checks.sh ───────────────────────────────────────────────────────────

_cache() {
  mkdir -p "$WORK/.coding-crew"
  printf '%s\n' "$1" > "$WORK/.coding-crew/dev-commands.json"
}

@test "run-checks: no cache means DISCOVER, exit 3" {
  run bash "$RUN_CHECKS" --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 3 ]
  [ "$output" = DISCOVER ]
}

@test "run-checks: runs typecheck, lint, test, then the extra checks, and reports null as NOT RUN" {
  _cache '{"test": "echo T", "lint": null, "coverage": "echo C", "install": "echo I", "typecheck": "echo Y", "install_mode": "host"}'
  run bash "$RUN_CHECKS" --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"typecheck: pass"*"lint: NOT RUN: no command found"*"test: pass"*"coverage: pass"*"CHECKS: pass" ]]
  # install is not a check
  [[ "$output" != *"=== install"* ]]
}

@test "run-checks: one failing check fails the run and does not hide the rest" {
  _cache '{"typecheck": "exit 4", "lint": "echo L", "test": "echo T"}'
  run bash "$RUN_CHECKS" --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"typecheck: fail (exit 4)"*"lint: pass"*"test: pass"*"CHECKS: fail" ]]
}

@test "run-checks: finds the shared cache from a worktree when --main-root is empty" {
  _cache '{"test": "pwd -P", "lint": null, "typecheck": null}'
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m cache
  git -C "$WORK" worktree add -q "$TEMP_DIR/wt" -b wt-branch
  rm -rf "$TEMP_DIR/wt/.coding-crew"
  run bash "$RUN_CHECKS" --project-root "$TEMP_DIR/wt" --main-root "" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(cd "$TEMP_DIR/wt" && pwd -P)"* ]]
}

# The same rule, and the same line, as crew-afk's verify gate — so a coder sees its verdict.
_committed_src() {
  mkdir -p "$WORK/src"
  printf 'a = 1\n' > "$WORK/src/app.py"
  printf 'coverage/\n.coding-crew/\n' > "$WORK/.gitignore"
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m src
}

@test "run-checks: a check that edits a tracked file fails, naming the file" {
  _committed_src
  _cache '{"test": "true", "lint": "echo fixed >> src/app.py", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lint: modified files: src/app.py — configure a non-mutating command in .coding-crew/dev-commands.json"* ]]
  [[ "$output" == *"lint: fail"*"test: pass"*"CHECKS: fail" ]]
}

@test "run-checks: an ignored file written by a check, or dirt already there, is not a modification" {
  _committed_src
  printf 'b = 2\n' >> "$WORK/src/app.py"
  _cache '{"test": "mkdir -p coverage && echo 90 > coverage/lcov.info", "lint": "true", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
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

@test "preflight: a failing Requires command blocks a direct run" {
  { printf '# Second\n\n## Requires\n\n- `echo no token; exit 1`\n\n## Blocked by\n\nNone\n'; } > "$ISSUE"
  _preflight
  [ "$status" -eq 1 ]
  [[ "${lines[0]}" == "BLOCKED: requires: echo no token; exit 1" ]]
  [[ "$output" == *"  | no token"* ]]
}

@test "preflight: Requires is not run again when orchestrated — the orchestrator already did" {
  { printf '# Second\n\n## Requires\n\n- `touch %s/ran; exit 1`\n\n## Blocked by\n\nNone\n' "$TEMP_DIR"; } > "$ISSUE"
  CREW_ORCHESTRATED=1 _preflight
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/ran" ]
}
