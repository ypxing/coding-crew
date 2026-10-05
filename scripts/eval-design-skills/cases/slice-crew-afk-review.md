---
skill: to-issues
stage: slice
repo_ref: 3bec757
---
<!-- repo_ref 3bec757 is on main, before PRD #147's work merged. The PRD body below is frozen as published. -->
## Request
The PRD below is approved; the feature slug is `afk-overhaul`, under `tracker: github`. Break it into issues. The PRD body, as published:

## Problem Statement

Actor: the maintainer, today crew-afk's only user, running `/crew-afk` unattended on this repo and others, on any of claude, copilot, codex or pi.
Origin: #119

A review of crew-afk's value, effectiveness, cost, design, adoption and flow found four problems.

1. **Runs are slow.** 16 measured runs took 803 wall-minutes in total, median about 45 minutes, longest 120.
   - The project's full check suite runs as the baseline, as every per-issue verify, and as the integration check: 47% of wall time.
   - Coders also ran the full suite about 65 times (roughly 374 clock-minutes), although the crew path tells them to defer it (`CREW_DEFER_FULL_CHECKS`, `orchestrator/lib/dispatch.mjs:90`).
   - 9 of 12 integration checks ran on a git tree byte-identical to one that had just passed verify.
   - In this repo one suite run takes 6.5 minutes, and 12 node-suite wrappers account for 64% of it.
2. **Platform dispatch is the largest maintenance cost.** Dispatch and platform fixes are 45 of the 121 fix commits touching crew-afk.
   - The cause is per-platform agent files (12 of them) and two bash dispatchers (`dispatch-agent.sh`, `dispatch-codex-agent.sh`, about 650 lines).
   - Three of the six roles already dispatch without an agent file (`dispatchPlain`, `dispatch.mjs:552-626`).
3. **Correctness gaps.**
   - A stalled sprint opens a ready PR. PR #118 was merged that way (#119).
   - An integration check that could not run reads as `pass`.
   - A timeout kills only the direct child, so the pi or codex process keeps running.
   - The orchestrator ignores the config-dir env vars that `install.sh` honours.
   - Polling for new issues has no wall-clock bound.
4. **Dead weight and drift.**
   - 7 legacy or rarely useful flags; `--review-timeout` silently sets 5 role timeouts.
   - 1,152 lines of unused `references/test-*.sh` ship to users.
   - The 4 crew-afk launchers are hand-copied and have drifted.
   - The severity thresholds are duplicated in bash and JS.
   - CLAUDE.md has drifted from the code.

## Solution

crew-afk dispatches every role the same way on every CLI.
- Each role is one adapter call per CLI, with the role's protocol in the prompt and no per-platform agent files.
- A mechanical guard keeps the reviewer and triage roles read-only.

Runs get faster:
- An identical tree is never checked twice.
- Coders really leave the full suite to the verify gate.
- The first coders start while the baseline runs.
- This repo's own suite is parallelised.

Runs are bounded:
- A soft wall-clock cap, 120 minutes by default.
- The PR is a draft whenever the run did not finish green.

Dead flags, dead files, duplicated launchers and duplicated thresholds are removed, and the docs match the code.

## Behaviours

- **B1** — given any `--platform`, every role (coder, reviewer, triage, commandFinder, prdAuditor, prWriter) is spawned through that platform's adapter with no agent file on disk, at `orchestrator/lib/dispatch.mjs` (`dispatch.test.mjs`)
- **B2** — given a reviewer or triage dispatch that changes a `crew/<feature>/*` ref, the feature branch, main `HEAD` or the main checkout's status, the dispatch counts as not-run and `[READONLY-VIOLATION]` is logged, at the sprint suite with `CREW_FAKE_DISPATCH`
- **B3** — given a run that stalls, finishes with integration red or `skipped`, or hits the wall-clock cap, `--open-pr` creates the PR as a draft, or converts an existing ready PR to draft, and the PR body and summary say why; a clean run leaves the PR ready or marks an existing draft ready, at `open-pr.sh` + the sprint suite
- **B4** — given `afk.maxWallMinutes` elapsed (default 120), no issue is claimed, polling stops, running workers finish, Phase 2 is skipped, the integration check runs, and the run exits 2, at the sprint suite
- **B5** — given a feature branch whose tree equals a tree that already passed baseline, integration or a per-issue verify, the integration and baseline checks report `cached` without running, at `runFeatureChecks` (`preflight.mjs`)
- **B6** — given a dispatch that times out, its whole process group (dispatcher, CLI and any checks it started) is gone, at `Effects` (`effects.test.mjs`)
- **B7** — given the baseline still running, the first ready issues are already dispatched; given the baseline then fails, no further issue is claimed and the run stops as it does today, keeping the started branches, at the sprint suite

