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
  unset CREW_ORCHESTRATED MAIN_ROOT
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
