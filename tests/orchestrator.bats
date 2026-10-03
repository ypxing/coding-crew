#!/usr/bin/env bats
# orchestrator.bats — runs the Node orchestrator's own suite through the one test
# entry point this repo has (bats), so CI shards it like everything else and a broken state
# machine cannot merge on a green bats run that never executed it. The sprint suite's topic
# files (tests/orchestrator/sprint-<topic>.test.mjs), most of its time, each run from their own
# orchestrator-sprint-<topic>.bats so they can land on different shards; this file runs the rest.
#
# The suite is node:test only — no dependencies — and its integration half drives the
# whole sprint state machine with every model dispatch faked, so it costs no tokens.

load helpers/orchestrator-suite

@test "orchestrator: node is available (the orchestrator's runtime)" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not installed — the orchestrator requires Node >= 20"
  fi
  run node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)'
  [ "$status" -eq 0 ]
}

@test "orchestrator: unit suite passes (the sprint topic files run from orchestrator-sprint-<topic>.bats)" {
  local files=() f
  while IFS= read -r f; do files+=("$f"); done < <(orchestrator_unit_tests)
  [ "${#files[@]}" -gt 0 ]
  run_node_tests "${files[@]}"
}

@test "orchestrator: every node test file runs from exactly one bats file" {
  # Each sprint topic file has a bats wrapper of its own so CI can shard it; the rest run from
  # this file's glob. A topic file with no wrapper, or one also swept up by the glob, is a test
  # that silently never runs or runs twice.
  cd "$REPO_ROOT"
  local f base topic w n
  for f in tests/orchestrator/sprint-*.test.mjs; do
    base=$(basename "$f")
    topic=${base#sprint-}; topic=${topic%.test.mjs}
    w="tests/orchestrator-sprint-$topic.bats"
    [ -f "$w" ] || { echo "no bats wrapper for $base (expected $w)"; return 1; }
    # Run by exactly one wrapper: no other bats file runs the topic file (comments may name it).
    n=$(grep -l "run_node_tests .*tests/orchestrator/$base" tests/*.bats | tr '\n' ' ')
    [ "$n" = "$w " ] || { echo "$base is run by: ${n:-no bats file} (want only $w)"; return 1; }
  done
  # No wrapper without a topic file behind it.
  for w in tests/orchestrator-sprint-*.bats; do
    topic=${w#tests/orchestrator-sprint-}; topic=${topic%.bats}
    [ -f "tests/orchestrator/sprint-$topic.test.mjs" ] || { echo "$w has no topic file"; return 1; }
  done
  # The unit glob runs none of the topic files, and nothing else is left unrun: what it finds
  # plus the topic files is every *.test.mjs there is.
  [ -z "$(orchestrator_unit_tests | grep '^tests/orchestrator/sprint-')" ]
  [ "$( (orchestrator_unit_tests; ls tests/orchestrator/sprint-*.test.mjs) | sort)" = \
    "$(ls tests/orchestrator/*.test.mjs | sort)" ]
}

@test "orchestrator: the sprint topic files share one helpers module, with no helper redefined" {
  cd "$REPO_ROOT"
  local f
  [ -f tests/orchestrator/helpers/sprint.mjs ]
  for f in tests/orchestrator/sprint-*.test.mjs; do
    grep -q 'from "./helpers/sprint.mjs"' "$f" || { echo "$f does not import the shared helpers"; return 1; }
    ! grep -qE '^(async )?function (fixtureRepo|addIssue|runSprint|sh)\(' "$f" || { echo "$f redefines a shared helper"; return 1; }
  done
}

@test "orchestrator: plan is read-only and needs no model" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  # A scratch repo on the local tracker, not this repo: this repo tracks its own issues on
  # GitHub, so planning here would need `gh` auth (and the network) just to list issues.
  local dir
  dir="$(mktemp -d)"
  cd "$dir"
  git init -q
  git config user.email t@test
  git config user.name T
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m init
  mkdir -p .scratch/feat-a/issues/open
  printf '# A\n\nStatus: ready-for-agent\n' > .scratch/feat-a/issues/open/01-a.md

  run node "$REPO_ROOT/orchestrator/main.mjs" plan --platform pi --feature-slug feat-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"pipeline per branch: deps → dispatch → verify → review (AC + findings) → merge → close"* ]]
  # Provisioning is part of the pipeline plan, and its off switch is visible in it.
  [[ "$output" == *"deps:"* ]]

  run node "$REPO_ROOT/orchestrator/main.mjs" plan --platform pi --feature-slug feat-a --no-deps
  [ "$status" -eq 0 ]
  [[ "$output" == *"disabled (--no-deps)"* ]]
  # Read-only: plan left the checkout exactly as it found it.
  [ -z "$(git status --porcelain)" ]

  cd /
  rm -rf "$dir"
}

@test "orchestrator: plan (and run) refuse to guess between two feature dirs with ready issues" {
  # Regression: a bare invocation with no --feature-slug used to let session-init.sh's
  # own "find | head -n 1" fallback silently pick one of several feature dirs, which is
  # exactly the shape of the cross-feature dispatch bug selectDispatchable()'s scoping
  # fix (tracker.mjs) exists to prevent. main.mjs must refuse instead of guessing, before
  # session-init.sh (or anything else) ever runs.
  command -v node >/dev/null 2>&1 || skip "node not installed"
  local dir
  dir="$(mktemp -d)"
  cd "$dir"
  git init -q
  git config user.email t@test
  git config user.name T
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m init
  mkdir -p .scratch/feat-a/issues/open .scratch/feat-b/issues/open
  printf '# A\n\nStatus: ready-for-agent\n' > .scratch/feat-a/issues/open/01-a.md
  printf '# B\n\nStatus: ready-for-agent\n' > .scratch/feat-b/issues/open/01-b.md

  run node "$REPO_ROOT/orchestrator/main.mjs" plan --platform pi
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to guess"* ]]
  [[ "$output" == *"--feature-slug feat-a"* ]]
  [[ "$output" == *"--feature-slug feat-b"* ]]

  # An explicit slug still resolves normally and is never treated as ambiguous.
  run node "$REPO_ROOT/orchestrator/main.mjs" plan --platform pi --feature-slug feat-a
  [ "$status" -eq 0 ]
  [[ "$output" == *"dispatchable now (1):"* ]]
  [[ "$output" == *"- a  "* ]]

  cd /
  rm -rf "$dir"
}

@test "orchestrator: run refuses to start when another sprint already holds this feature-slug's lock" {
  # Regression: two `crew-afk run` invocations for the same feature-slug used to race —
  # both dispatching the same issue's coder concurrently, racing for the same worktree and
  # branch, burning a real retry attempt on a collision neither process's own code caused.
  # acquireSprintLock in main.mjs now refuses a second `run` outright instead.
  command -v node >/dev/null 2>&1 || skip "node not installed"
  local dir
  dir="$(mktemp -d)"
  cd "$dir"
  git init -q
  git config user.email t@test
  git config user.name T
  printf '.scratch/\n' > .gitignore
  git add .gitignore
  git commit -q -m init
  mkdir -p .scratch/feat-a/issues/open
  printf '# A\n\nStatus: ready-for-agent\n' > .scratch/feat-a/issues/open/01-a.md
  # $$ (this bats test's own shell pid) is guaranteed alive for the test's duration —
  # a deterministic stand-in for "a sprint that is still actually running".
  printf '{"pid": %s, "startedAt": "2020-01-01T00:00:00.000Z"}' "$$" > .scratch/feat-a/.crew-afk.lock

  # CREW_FAKE_DISPATCH short-circuits preflight()'s CLI/agent-file checks (this repo has
  # neither `pi` nor any agent definitions installed), so the run reaches the lock check on
  # its own merits. CREW_PANE_HOST=none (this suite may itself be running inside a herdr- or
  # orca-managed pane) so a real notifyTriggeringPane call never fires into it. Unsetting it is
  # not enough: the user-level config's afk.paneHost, or "auto" with the pane's own
  # ORCA_TERMINAL_HANDLE, would still pick a host; only an explicit none outranks the file.
  run env CREW_PANE_HOST=none CREW_FAKE_DISPATCH=1 node "$REPO_ROOT/orchestrator/main.mjs" run --platform pi --feature-slug feat-a
  [ "$status" -eq 1 ]
  [[ "$output" == *"already running"* ]]
  [[ "$output" == *"pid $$"* ]]

  cd /
  rm -rf "$dir"
}

@test "orchestrator: every platform builds a headless per-agent dispatch" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  cd "$REPO_ROOT"
  run node -e '
    import("./orchestrator/lib/dispatch.mjs").then(({ buildDispatch, PLATFORMS }) => {
      const fs = require("fs"), os = require("os"), path = require("path");
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), "d-"));
      const promptFile = path.join(dir, "p.md");
      fs.writeFileSync(promptFile, "prompt body");
      for (const platform of PLATFORMS) {
        const b = buildDispatch(platform, {
          agent: "crew-coder", cwd: dir, promptFile, outFile: path.join(dir, "o.md"),
          model: null, mainRoot: dir, logFile: null, scriptsDir: "skills/crew-afk/scripts",
        });
        const argv = [b.cmd, ...b.args].join(" ");
        if (argv.includes("--agent ") || /dispatch-.*agent\.sh/.test(argv)) throw new Error(platform + ": agent file or bash dispatcher expected");
        console.log(platform + ": " + b.cmd + " (" + b.capture + ")");
      }
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi: pi"* ]]
  [[ "$output" == *"codex: codex"* ]]
  [[ "$output" == *"claude: claude"* ]]
  [[ "$output" == *"copilot: copilot"* ]]
}

@test "orchestrator CLI: the seven retired flags are rejected as unrecognized" {
  for f in --promote --coverage --worker-timeout --review-timeout --max-rounds --merge-timeout --no-commands; do
    run node orchestrator/main.mjs run "$f"
    [ "$status" -ne 0 ] || { echo "$f accepted"; return 1; }
    [[ "$output" == *"unrecognized argument"*"$f"* ]] || { echo "$f: $output"; return 1; }
  done
}

@test "orchestrator CLI: --help lists --dry-run and none of the retired flags" {
  run node orchestrator/main.mjs --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--dry-run"* ]]
  for f in --promote --coverage --worker-timeout --review-timeout --max-rounds --merge-timeout --no-commands; do
    [[ "$output" != *"$f"* ]] || { echo "help names $f"; return 1; }
  done
}

@test "orchestrator: doctor reports a PROBLEM when the CLI's --help omits a required flag" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  local bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/bin/sh\necho "usage: claude [--output-format x] [--add-dir d]"\n' > "$bin/claude"
  chmod +x "$bin/claude"
  cd "$REPO_ROOT"
  run env PATH="$bin:$PATH" CREW_PANE_HOST=none node "$REPO_ROOT/orchestrator/main.mjs" doctor --platform claude
  [ "$status" -eq 1 ]
  [[ "$output" == *"PROBLEM:"*"--permission-mode"* ]]
}