## Decisions

- **D1** — The target is "personal now, public later": portability bugs get fixed, there is no adoption work. All 4 platforms and both pane hosts (herdr, orca) stay.
- **D2** — **Adapters.**
  - `orchestrator/lib/adapters/<platform>.mjs`, one per CLI, with the shape below.
  - `dispatch.mjs` owns spawning and depends on adapters, never the reverse.
  - The pi and codex stream parsers move from bash into their adapters.

  ```js
  // adapter shape
  { cmd, defaultParallel, defaultModel,
    argv({ cwd, mainRoot, model, role, promptFile, outFile }),   // headless + full permissions
    promptVia: "stdin" | "file" | "argv",                        // argv only where the CLI allows nothing else (copilot)
    env?, traceLine(evt), finalText(lines),
    resultMeta?(lines), resume?(id), budget?(usd), roleArgs?(role) }
  ```

  Today's argv is the starting point:
  - claude: `dispatch.mjs:150-160`
  - copilot: `dispatch.mjs:184-197`
  - codex: `dispatch-codex-agent.sh:156,203,345`
  - pi: `dispatch-agent.sh:149`
- **D3** — **Prompt assembly.** The orchestrator renders each role's prompt from `agents/<role>/protocol.md` and expands `{{FRAGMENT:…}}` itself, using the same rules as `scripts/render-skill.sh`. The protocol goes in as a system-prompt file where the CLI has one (claude `--append-system-prompt-file`), otherwise it is prepended to the prompt. Skills the protocol names get absolute paths under `CREW_INSTALL_DIR`, as prWriter already uses `.coding-crew/write-pr/` (`orchestrator/lib/install-dir.mjs`).
- **D4** — **Removed:**
  - the 12 per-platform agent files under `agents/*/`
  - `dispatch-agent.sh` and `dispatch-codex-agent.sh`
  - `agentFileCandidates`/`resolveAgentFile` (`dispatch.mjs:43-76`) and `copilotWorktreeVisible` (`dispatch.mjs:628-662`)
  - `DISPATCHER`/`resolveDispatcherDir` (`crew-config.mjs:389`, `main.mjs:444-456`)
  - the shim install code (`install.sh:445-530`)
  - the registry `install.shims` entries

  `protocol.md` stays as each agent's only source. An agent entry's installed form is its protocol as an asset, under `.coding-crew/`.
- **D5** — **Per-role settings move into role config.** Codex reasoning effort (coder medium, reviewer and triage high) and the claude coder's `--disallowedTools Agent` move from the agent files into role config: `roleArgs` in the adapter, with defaults in `crew-config.mjs`.
- **D6** — **Read-only guard.** Wraps every reviewer, triage and feature-review dispatch. Before the dispatch it snapshots `git for-each-ref refs/heads/crew/<feature>/`, the feature branch ref, main `HEAD` and `git status --porcelain` of the main checkout. Any difference afterwards makes the dispatch fail closed: it is recorded as not-run, through the existing review-not-run route. The AC receipt is written for the commit the reviewer was given (`receipts.sh write ac` receives that sha), not for the tip after the review (`pipeline.mjs:699`).
- **D7** — **Draft rule.** A run is green iff:
  - exit 0,
  - no blocked issue,
  - integration `pass` or `cached`,
  - cap not hit.

  `pullRequest` (`orchestrator/lib/loop.mjs:~560-600`) passes `--draft` to `open-pr.sh` whenever the run is not green, and otherwise passes nothing, as today. `open-pr.sh`:
  - a new PR is created with `gh pr create --draft`;
  - an existing ready PR is converted with `gh pr ready --undo`;
  - a clean run marks an existing draft ready with `gh pr ready`;
  - a failed `gh pr ready` or `--undo` only warns.

  The crew-afk block of the PR body lists each blocker and reason. #119's acceptance criteria apply unchanged.
- **D8** — **Integration `skipped`.** `runFeatureChecks` returns `status: "skipped"` when the integration worktree can't be created. The baseline keeps returning `pass` in that case, by design (`preflight.mjs:237-240`). The summary reports `skipped`, and D7 treats it as not green.
- **D9** — **Tree cache.**
  - `state.sh baseline` records `--tree <sha>` next to `--commit`.
  - Each passing per-issue verify records its tree as well.
  - `runFeatureChecks` compares `<feature>^{tree}` with every recorded passing tree and returns `cached` on a match. The commit cache at `preflight.mjs:220-224` becomes tree-keyed.
