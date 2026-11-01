#!/usr/bin/env bats

# solve-issue's own scripts: preflight.sh (Steps 0, 1, 1.5 and 7's facts in one call) and
# run-checks.sh (Step 5's cached checks, each through the checks library's run.sh).

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")" && pwd)"
RUN_CHECKS="$REPO_ROOT/lib/checks/run-checks.sh"

setup() {
  TEMP_DIR=$(mktemp -d)
  # solve-issue's scripts/ as installed: its own scripts, and the checks library in the coding-crew-lib skill beside it.
  mkdir -p "$TEMP_DIR/skills/solve-issue/scripts" "$TEMP_DIR/skills/coding-crew-lib/scripts"
  cp "$REPO_ROOT"/skills/solve-issue/scripts/*.sh "$TEMP_DIR/skills/solve-issue/scripts/"
  cp -RL "$REPO_ROOT/skills/coding-crew-lib/scripts/checks" "$TEMP_DIR/skills/coding-crew-lib/scripts/checks"
  PREFLIGHT="$TEMP_DIR/skills/solve-issue/scripts/preflight.sh"
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

@test "preflight: reports the slug and PRD only, and stops naming the coding-crew-lib skill and its install when the checks library is missing" {
  _issue "" "None"
  _preflight
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'OK\nISSUE_SLUG=02-second\nPRD=')" ]
  rm -r "$TEMP_DIR/skills/coding-crew-lib"
  _preflight
  [ "$status" -eq 1 ]
  [[ "$output" == "BLOCKED: checks library missing from the coding-crew-lib skill"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"npx skills add <that source> -s coding-crew-lib"* ]] || { echo "$output"; return 1; }
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

@test "run-checks: a log dir it cannot create (a full disk) fails before any check runs, naming the dir, not as a check's failure" {
  _cache "{\"test\": \"touch $TEMP_DIR/ran\"}"
  TMPDIR="$TEMP_DIR/missing" run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ]
  [ ! -e "$TEMP_DIR/ran" ]
  [[ "$output" == *"cannot create a log dir under $TEMP_DIR/missing"*"no check ran"*"CHECKS: fail" ]] || { echo "$output"; return 1; }
  [[ "$output" != *"test: fail"* ]]
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

@test "run-checks: a rewrite that settles passes: every check runs a second time on the rewritten tree, the rewrite stays and is named" {
  _committed_src
  _cache "{\"typecheck\": \"echo Y >> $TEMP_DIR/runs\", \"lint\": \"printf 'a=1\\\\n' > src/app.py\", \"test\": \"echo T >> $TEMP_DIR/runs\"}"
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | grep -c '^lint: rewrote: ')" -eq 1 ]
  [[ "$output" == *"lint: rewrote: src/app.py"*"CHECKS: pass" ]] || { echo "$output"; return 1; }
  [[ "$output" != *"modified files"* ]]
  [ "$(cat "$WORK/src/app.py")" = "a=1" ]
  [ "$(tr '\n' ' ' < "$TEMP_DIR/runs")" = "Y T Y T " ]
}

@test "run-checks: no rewrite, no second pass" {
  _committed_src
  _cache "{\"typecheck\": null, \"lint\": \"true\", \"test\": \"echo T >> $TEMP_DIR/runs\"}"
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [ "$(cat "$TEMP_DIR/runs")" = T ]
  [[ "$output" != *"rewrote"* ]]
}

@test "run-checks: a check that rewrites a file differently on every run fails in the second pass, naming a non-mutating command as the fix" {
  _committed_src
  _cache '{"test": "true", "lint": "echo fixed >> src/app.py", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lint: modified files: src/app.py — the check rewrote them again on a second run: name a non-mutating command for it in $(cd "$WORK" && pwd -P)/.coding-crew/dev-commands.json"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"lint: rewrote: src/app.py"*"CHECKS: fail" ]] || { echo "$output"; return 1; }
}

@test "run-checks: a rewrite of a file already dirty is still a rewrite: named when it settles, failed when it never does" {
  _committed_src
  printf 'b = 2\n' >> "$WORK/src/app.py"
  _cache '{"test": "true", "lint": "echo fixed >> src/app.py", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"lint: modified files: src/app.py — the check rewrote them again"* ]] || { echo "$output"; return 1; }

  _cache "{\"test\": \"true\", \"lint\": \"printf 'a=1\\\\n' > src/app.py\", \"typecheck\": null}"
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"lint: rewrote: src/app.py"$'\n'"CHECKS: pass" ]] || { echo "$output"; return 1; }
}

@test "run-checks: a file whose name has a space or a non-ASCII character is named as written and still gated in the second pass" {
  _committed_src
  printf 'a\n' > "$WORK/src/é b.py"
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m names
  _cache '{"test": "true", "lint": "echo fixed >> \"src/é b.py\"", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"lint: modified files: src/é b.py — the check rewrote them again"* ]] || { echo "$output"; return 1; }

  git -C "$WORK" checkout -q -- .
  _cache '{"test": "true", "lint": "printf \"b\\\\n\" > \"src/é b.py\"", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"lint: rewrote: src/é b.py"$'\n'"CHECKS: pass" ]] || { echo "$output"; return 1; }
}

@test "run-checks: a check that fails in the second pass fails the run, whatever it rewrote" {
  _committed_src
  _cache "{\"typecheck\": null, \"lint\": \"printf 'a=1\\\\n' > src/app.py\", \"test\": \"[ ! -f $TEMP_DIR/ran ] && touch $TEMP_DIR/ran\"}"
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"test: fail (exit 1)"*"lint: rewrote: src/app.py"*"CHECKS: fail" ]] || { echo "$output"; return 1; }
}

@test "run-checks: a file a check creates that git does not ignore fails as modified files, never as a rewrite" {
  _committed_src
  _cache '{"test": "true", "lint": "echo report > report.txt", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lint: modified files: report.txt"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"lint: fail"*"test: pass"*"CHECKS: fail" ]]
  [[ "$output" != *"rewrote:"* ]]
}

@test "run-checks: a tracked file a check deletes fails as modified files, never as a rewrite" {
  _committed_src
  _cache '{"test": "true", "lint": "rm -f src/app.py", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" == *"lint: modified files: src/app.py"* ]] || { echo "$output"; return 1; }
  [[ "$output" != *"rewrote:"* ]]
}

@test "run-checks: an ignored file written by a check, or dirt already there, is not a modification" {
  _committed_src
  printf 'b = 2\n' >> "$WORK/src/app.py"
  _cache '{"test": "mkdir -p coverage && echo 90 > coverage/lcov.info", "lint": "true", "typecheck": null}'
  run bash "$RUN_CHECKS" --project-root "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" != *"modified files"* ]]
}


