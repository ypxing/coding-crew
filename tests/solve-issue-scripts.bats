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
  unset CREW_ORCHESTRATED MAIN_ROOT CREW_INSTALL_DIR CREW_DEFER_FULL_CHECKS
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

@test "run-checks: CREW_DEFER_FULL_CHECKS=1 runs typecheck and lint, defers test and coverage, keeps null NOT RUN" {
  _cache '{"typecheck": "echo Y", "lint": "echo L", "test": "touch $PWD/ran-test", "coverage": "touch $PWD/ran-cov", "integration": null}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"typecheck: pass"*"lint: pass"*"test: deferred"*"coverage: deferred"*"integration: NOT RUN: no command found"*"CHECKS: pass" ]]
  [ ! -e "$WORK/ran-test" ] && [ ! -e "$WORK/ran-cov" ]
}

@test "run-checks: CREW_DEFER_FULL_CHECKS=1 still fails when lint fails" {
  _cache '{"typecheck": "echo Y", "lint": "exit 2", "test": "echo T"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"test: deferred"*"CHECKS: fail" ]]
}

@test "run-checks: --targeted under deferral runs only the changed test files and says so" {
  mkdir -p "$WORK/tests"
  : > "$WORK/tests/old.bats"; : > "$WORK/tests/mine.bats"
  git -C "$WORK" add -A && git -C "$WORK" commit -q -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/tests/mine.bats"
  _cache '{"typecheck": null, "lint": null, "test": "echo RAN tests/*.bats"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN tests/mine.bats"* ]]
  [[ "$output" != *"old.bats"* ]]
  [[ "$output" == *"test: pass (targeted)"* ]]
}

@test "run-checks: --targeted keeps a wrapper script and cd target, replacing only the suite paths" {
  mkdir -p "$WORK/sub/tests" "$WORK/scripts"
  : > "$WORK/sub/tests/old.bats"
  printf 'for f; do [ -f "$f" ] || exit 9; done; echo WRAP "$@"\n' > "$WORK/scripts/test.sh"
  git -C "$WORK" add -A; git -C "$WORK" commit -q -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/sub/tests/new.bats"
  _cache '{"typecheck": null, "lint": null, "test": "cd sub && bash ../scripts/test.sh tests"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  # the files are passed relative to the cd target, so the runner finds them from there
  [[ "$output" == *"cd sub && bash ../scripts/test.sh tests/new.bats"* ]]
  [[ "$output" == *"WRAP tests/new.bats"* ]]
}

@test "run-checks: --targeted passes a changed test outside the cd target as an absolute path" {
  mkdir -p "$WORK/sub" "$WORK/tests"
  git -C "$WORK" add -A; git -C "$WORK" commit -q --allow-empty -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/tests/new.bats"
  _cache '{"typecheck": null, "lint": null, "test": "cd sub && ls"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd sub && ls $WORK/tests/new.bats"* ]]
}

@test "run-checks: --targeted keeps a wrapper script that lives under a test dir" {
  mkdir -p "$WORK/tests"
  printf 'echo WRAP "$@"\n' > "$WORK/tests/run.sh"
  git -C "$WORK" add -A; git -C "$WORK" commit -q --allow-empty -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/tests/new.bats"
  _cache '{"typecheck": null, "lint": null, "test": "bash tests/run.sh"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bash tests/run.sh tests/new.bats"* ]]
  [[ "$output" == *"WRAP tests/new.bats"* ]]
}

@test "run-checks: --targeted reports fail (targeted) when the changed tests fail" {
  mkdir -p "$WORK/tests"
  git -C "$WORK" commit -q --allow-empty -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/tests/new.bats"
  _cache '{"typecheck": null, "lint": null, "test": "false"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"test: fail (targeted, exit 1)"* ]]
}

@test "run-checks: --targeted with no changed test file is deferred and runs nothing" {
  git -C "$WORK" branch -f main
  echo x > "$WORK/app.py"
  _cache '{"typecheck": null, "lint": null, "test": "touch $PWD/ran-test"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test: deferred"* ]]
  [ ! -e "$WORK/ran-test" ]
}

