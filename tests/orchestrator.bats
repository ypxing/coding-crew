#!/usr/bin/env bats
# orchestrator.bats — runs the Node orchestrator's own suite through the one test
# entry point this repo has, so CI shards it like everything else and a broken state
# machine cannot merge on a green bats run that never executed it.
#
# The suite is node:test only — no dependencies — and its integration half drives the
# whole sprint state machine with every model dispatch faked, so it costs no tokens.

setup_file() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export REPO_ROOT
}

@test "orchestrator: node is available (the orchestrator's runtime)" {
  if ! command -v node >/dev/null 2>&1; then
    skip "node not installed — the orchestrator requires Node >= 20"
  fi
  run node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)'
  [ "$status" -eq 0 ]
}

@test "orchestrator: unit and integration suite passes" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  cd "$REPO_ROOT"
  run node --test tests/orchestrator/tracker.test.mjs tests/orchestrator/report.test.mjs \
    tests/orchestrator/dispatch.test.mjs tests/orchestrator/sprint.test.mjs
  if [ "$status" -ne 0 ]; then
    echo "$output" >&3
  fi
  [ "$status" -eq 0 ]
}

@test "orchestrator: plan is read-only and needs no model" {
  command -v node >/dev/null 2>&1 || skip "node not installed"
  cd "$REPO_ROOT"
  run node orchestrator/main.mjs plan --platform pi
  # 0 = issues found, 3 = nothing to do; both are read-only successes.
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
  [[ "$output" == *"pipeline per branch: verify → review (AC + findings) → merge → close"* ]]
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
        if (!argv.includes("crew-coder")) throw new Error(platform + ": agent not named");
        console.log(platform + ": " + b.cmd + " (" + b.capture + ")");
      }
    }).catch((e) => { console.error(e.message); process.exit(1); });
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi: bash"* ]]
  [[ "$output" == *"codex: bash"* ]]
  [[ "$output" == *"claude: claude"* ]]
  [[ "$output" == *"copilot: copilot"* ]]
}
