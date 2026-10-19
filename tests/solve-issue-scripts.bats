#!/usr/bin/env bats

# solve-issue's own scripts: preflight.sh (Steps 0, 1, 1.5 and 7's facts in one call) and
# run-checks.sh (Step 5's cached checks, each through the checks library's run.sh).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
RUN_CHECKS="$REPO_ROOT/lib/checks/run-checks.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  # solve-issue's scripts/ as installed: its own scripts, and the checks library its committed link points to.
  mkdir -p "$TEMP_DIR/skill/scripts"
  cp "$REPO_ROOT"/skills/solve-issue/scripts/*.sh "$TEMP_DIR/skill/scripts/"
  cp -RL "$REPO_ROOT/skills/solve-issue/scripts/checks" "$TEMP_DIR/skill/scripts/checks"
  PREFLIGHT="$TEMP_DIR/skill/scripts/preflight.sh"
  WORK="$TEMP_DIR/work"
  mkdir -p "$WORK/.coding-crew/scratch/feat/issues/open" "$WORK/.coding-crew/scratch/feat/issues/done"
  git -C "$WORK" init -q -b main
  git -C "$WORK" config user.email t@test
  git -C "$WORK" config user.name T
  git -C "$WORK" commit -q --allow-empty -m init
  git -C "$WORK" checkout -q -b feature
  ISSUE="$WORK/.coding-crew/scratch/feat/issues/open/02-second.md"
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
  _issue "" '- Issue 01: `.coding-crew/scratch/feat/issues/open/01-first.md`'
  _preflight
  [ "$status" -eq 1 ]
  [ "$output" = "BLOCKED: depends on 01-first.md which is not yet done" ]
  touch "$WORK/.coding-crew/scratch/feat/issues/done/01-first.md"
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

@test "preflight: a PRD under .coding-crew/scratch is found in the checkout that holds the issue, not --project-root" {
  mkdir -p "$TEMP_DIR/wt"
  touch "$WORK/.coding-crew/scratch/feat/PRD.md"
  _issue '- PRD: `.coding-crew/scratch/feat/PRD.md`' "None"
  run bash "$PREFLIGHT" --project-root "$TEMP_DIR/wt" --issue "$ISSUE"
  [[ "$output" == *"PRD=$WORK/.coding-crew/scratch/feat/PRD.md"* ]]
}

@test "preflight: a relative issue ref in a linked worktree resolves in the main checkout, where .coding-crew/scratch/ lives" {
  git -C "$WORK" worktree add -q -b wt-branch "$TEMP_DIR/wt"
  touch "$WORK/.coding-crew/scratch/feat/PRD.md"
  _issue '- PRD: `.coding-crew/scratch/feat/PRD.md`' '- Issue 01: `.coding-crew/scratch/feat/issues/open/01-first.md`'
  run bash -c 'cd "$1" && bash "$2" --project-root "$1" --issue .coding-crew/scratch/feat/issues/open/02-second.md' _ "$TEMP_DIR/wt" "$PREFLIGHT"
  [ "$status" -eq 1 ]
  [ "$output" = "BLOCKED: depends on 01-first.md which is not yet done" ]
  touch "$WORK/.coding-crew/scratch/feat/issues/done/01-first.md"
  run bash -c 'cd "$1" && bash "$2" --project-root "$1" --issue .coding-crew/scratch/feat/issues/open/02-second.md' _ "$TEMP_DIR/wt" "$PREFLIGHT"
  [ "$status" -eq 0 ]
  # git names the main checkout by its physical path: macOS's /var is /private/var.
  [[ "$output" == *"PRD=$(cd "$WORK" && pwd -P)/.coding-crew/scratch/feat/PRD.md"* ]]
}

@test "preflight: the PRD is the one Context Documents names; without a PRD line there is none, whatever .coding-crew/scratch holds" {
  mkdir -p "$WORK/docs"
  touch "$WORK/docs/prd.md" "$WORK/.coding-crew/scratch/feat/PRD.md"
  _issue '- PRD: `docs/prd.md`' "None"
  _preflight
  [[ "$output" == *"PRD=$WORK/docs/prd.md"* ]]
  _issue '- PRD: docs/prd.md' "None"
  _preflight
  [[ "$output" == *"PRD=$WORK/docs/prd.md"* ]]
  _issue "" "None"
  _preflight
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\nPRD=' ]]
}

@test "preflight: a Requires section is ignored, even when its command fails" {
  { printf '# Second\n\n## Requires\n\n- `echo no token; exit 1`\n\n## Blocked by\n\nNone\n'; } > "$ISSUE"
  _preflight
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'OK\nISSUE_SLUG=02-second\nPRD=')" ]
}

@test "preflight: reports the slug and PRD only, and stops when the checks library is missing from scripts/checks" {
  _issue "" "None"
  _preflight
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'OK\nISSUE_SLUG=02-second\nPRD=')" ]
  rm -r "$TEMP_DIR/skill/scripts/checks"
  _preflight
  [ "$status" -eq 1 ]
  [ "$output" = "BLOCKED: checks library missing from scripts/checks — re-install coding-crew" ]
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

@test "run-checks: registry_auth and a key it does not know are never run as checks" {
  _cache "{\"test\": \"echo T\", \"registry_auth\": \"touch $TEMP_DIR/auth\", \"old_key\": \"touch $TEMP_DIR/old\"}"
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/auth" ] && [ ! -e "$TEMP_DIR/old" ]
  [[ "$output" != *registry_auth* && "$output" != *old_key* ]]
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

@test "run-checks: a worktree runs its branch's committed checks, else the main checkout's, in the worktree" {
  _cache '{"test": "echo branch-copy && pwd -P", "lint": null, "typecheck": null}'
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m cache
  git -C "$WORK" worktree add -q "$TEMP_DIR/wt" -b wt-branch
  _cache '{"test": "echo main-copy", "lint": null, "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$TEMP_DIR/wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *branch-copy*"$(cd "$TEMP_DIR/wt" && pwd -P)"* ]]
  [[ "$output" != *main-copy* ]]

  git -C "$TEMP_DIR/wt" rm -q .coding-crew/dev-commands.json && git -C "$TEMP_DIR/wt" commit -q -m untrack
  _cache '{"test": "pwd -P", "lint": null, "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$TEMP_DIR/wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(cd "$TEMP_DIR/wt" && pwd -P)"* ]]
  rm -f "$WORK/.coding-crew/dev-commands.json"
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