@test "run-checks: --targeted measures from CREW_BASE_REF, so a feature branch's own tests are not the issue's" {
  mkdir -p "$WORK/tests"
  # setup() left WORK on `feature`: main is cut here, the feature adds its own test.
  git -C "$WORK" commit -q --allow-empty -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/tests/feat.bats"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m feat
  git -C "$WORK" checkout -q -b issue
  echo x > "$WORK/tests/mine.bats"; git -C "$WORK" add -A; git -C "$WORK" commit -q -m mine
  _cache '{"typecheck": null, "lint": null, "test": "echo RAN tests/*.bats"}'
  CREW_BASE_REF=feature CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN tests/mine.bats"* ]]
  [[ "$output" != *"feat.bats"* ]]
}

@test "run-checks: --targeted passes test files only, never a helper or fixture under a test dir" {
  mkdir -p "$WORK/tests/helpers" "$WORK/tests/fixtures" "$WORK/tests/orchestrator"
  git -C "$WORK" commit -q --allow-empty -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/tests/helpers/h.bash"; echo x > "$WORK/tests/fixtures/f.jsonl"
  echo x > "$WORK/tests/orchestrator/lib.mjs"; echo x > "$WORK/tests/orchestrator/x.test.mjs"
  echo x > "$WORK/tests/fixtures/case.test.js"
  _cache '{"typecheck": null, "lint": null, "test": "echo RAN"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RAN tests/orchestrator/x.test.mjs"* ]]
  [[ "$output" != *"h.bash"* && "$output" != *"f.jsonl"* && "$output" != *"lib.mjs"* && "$output" != *"case.test.js"* ]]
}

@test "run-checks: --targeted recognises mocha, phpunit, nested jest and colocated tests outside a test tree" {
  mkdir -p "$WORK/test" "$WORK/tests" "$WORK/src/__tests__/sub" "$WORK/src/helpers"
  git -C "$WORK" commit -q --allow-empty -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/test/app.js"; echo x > "$WORK/tests/FooTest.php"
  echo x > "$WORK/src/__tests__/sub/b.js"; echo x > "$WORK/src/helpers/format.test.ts"
  _cache '{"typecheck": null, "lint": null, "test": "echo RAN"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  for f in test/app.js tests/FooTest.php src/__tests__/sub/b.js src/helpers/format.test.ts; do
    [[ "$output" == *"$f"* ]] || { echo "missing $f: $output"; return 1; }
  done
}

@test "run-checks: --targeted passes only the changed files the suite argument it replaces selects" {
  mkdir -p "$WORK/tests/orchestrator"
  git -C "$WORK" commit -q --allow-empty -m base && git -C "$WORK" branch -f main
  printf '@test "x" { true; }\n' > "$WORK/tests/x.bats"
  echo 'import "node:test";' > "$WORK/tests/orchestrator/y.test.mjs"
  _cache '{"typecheck": null, "lint": null, "test": "bats tests/*.bats"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *$'=== test: bats tests/x.bats\n'* ]]
  [[ "$output" != *"y.test.mjs"* ]]
  [[ "$output" == *"test: pass (targeted)"* ]]
}

@test "run-checks: --targeted matches a glob the way the shell would, and a directory by what it holds" {
  mkdir -p "$WORK/tests/sub" "$WORK/src/a/b" "$WORK/spec"
  git -C "$WORK" commit -q --allow-empty -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/tests/top.bats"; echo x > "$WORK/tests/sub/deep.bats"
  echo x > "$WORK/src/a/b/c.test.ts"; echo x > "$WORK/src/d.test.ts"; echo x > "$WORK/spec/e_spec.rb"
  # `*` stays inside one directory; `**/` spans any number of them, none included
  _cache "{\"typecheck\": null, \"lint\": null, \"test\": \"echo RAN tests/*.bats 'src/**/*.test.ts' spec\"}"
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  for f in tests/top.bats src/a/b/c.test.ts src/d.test.ts spec/e_spec.rb; do
    [[ "$output" == *"RAN"*"$f"* ]] || { echo "missing $f: $output"; return 1; }
  done
  [[ "$output" != *"deep.bats"* ]]
}