- **D10** — **Coders defer the full suite.** While the verify gate exists, the coder runs only typecheck, lint and the tests it touched. Today `CREW_DEFER_FULL_CHECKS` is honoured only by `skills/solve-issue/scripts/run-checks.sh`, and coders bypass it by running the suite command directly. The fix gives the coder a mechanical way to run the tests it touched and makes the deferral visible in what its prompt asks for. The coder report's check section counts a full-suite run as a deviation. The direct `/solve-issue` path, with no orchestrator, keeps the full suite.
- **D11** — **Baseline runs concurrently.**
  - `effects.bashAsync` runs the baseline while the loop dispatches up to `maxParallel` issues.
  - A coder's verify waits for the baseline verdict.
  - A red baseline stops further claims and stops the run with today's message.
  - Started branches are retained, as a stalled branch is today.
- **D12** — **Wall-clock cap.** `--max-wall <minutes>` / `afk.maxWallMinutes`, default 120, `0` = off. It is checked in `loop.mjs` at each claim and each poll tick. Hitting it is a soft stop: workers already running keep their own timeouts, Phase 2 and its fix issues are skipped, and the integration check still runs. The summary names the cap and the issues left unclaimed. The exit code is 2.
- **D13** — **Process groups.** `Effects.exec`, `bashAsync` and `spawnWithTimeout` spawn with `detached: true`; a timeout or an interrupt sends `process.kill(-pid, …)` (`orchestrator/lib/effects.mjs:111-120,166-175`). The orchestrator also kills every live group when it exits.
- **D14** — **Config-dir env vars.** Script lookup (`PROJECT_SKILL_DIRS`/`USER_SKILL_DIRS`, `main.mjs:403-414`) roots each user-level dir at `CLAUDE_CONFIG_DIR`, `COPILOT_HOME`, `PI_CODING_AGENT_DIR` or `CODEX_HOME` when set. These are the same vars `install.sh:203-217` reads.
- **D15** — **Flags removed** (`main.mjs:168-215`): `--promote`, `--coverage`, `--worker-timeout`, `--review-timeout`, `--max-rounds`, `--merge-timeout`, `--no-commands`. They fall through to the existing unknown-argument rejection (c1883d3). The help text and `docs/guide.md` drop them; the help text gains `--dry-run`, which it was missing (`main.mjs:462`).
- **D16** — **Dead references deleted:** `skills/crew-afk/references/test-{promote-findings,session-init,sprint-state,worktree-lifecycle,worktree}.sh`. Nothing runs or references them except one of them naming another.
- **D17** — **Launchers rendered from one body.** The four `skills/crew-afk/<platform>.SKILL.md` become one shared body via a `registry.json` `body` entry, with `{{FRAGMENT:…}}` for the 34–40 lines that really differ by platform (`scripts/render-skill.sh:8-13`). Copilot's missing "missing agent" failure line disappears together with agent files.
- **D18** — **One owner for severity thresholds.** `orchestrator/lib/report.mjs:349-360` resolves `fixFindings` to a severity list and passes it to `promote-findings.sh`. The bash table (`promote-findings.sh:105-128`) and `CREW_PROMOTE` go.
- **D19** — **This repo's suite is faster.** The 12 `tests/orchestrator-*.bats` wrappers around node suites (245 s of the 6.5-minute run) are run in parallel, through `node --test` concurrency or by splitting them. The target is the single `bats tests/*.bats` command in `.coding-crew/dev-commands.json`, which must stay under 3 minutes locally. `bats --jobs` needs GNU parallel, which is not installed, so it is not the mechanism.
- **D20** — **Docs.**
  - CLAUDE.md lists `lease.sh`, `post-findings.sh` and `prd-audit.sh`.
  - The false "one caller each" is dropped.
  - "`tests/layer-ownership.bats` is this table" is narrowed to the rows it checks.
  - The layer table's `crew-coder` row becomes "protocol + report wire". Tool and model bindings move to the adapters (orchestrator).
  - The README gains one line: workers run with full permissions on the host, in per-issue worktrees.
- **D21** — Every touched `registry.json` entry's version is above origin/main's (CLAUDE.md D4 invariant).

## Trust Boundaries & Risks