@test "run-checks: --targeted defers, running nothing, when no changed test file is one the suite argument selects" {
  mkdir -p "$WORK/tests/orchestrator"
  git -C "$WORK" commit -q --allow-empty -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/tests/orchestrator/y.test.mjs"
  _cache '{"typecheck": null, "lint": null, "test": "touch $PWD/ran-test tests/*.bats"}'
  CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"test: deferred (no changed test file the test command's suite arguments select)"* ]]
  [[ "$output" != *"=== test"* ]]
  [ ! -e "$WORK/ran-test" ]
}

@test "run-checks: each check writes its log through a pipe, and reports its own exit code" {
  # a log file on overlayfs can hang a bats load error forever (#266); a pipe never does
  _cache '{"typecheck": null, "lint": "if [ -p /dev/stdout ]; then echo PIPED; else echo FILE; fi; exit 3", "test": "echo T"}'
  run bash "$RUN_CHECKS" --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"PIPED"*"lint: fail (exit 3)"*"test: pass"*"CHECKS: fail" ]] || { echo "$output"; return 1; }
  log="$(printf '%s\n' "$output" | sed -n 's/^lint: log: //p')"
  grep -qx PIPED "$log"
}

@test "run-checks: --targeted defers a runner that takes no test file arguments (make, go, cargo)" {
  mkdir -p "$WORK/tests"
  git -C "$WORK" commit -q --allow-empty -m base && git -C "$WORK" branch -f main
  echo x > "$WORK/tests/new_test.go"
  for runner in "make test" "go test ./..." "cargo test" "cd sub; make test" "env CI=1 cargo test" "bundle exec rake test"; do
    _cache "{\"typecheck\": null, \"lint\": null, \"test\": \"$runner\"}"
    CREW_DEFER_FULL_CHECKS=1 run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
    [ "$status" -eq 0 ] || { echo "$runner: $output"; return 1; }
    [[ "$output" == *"test: deferred (the test command takes no test file arguments)"* ]] || { echo "$runner: $output"; return 1; }
    [[ "$output" != *"=== test"* ]]
  done
}

@test "run-checks: --targeted without CREW_DEFER_FULL_CHECKS still runs the full suite" {
  mkdir -p "$WORK/tests"; echo x > "$WORK/tests/new.bats"
  _cache '{"typecheck": null, "lint": null, "test": "echo FULL tests/*.bats"}'
  run bash "$RUN_CHECKS" --targeted --project-root "$WORK" --main-root "$WORK" --dep-scripts "$DEP_SCRIPTS"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FULL tests/*.bats"* ]]
  [[ "$output" == *"test: pass"* && "$output" != *"(targeted)"* ]]
}

@test "solve-issue SKILL.md names the targeted mode and leaves the full suite to the verify gate" {
  run grep -E -- '--targeted' "$REPO_ROOT/skills/solve-issue/SKILL.md"
  [ "$status" -eq 0 ]
  run grep -F "full suite is the verify gate's" "$REPO_ROOT/skills/solve-issue/SKILL.md"
  [ "$status" -eq 0 ]
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
  [[ "$output" == *"lint: modified files: src/app.py — the check rewrote them: run it, commit the result, and re-run"* ]]
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

@test "preflight: Requires is not run again when orchestrated - the orchestrator already did" {
  { printf '# Second\n\n## Requires\n\n- `touch %s/ran; exit 1`\n\n## Blocked by\n\nNone\n' "$TEMP_DIR"; } > "$ISSUE"
  CREW_ORCHESTRATED=1 _preflight
  [ "$status" -eq 0 ]
  [ ! -e "$TEMP_DIR/ran" ]
}