- **Shell/exec.** Every role runs a coding-agent CLI with full permissions on the host. This is already true for the coder; for reviewer and triage, D6 is the only guard. A guard trip fails closed (not-run), never merges.
- **Prompt size.** On Linux one argv string is capped at 128 KiB (`MAX_ARG_STRLEN`), and Windows caps the whole command line at about 32K characters. Adapters use stdin or a file wherever the CLI allows. An argv prompt over the limit fails the dispatch with a clear error and is never truncated.
- **Unverified CLI flags.** Only claude is installed on the dev machine. The copilot and pi flags for full-permission headless runs, and stdin support, are unverified. Each adapter's tests pin its argv, and `crew-afk doctor` reports a CLI whose `--help` lacks a required flag.

## Compatibility & Migration

Not expand–contract; you are the only user.
- **Removed flags** (D15) are rejected as unknown.
- **Agent files** (D4): `install.sh --update` removes the installed shims, through the existing `retired_files` / `prune_replaced_agent_shims` mechanism. `crew-coder`, `crew-reviewer` and `crew-triage` disappear from Claude's agent list and from Codex's subagents.
- **`CREW_PROMOTE`** is no longer read.
- **`sprint-state.json`** gains `tree` fields. An old state without them simply misses the cache.

## Testing Decisions

- **Seam for B2–B5 and B7:** the sprint suite (`tests/orchestrator/sprint-*.test.mjs`, run through `CREW_FAKE_DISPATCH` and `tests/orchestrator/helpers/sprint.mjs`). Assert on the summary, the exit code, `sprint-state.json` and recorded effects; don't assert on internals.
- **Adapters:** each one gets argv and parser tests over recorded event streams, extending `tests/orchestrator/dispatch.test.mjs`. Fixtures for the pi and codex streams come from the current bash dispatchers' parsing cases.
- **Process groups:** `effects.test.mjs` spawns a grandchild `sleep` and asserts it is gone after the timeout.
- **Draft rule:** `tests/crew-afk-open-pr.bats` with a fake `gh`.
- **Existing tests:** those that assert agent files, shims or bash dispatchers are deleted or rewritten:
  - `tests/*codex*`, `*pi*`, `*copilot*`
  - shim-consistency and tool-inheritance tests
  - `layer-ownership.bats` rows

## Out of Scope

- **Moving judgement out of the orchestrator** (status interpretation `pipeline.mjs:567-608`, regex on verify output, `isTestPath`): a large refactor, and no fix commit traces back to it.
- **The bash/JS split of tracker and `gh` calls**, and `lease.mjs`/`lease.sh`: same reason.
- **A USD budget per run:** spend is about $0.83 per issue, the biggest run cost $12.88, and it would only work on claude.
- **A "removed; use X" message for cut flags:** the unknown-argument rejection already exists, and you are the only user.
- **Merge conflicts in CLAUDE.md or other shared files:** prevention is open #146.
- **Low slot use from `## Blocked by` chains** (42% average): a `to-issues` slicing concern, last changed in #141.
- **End-to-end sprint tests on real claude or copilot:** unnecessary until there are outside users.
- **Adoption work:** README marketing, outside platform support.

## Further Notes

- **Evidence base:**
  - 17 sprint features, about 58 merged issues, about $48, 166 dispatches; 51 of 73 attempts completed.
  - The time breakdown above comes from `.scratch/*/traces*/orchestrator.log`, parsed by `/tmp/crewtime/parse.py`.
  - Merge-conflict retries cost about 99 minutes.
- **Order.** Do the fix and cut work (D7, D8, D13–D16, D18, D20) before the adapter migration (D2–D6), so the migration lands on a smaller surface. Speed work (D9–D11, D19) and the cap (D12) are independent of both.

## Reference judgement
Many slices are right here: the slices actually published (#148–#160) were 13, 4–7 criteria each, each landed in one coder session and was judged well sized afterwards (#182). The work spans 21 decisions across the orchestrator, every platform adapter, four launchers, the installer and this repo's test suite — far beyond one coder's session — so the context-budget reason splits it, and the PRD's own Further Notes ask for the fix-and-cut work (D7, D8, D13–D16, D18, D20) before the adapter migration (D2–D6), so that order gives `Blocked by` edges. Expected shape: independent fix/cut slices (draft rule + integration `skipped`; process groups + config-dir env vars; dead flags and files + docs; one severity owner; launchers from one body), independent speed slices (coders defer the full suite; parallel node suites; tree cache + concurrent baseline), the cap, then the adapter migration (claude/copilot adapters, read-only guard, pi/codex adapters, removing agent files and shims) blocked by the work it lands on. `count_ok` is about 8–16 slices. Collapsing to a handful (5 or fewer) is overmerged: no single coder can hold, say, all four adapters plus the agent-file removal plus the guard. Slices of one or two criteria each (for example every removed flag on its own) is oversplit.
