# Changelog

## [1.28.4]

### Fixed

- **`crew-coder`'s report file and final message were the same stringified JSON, which
  defeated the point of having two artifacts.** 1.28.2 fixed the two-*shapes* problem
  (markdown template plus a JSON echo, with the markdown thrown away unread) by making
  both channels pure JSON — but that traded it for a two-*copies* problem: `<slug>.report.md`
  (the dispatch's captured final message) and `<slug>.report.json` (the sidecar) ended up
  byte-for-byte identical, so the `.md` file carried no information the `.json` one didn't.
  The final message now leads with one line (`Status: complete|partial|blocked`) and a short
  human-readable summary before the same JSON block, verbatim, last — `report.mjs` still
  reads the sidecar first and falls back to the fenced block in the message if the sidecar
  write failed (the reliability property 1.28.2 added), but `<slug>.report.json` holds only
  the JSON object and `<slug>.report.md` is now an actual report a human can read. Also
  fixed four tests left asserting the pre-1.28.2 markdown headings (`### Acceptance
  Criteria`, `- [ ]` checkboxes, `## Issue: <slug>`) that no longer exist under either shape.

## [1.28.3]

### Fixed

- `ensure-deps.sh`'s presence guard ran before its docker-mode check, for every call
  including the one MAIN_ROOT call that generates `docker-compose.override.yml`. A repo
  that already had a host-side `node_modules` at `$MAIN_ROOT` (predating
  `.worktreeinclude` excluding it, or a contributor's own local install) reported `DEPS:
  present` and never reached `docker-install.sh` — the override was never written, no
  worktree ever saw `docker-present`, and every worker was left to run its own
  `dep-install` from scratch. The MAIN_ROOT call now runs `detect-mode.sh` ahead of the
  presence guard and skips the guard when it says `USE_DOCKER`; worktree calls are
  unaffected, since an inherited dep dir via `.worktreeinclude` there genuinely means
  there is nothing to do.

## [1.28.2]

### Fixed

- `crew-coder`'s report was two shapes: a markdown template (`## Issue:` / `### Notes`) plus a JSON
  block echoing the same fields. `report.mjs` parses the JSON alone and only falls back to scraping
  markdown when no JSON exists anywhere, so the markdown report was generated on every run and then
  thrown away unread. The protocol and example now specify one report shape — the JSON block,
  written to the sidecar file and repeated verbatim as the final message — with `notes` (was
  `### Notes`) as one of its fields.

## [1.28.1]

### Fixed

- `solve-issue` Step 2's docker-mode check only looked at `agent.install-mode` git config or an
  existing `docker-compose.override.yml`. `detect-mode.sh` also reads a Makefile `install`/`deps`
  target for a docker command — a worktree in docker mode by that heuristic alone silently read as
  host mode and never got its deps in either mode. Step 2 now runs the real script instead of
  duplicating a narrower guess of its own.

## [1.28.0]

### Added

- `ensure-deps.sh` now mechanizes docker-mode installs for the one MAIN_ROOT call a sprint makes
  before any worktree exists: it runs `dep-install`'s new `docker-install.sh` (the docker-mode
  sibling of `host-install.sh` — deterministic ecosystem/service/command selection, no judgement)
  under an `mkdir`-based lock, then writes `$MAIN_ROOT/.scratch/docker-install.done`. A worktree's
  own `ensure-deps.sh` call only checks that marker (`DEPS: docker-present`) and never installs
  itself — the named volume it would write into is shared by every worktree of this checkout by
  design, so the install must run once, not once per worktree. `CREW_DOCKER_INSTALL=off` rolls it
  back to the previous always-deferred `DEPS: docker` behaviour, independently of `CREW_DEPS`.
- `gen-override.sh --query <services|ecosystem|container-src|manifest-dirs>` — prints one detected
  fact and exits, so a caller that needs to *run* an install can reuse this script's own detection
  instead of re-parsing the compose file and manifests a second time.

### Fixed

- `gen-override.sh`'s `CONTAINER_SRC` detection ran under `set -euo pipefail` with no `|| true` on
  a pipeline that legitimately returns no match — the documented `/app` fallback for a compose file
  with no matching bind-mount line was dead code; the script exited early instead of reaching it.

## [1.27.0]

### Added

- New user-level install integration tests for comprehensive verification of installation across platforms
- Enhanced orchestrator main.mjs with improved state management and control flow

### Changed

- Updated crew-afk skill documentation across all platforms (claude, codex, copilot, pi) with refined implementation details
- Improved platform-specific skill wrappers for better cross-platform compatibility
- Enhanced manifest and orchestration documentation for clarity

### Fixed

- Fixed state management in orchestrator for improved sprint reliability
- Improved error handling in platform-specific dispatchers

## [Unreleased]

### Changed

- **The shared-body scaffolding is retired, and the last three prose promises became code.** With every platform on a launcher, the machinery that kept four prose bodies in parity had no subject: `AFK_PROSE_VARIANTS`/`AFK_PROSE_DISPATCH_VARIANTS` are gone from `tests/helpers/render.bash` (`rendered_skill` stays — other skills still render, and a launcher must be asserted through the path that installs it), and the loops that iterated them are pruned from seven suites (`prompt-integrity`, `crew-afk-ac-in-review`, `crew-afk-review-gaps`, `crew-afk-promotion-threshold`, `crew-afk-receipts`, `crew-afk-state`, `workflow-integrity`). **An empty loop is not a passing test**, which is the failure mode this pass existed to prevent: each deletion is either already covered in `tests/orchestrator/` or was replaced by an assertion on the file that still owns the rule — `promote-findings.sh` is the only writer of the `ACVERIFY` marker, `orchestrator/lib/pipeline.mjs` is the only writer of both receipts, and no launcher may state the promotion threshold.

  **Three assertions had no code equivalent, so they were written before the prose went** (`tests/orchestrator/sprint.test.mjs`): the promotion threshold has one source (`--promote critical-high` promotes a HIGH into a Phase 2 fix issue, the default does not, and the value lives in `CREW_PROMOTE` in `sprint.env`); the sprint reports **once**, from disk, with the summary last and the findings reminder printed exactly once; and a review that never ran is *named* in the summary under `## Unreviewed Branches`, not merely counted in the state file. Writing the first found a real gap: `promote-findings.sh remind` counted only `[SEVERITY]` prose blocks, so a report carrying just the machine-readable `FINDING: HIGH | file:line | criterion` line — the exact form `findingsAtOrAbove()` promotes from — ended a sprint as "No open review findings", silently breaking the guarantee that nothing subtracts an unpromoted severity from the reminder. `remind` now counts either form, once per branch and severity (two new bats cases: machine-only counted, both-forms not double-counted).

  **`configure-tracker-auto.sh` is dropped from `crew-afk`.** The orchestrator does its own issue discovery (`orchestrator/lib/tracker.mjs`), so the prose body was the script's last caller and every launcher platform was installing a script no agent runs. It joins `install.sh`'s per-skill retired-file sweep, since older installs left a copy behind; the `configure-tracker` skill still ships it, and `feature-branch-setup.sh` stays because `session-init.sh` calls it. `CLAUDE.md`'s six platform-specifics paragraphs collapse into **one adapter table** plus the four facts a real sprint paid to learn (the `--agent` contract, permission flags removing the prompt and not the allowlist, copilot's cwd-relative agent resolution, codex's sandbox writable root). And `state.sh` / `trace.sh` / `receipts.sh` **stay in bash**, deliberately: they are effects with one caller each, and they are how a human inspects or repairs a stalled sprint from a shell with no live orchestrator — recorded in `docs/crew-afk-orchestrator.md` so the question is not re-litigated. 529 bats + 74 node tests green.

- **copilot is cut over to the orchestrator program, and the last prose orchestrator is deleted.** Fourth and final platform: `skills/crew-afk/copilot.SKILL.md` is a 477-word launcher that runs `node .coding-crew/crew-afk/main.mjs run --platform copilot`, and `skills/crew-afk/fragments/copilot/` plus `skills/crew-afk/dispatch.SKILL.md` — which had no consumers left once copilot moved — are **deleted**, along with the `body` map entry that pointed at it. `AFK_PROSE_VARIANTS` is now empty, so `tests/shared-dispatch-body.bats` retires with its subject (its own guard said to delete the suite, not the guard, when the list emptied), and every launcher rule in `tests/crew-afk-launcher.bats` applies to all four platforms. Dispatch stops being a special case: copilot's workers were in-session `task` subagents sharing the parent's working root, with per-issue isolation carried by a `Working directory:` line the model had to obey, and are now one `copilot -p --agent crew-coder` process per issue with a real worktree as cwd and a hard timeout.

  **Five decisions, each answered by a probe rather than by documentation** (Copilot CLI 1.0.79), recorded in `.scratch/crew-afk-as-code/issues/done/04-copilot-launcher-cutover.md`. (1) `copilot -p --agent <name>` **does** resolve `.github/agents/<name>.agent.md` (a throwaway agent's body governed the run), enforces that definition's `tools:` list even under `--allow-all-tools` (an agent with `tools: ["view"]` answered `NO-SHELL-TOOL`; the same prompt with `bash` ran it), and exits **1** with `No such agent: <name>, available: …` on an unknown name — it never silently falls back. So the prepended agent body is **removed**: it duplicated a definition the CLI loads itself, and it could never have rescued an unresolvable name, because the CLI exits before reading the prompt. (2) **`--agent` resolves that directory from the process's own working directory and does not walk up** — the one place copilot differs from claude, and the trap only a probe finds: a worker's cwd is its worktree, so an *untracked* `.github/agents/crew-coder.agent.md` in the main root is installed and invisible, and every worker would die on `No such agent` after the sprint had started. `preflight()` now checks visibility from a worktree (tracked in `HEAD`, or present under `~/.copilot/agents/`) and names both fixes, so this fails before round 1 instead of during it. `--agent` also takes a name only — an absolute path to the definition is rejected with the same error. (3) `--allow-all-tools` stays, because an unattended sprint cannot answer a permission prompt and it removes the *prompt*, not the definition's allowlist — which is what keeps the read-only reviewer read-only. `--available-tools` was rejected for the same reason a narrow `--allowedTools` was rejected on claude: a worker runs the consuming project's own checks. (4) `--add-dir <main root>` is passed explicitly: the worker reads the issue file and writes `<slug>.report.json` under `.scratch/`, outside its worktree. (5) `--max-parallel` stays at **2**. The plan tier (Free 2 … Enterprise 32) capped *in-session* subagents; a worker is its own session now, so what binds a process pool is the account's request rate, which the CLI does not expose — and a throttled worker costs its issue a whole round. `--model` stops being accepted-and-ignored and becomes a real flag, since each worker is its own process rather than a `task` that took no model argument.

  **Nothing was deleted before its code equivalent existed.** Copilot's `crew-coder` had no machine-readable report block at all (it was never a launcher platform), so its contract is migrated to the parser's shape — the `<slug>.report.json` sidecar written **as the last action**, `checks{test,lint,typecheck}` as an object — which is exactly what `tests/orchestrator/contract.test.mjs` existed to force on the `AFK_LAUNCHER_VARIANTS` edit. The fragment and body assertions across six bats files (the `task`-tool dispatch, `#runSubagent` never instructed, the agent locations Copilot scans, `Unknown agent_type` reported rather than self-implemented, plan-tier batching, `--model` ignored, review-before-merge and review-before-squash ordering, the no-branch skip, the review report path, retention/resume/cleanup prose, the `not_run` demotion policy, the coverage-validation section and its model tier, and the 2,750-word prose budget) are replaced by nine new cases in `tests/orchestrator/dispatch.test.mjs` plus the existing `sprint.test.mjs`/`report.test.mjs` coverage of the pipeline they described. The one dispatch fact that is still the *body's* to carry — `allowed-tools: shell`, so an unattended sprint cannot stall on a permission prompt — stays in `tests/copilot-platform.bats`, which now also asserts the body no longer pre-approves `task`. 542 bats + 71 node tests green, and a real single-issue copilot sprint verified end to end: worker → verify (`TEST: pass`, lint/typecheck recorded as coverage gaps) → review (`ACVERIFY result=all-met`) → receipts → merge → close → squash → cleanup → summary, exit 0.

- **claude is cut over to the orchestrator program, and its 2,700-word prose body is deleted.** Third platform, one edit to `AFK_LAUNCHER_VARIANTS`: `skills/crew-afk/claude.SKILL.md` is a 449-word launcher that runs `node .coding-crew/crew-afk/main.mjs run --platform claude`, and `skills/crew-afk/SKILL.md` — the last hand-written orchestrator — is **deleted**, not kept in parallel. Every launcher rule in `tests/crew-afk-launcher.bats` now applies to claude, and `tests/shared-dispatch-body.bats` asserts no launcher platform is left mapped to the shared prose body.

  **Three decisions, each answered by a probe rather than by documentation** (Claude Code 2.1.221), recorded in `.scratch/crew-afk-as-code/issues/done/03-claude-launcher-cutover.md`. (1) `claude -p --agent <name>` **does** resolve the project-level `.claude/agents/` definition (a throwaway agent's instruction won over the question asked), enforces that definition's `tools:` list (an agent with `tools: [Read]` answered `NO-BASH-TOOL`), and exits **1** with `--agent '<name>' not found. Available agents: …` on an unknown name — it never silently falls back. So the belt-and-braces `--append-system-prompt <agent body>` is **removed**: it re-sent the coder's whole ~1,000-word definition inside every worker's system prompt on top of the one Claude had already loaded, and an append *overrides* the definition on conflict, which is backwards for a fallback. A missing definition is still caught twice, by `preflight()` before round 1 and by the CLI after. (2) `--permission-mode bypassPermissions` stays the default, because it removes the *prompt* and not the allowlist — the agent definition's `tools:` list still binds, so `crew-code-reviewer` remains read-only under bypass. A narrow `--allowedTools` was rejected as unwritable in advance: a worker runs the consuming project's own checks, so the list is either `Bash(*)` (bypass with a false sense of narrowness) or a per-repo enumeration that stalls the first sprint that meets an unlisted command. (3) `isolation: worktree` is **removed** from `agents/crew-coder/claude.agent.md`: `orchestrator/lib/worktree.mjs` creates `.scratch/worktrees/<branch>` for every platform now, so the key described a mechanism no sprint runs and would have nested a second runtime worktree inside the orchestrator's. `cleanup-worktrees.sh` keeps sweeping `.claude/worktrees/agent-*` / `worktree-agent-*`, because repos that ran earlier sprints still have them. "Dispatch in batches of 3", the claude body's only concurrency control and enforced by nothing, is `--max-parallel` (default 3 for claude).

  **The bug only a real sprint could find is platform-general: the structured report has to be a file the worker writes.** A live claude sprint spent round 1 as `blocked / no Status: line in the worker report` — the work was implemented, tested and committed, but `claude -p` prints only the final message, that message ended with a sentence of summary instead of the JSON block, and a pessimistic parser correctly refused to guess. The sidecar was offered as an *alternative* ("the same block may be written to … instead"); `orchestrator/lib/prompts.mjs` and all three launcher `crew-coder` definitions now require writing `<slug>.report.json` **as the last action**, because a file write does not depend on how a message ends. The re-run merged in a single round. `tests/orchestrator/contract.test.mjs` asserts every launcher coder asks for it, and `report.test.mjs` asserts the prompt does.

  **Nothing was deleted before its code equivalent existed.** claude's prose assertions across seven bats files (pre-merge review order, retention and resume, the report path and the no-verified-branch skip, cleanup scoping, the model in the summary, coverage validation's position in the wrap-up, tracker configuration) are replaced by seven new cases in `tests/orchestrator/sprint.test.mjs` that run the behaviour on a real faked-dispatch sprint — gate order read from the trace log (`VERIFY` → `ACVERIFY` → `MERGE` → `CLOSE` → `SQUASH`), a retained branch surviving cleanup and being named in the summary while round 2's prompt says "Resume on that existing branch", a merged branch losing both worktree and ref, `Model:` rendered from `sprint-state.json`, and coverage validation off-by-default/on-with-`--coverage` between squash and cleanup — plus six adapter cases in `dispatch.test.mjs`. `dispatchPlain()` gained the same `CREW_FAKE_DISPATCH` seam the worker dispatch has, so the coverage step is exercisable for zero tokens instead of being the one wrap-up step no test ran. Claude's `crew-coder` report contract is migrated from the prose orchestrator's `checks` array to the parser's `checks{test,lint,typecheck}` object, which is what `contract.test.mjs` existed to force. 590 bats + 62 node tests green, nothing skipped.

- **codex is cut over to the orchestrator program, and its prose body is deleted.** Second platform, same discipline as pi: `skills/crew-afk/codex.SKILL.md` is a 434-word launcher that runs `node .coding-crew/crew-afk/main.mjs run --platform codex`, streams it, and maps its exit codes; `skills/crew-afk/fragments/codex/` and the `body.codex` registry mapping are **deleted**, not maintained in parallel. `codex` moves from `AFK_PROSE_VARIANTS`/`AFK_PROSE_DISPATCH_VARIANTS` into `AFK_LAUNCHER_VARIANTS` in `tests/helpers/render.bash` — one edit, and every launcher rule in `tests/crew-afk-launcher.bats` (now a loop over that list, not a pi-shaped file) applies to it: word budget, exit-code coverage, and the standing ban on naming `state.sh`, `receipts.sh`, `merge-branches.sh`, `close-issue.sh`, `promote-findings.sh`, `verify-worktree.sh` or `git worktree add`. The assertions the deleted fragments carried move to `tests/orchestrator/dispatch.test.mjs` (8 cases: which dispatcher runs, worker pinned to its worktree, reviewer run from the main checkout on the coder's model, `--model inherit` passing no model, project-then-home TOML resolution, and preflight naming the install command). `tests/shared-dispatch-body.bats` now guards the shrinking prose mechanism generically and asserts its platform list is non-empty, so it cannot go green by iterating nothing.

  **Running it for real found two bugs that prose review could not.** (1) A codex worker could edit files but never commit them: codex's `workspace-write` sandbox keeps `.git` read-only even when its parent is passed with `--add-dir`, and a linked worktree's index lives at `<main>/.git/worktrees/<name>/index.lock` — so `git add` failed with `Operation not permitted`, the worker reverted its work and reported `blocked`, and the sprint stalled at round 1 with nothing merged. `dispatch-codex-agent.sh` now passes `-c sandbox_workspace_write.writable_roots=["<git-common-dir>"]` for a writable sandbox, and nothing for the read-only reviewer, which never commits. **The sandbox is part of the adapter contract**, not an environment detail. (2) The acceptance-criteria gate could never pass a criterion phrased "…and `npm test` passes": the reviewer is read-only, so it answered `AC: unmet — not executed in this inspection-only review` and the branch was retained every round, forever. This half is platform-general — the same issue would stall a pi or claude sprint. `parseVerifyChecks()` reads `verify-worktree.sh`'s own `TEST/LINT/TYPECHECK` lines and the review prompt states them, so the reviewer judges the code and takes execution as established; `not_run` is still evidence of nothing, "no file and line, no evidence, `unmet`" still holds for everything else, and `agents/crew-code-reviewer/protocol.md` carries the same rule so a prose platform behaves identically. Verified end to end afterwards on a scratch repo: worker → verify → review (`AC: all-met`) → receipts → merge → close → squash → cleanup → summary, exit 0, tests green in the merged tree.

- **The two report contracts moved into the agent definitions, where they can no longer be silently contradicted.** `orchestrator/lib/report.mjs` parses a worker's structured result and a reviewer's findings, but both shapes existed only in the prompts the orchestrator builds — and the failure mode of a definition that disagrees is quiet, not loud: a `checks` **array** where the parser indexes `checks.test/lint/typecheck` reads as three `not_run` categories, which demotes a clean branch to `partial` for "tests not run". The launcher platforms' `crew-coder` variants (pi, codex) now state the `<slug>.report.json` sidecar / fenced-JSON block — `status`, `branch`, `working_directory`, `checks{test,lint,typecheck}`, `criteria[]`, `progress`, `notes` — alongside the markdown report humans read, and `agents/crew-code-reviewer/protocol.md` states the `FINDING: <SEV> | <file:line> | <one verifiable fix criterion>` line that makes promotion into a fix issue parse one line instead of re-reading prose. The schema is **not** copied into any skill body: the prompt builder and the definition are two places already. `tests/orchestrator/contract.test.mjs` reads `AFK_LAUNCHER_VARIANTS` out of `tests/helpers/render.bash`, asserts the declared field names are exactly the parser's, round-trips the definition's own JSON template through `parseWorkerReport()` so a drifted example fails in CI rather than mid-sprint, and keeps the markdown fallback covered — so the next cutover fails here until that platform's contract is migrated. Paid for by cutting duplication: the coder's 7 report rules restated the schema printed directly above them and are now 4, and the reviewer protocol's word budget rises 1,500 → 1,560 (chain 2,150 → 2,210) for the two machine contracts, with the justification recorded on the budget itself.

- **crew-afk's orchestrator is a program on pi, and the pi prose body is deleted.** An orchestrator prompt is not a state machine, and every failure class observed in real sprints was control flow: a feature slug re-derived with an alphabetical `ls .scratch/*/sprint-state.json | head -1` glob, a branch merged whose `VERIFY` was `fail`, an issue closed off a sibling's branch, cleanup skipped because a round ran long, a hung `pi -p` blocking `wait` forever. Receipts can only fail *closed* — nothing could make a skipped step run. The loop now lives in `orchestrator/` (dependency-free Node ≥ 20, ~1,770 LOC): `tracker.mjs` (issue selection, `Status:`/`## Blocked by`, section splicing), `report.mjs` (report parsing + the schema pre-filter), `sprint.mjs` (sprint.env / sprint-state.json through the existing scripts), `pipeline.mjs` (the `verify → review → AC receipt → promote → merge → close` chain as one function body), `loop.mjs` (rounds, stall, Phase 1 → flush → Phase 2, wrap-up), `worktree.mjs`, `prompts.mjs`, `dispatch.mjs`, `effects.mjs`. **JS owns control flow, bash keeps the effects** — `verify-worktree.sh`, `merge-branches.sh`, `close-issue.sh`, `receipts.sh`, `promote-findings.sh`, `squash-commits.sh`, `cleanup-worktrees.sh`, `state.sh`, `trace.sh` and `crew-summary.sh` are unchanged and still runnable by hand. pi's `SKILL.md` is a 390-word launcher (was ~2,400 rendered words) that runs the program, streams it, and maps its exit codes (`0` finished · `2` stalled · `3` nothing ready · `1` setup error); `skills/crew-afk/fragments/pi/` is **deleted** rather than kept in parallel, because two maintained orchestrators is the drift the shared body was built to end. claude/codex/copilot are untouched and still prose — `tests/helpers/render.bash` now holds the single list (`AFK_PROSE_VARIANTS`) of which platforms those assertions apply to, so the next cutover moves a name once.

  Three things become possible only as code, and each was an observed failure: a **hard per-worker timeout** (`--worker-timeout`, default 45m) so a hung worker cannot hang a sprint; **real concurrency control** (`--max-parallel`) instead of "batches of 3" in prose; and **`crew-afk plan`**, a read-only dry run that prints what a sprint would do for zero tokens. Reports are now parsed *pessimistically*: a `<slug>.report.json` sidecar or a fenced JSON block is preferred, the markdown headings remain a fallback, and an unparseable report is `blocked` — never a silent `complete`. The reviewer is asked for one `FINDING: <SEV> | <file:line> | <criterion>` line per finding, which makes promotion mechanical (bracket severities remain the fallback, so an un-upgraded reviewer still works — verified against a live sprint).

  Testing changes character: `CREW_FAKE_DISPATCH` replaces every model dispatch with a script, so the whole state machine is exercisable without tokens. `tests/orchestrator/` (32 node:test cases, run through `tests/orchestrator.bats` so CI shards them) covers the clean merge path, a worker-reported failing check, an `AC: unmet` verdict, an empty review report, an unparseable report, a dead dispatch, blocked-by ordering across rounds, CRITICAL promotion into Phase 2, and the two-dry-round stall — paths that previously could only be observed by burning a real sprint. `install.sh` gains skill `assets` support (`install_assets_tree()`, shared with agent assets): repo-root-relative source, installed **once per run rather than once per platform** to `.coding-crew/crew-afk/`, always overwritten, removed on uninstall. The node suite lives outside `orchestrator/` so a consumer repo receives the runtime and nothing else — `tests/crew-afk-launcher.bats` (13 tests) asserts that, the launcher's word budget, its exit-code coverage, and that it never again names `state.sh`, `receipts.sh`, `merge-branches.sh`, `close-issue.sh`, `promote-findings.sh`, `verify-worktree.sh` or `git worktree add`.

- **Stage B of the crew-afk token diet: the acceptance-criteria check moved inside the code review, so every branch costs one agent and one diff read less.** AC verification was a second, independent pass over the diff the reviewer already reads, asking a question the reviewer's HIGH class #1 already asked ("does the implementation satisfy the acceptance criteria?") — a whole extra agent per branch on claude and codex, and on pi and copilot a full branch diff pulled into the *orchestrator's* context, where it stayed for the rest of the sprint. `crew-code-reviewer` now returns both halves of its single read: an `AC: all-met | unmet — …` line directly under its `## Branch:` heading, and the findings below it. The verdict is a gate (the orchestrator writes the `ac` receipt from it, and `close-issue.sh` still refuses to close without one); the findings stay advisory. Independence is preserved — the reviewer is read-only and is not the coder. The three `ac-verify` fragments are deleted, the pipeline is now `verify → review (acceptance criteria + findings) → merge → close` in all four bodies, and pi/codex read the verdict with `grep -m1 '^AC:'` on the report file rather than judging it. **The gate fails closed**: `AC: unmet`, a `SKIPPED:` block, a dead dispatch, or no verdict at all demotes the branch to `partial` with reason `review-not-run` — a review that did not happen is a criteria check that did not happen, so "advisory" can no longer degrade into an unverified merge. The review gap is still recorded with `promote-findings.sh mark-not-run` and still surfaced as `## Unreviewed Branches`; the orchestrator still must not review the branch itself. New `tests/crew-afk-ac-in-review.bats` (14 tests) locks the fold and the fail-closed default, including a negative check that no body reads a branch diff in the orchestrator session; `tests/crew-afk-review-gaps.bats` is retargeted from "an unreviewed branch still merges" onto "an unreviewed branch is kept out of the merge"
- **The reviewer's dependency audit runs only where its output is read.** `dependency-audit.sh` ran once per reviewer dispatch, but its only consumer is the `### Dependency Audit` block of the *multi-branch* session summary — and crew-afk dispatches per branch, so the audit was generated and discarded every time. It is now gated on a multi-branch review or a diff that touches a manifest or lockfile. `review-context.sh` stays unconditional: it is what selects the checklists. The three overlapping precision sections (`Confidence-Based Filtering`, `Pre-Report Gate`, `Zero Findings Is Valid`) merged into one `## Precision` section, keeping every rule and both grep anchors; `Common False Positives` is untouched on purpose — a false HIGH now costs a whole extra fix-and-review cycle, so precision is a token saving. New budget test caps the per-branch reviewer chain (protocol + widest reference selection) at 2,150 words
- **`dep-install` is failure-triggered rather than unconditional.** `solve-issue` §2 read the skill and ran an install for every issue — including in worktrees that symlink `node_modules` via `.worktreeinclude`, and in repos with no dependency step at all. It is now invoked up front only for a docker-mode project (`git config --local agent.install-mode`, or an existing `docker-compose.override.yml`, because the mode decides how every later command runs), and otherwise only when a command fails for a missing dependency — which is dep-install's own retry rule, applied to the first failure instead of to every run. Saves 800–1,250 words and 2–4 tool calls per issue; `dep-install` now states that it is invoked on demand and must not re-litigate whether install is needed

- **…and eager in a sprint, where a gate cannot retry. One decision, two halves: eager where a gate cannot retry, lazy where a human can.** The entry above is the whole policy only for a *direct* `solve-issue` run, where the worktree usually already has deps and the unconditional read bought nothing. It was the wrong policy for a sprint, where the orchestrator creates every worktree fresh and where one consumer of the deps is not a model at all: `skills/crew-afk/scripts/verify-worktree.sh` runs `npm test` / `pytest` in the worktree with **no dep recovery path**, because it is a gate and a gate cannot invoke a skill. Three failure modes, each costing a full round — a worker reading a missing dependency as a broken repo and reporting `blocked` (or "fixing" the import error by editing code); a resumed or retained worktree reaching the merge gate bare, scoring `TEST: fail`, and being demoted to `partial` with nothing merged; and every one of the N parallel workers rediscovering this independently, mid-implementation.

  So provisioning is **mechanism in the orchestrator**, on the same reasoning as receipts and cleanup: the host path has no judgement in it, and a script covers `verify-worktree.sh`, which reverting §2 would not. New `skills/crew-afk/scripts/ensure-deps.sh` reuses `dep-install`'s `detect-mode.sh` / `host-install.sh` **verbatim** — no new install logic, and `host-install.sh` stays the only place that knows package managers. Called twice, both through `effects.bash()` so `--dry-run` records them: once per sprint against `$MAIN_ROOT` (`sprint.mjs` `init()`, warming the cache before N parallel installs), and once per worktree between `applyWorktreeInclude()` and `dispatch()` (`pipeline.mjs` `runWorker()`) — that position is the whole point, being after the include and before *both* the worker and the verify gate. `--no-deps` removes both, and `CREW_DEPS=off` disables the script, for the same reason `CREW_RECEIPTS=off` exists.

  Four decisions worth keeping. **A failed install is advisory, never fatal**: `ensure-deps.sh` always exits 0 and the orchestrator logs its one `DEPS:` line without branching on it, so an install failure cannot demote an issue by itself — the consequence is caught by `verify-worktree.sh`, which already fails closed, and failing fast would save one dispatch while stalling a whole sprint on any environment quirk (the rule `dependency-audit.sh` already follows). **The presence check is the guard, the marker is only a cache**: a repo whose dep dir is already there — inherited via `.worktreeinclude`, or left by a prior round — costs nothing, and the `<slug>.deps.<ok|skip>` marker exists only so a `none`/`failed` probe is not repeated every round. **No symlinking `node_modules`/`.venv` from the main root**: cheaper than an install, but `.venv` carries absolute paths and some toolchains write into `node_modules`, so parallel workers would share mutable state; `.worktreeinclude` remains the explicit opt-in. **Docker mode is deferred, not handled** — generating an override is judgement, so it stays with the skill. `install.sh` now ships `dep-install`'s scripts once to `.coding-crew/dep-install/scripts` via the existing skill-`assets` mechanism, so a platform-neutral orchestrator does not have to guess which of the four platform skill dirs a repo installed; the per-platform copies stay, because `SKILL.md` still tells the model to run `scripts/detect-mode.sh` from the directory it read the skill from. **`solve-issue` and `tests/worker-chain-token-budget.bats` are untouched**, so the token diet and its test stand, and no launcher `SKILL.md` names the new script (`tests/crew-afk-launcher.bats` fails if one does). 26 new tests: `tests/crew-afk-ensure-deps.bats` (20) on the contract, `tests/dep-install-assets.bats` (6) on the one-copy install, and new `tests/orchestrator/sprint.test.mjs` cases asserting the two positions **on the recorded command order** rather than on prose — including the regression itself, a fixture whose `make test` can only pass if something ran `make install` first, which merges with the call sites in place and stalls with `verification-failed` under `--no-deps`

- **Stage A of the crew-afk token diet: the per-issue worker chain lost ~20% of its words and ~4 shell round trips per issue, with no behaviour change.** A sprint reads the orchestrator body once but the worker chain once *per issue*, so the chain is the multiplier — and most of what it cost was saying the same thing twice. The PRD read existed in `crew-coder` (`.scratch/<feature-slug>/PRD.md`) *and* in `solve-issue` §1.5 (the path from the issue's `## Context Documents` section); §1.5 now resolves the section path **and** falls back to the conventional path, so nothing is lost and the agent's copy is gone — with it the second feature-slug derivation, which is now done once, where the trace path needs it. The worker trace collapsed from six markers to `[START]`/`[DONE]`: `[PHASE]`/`[CMD]`/`[READ]`/`[WRITE]` cost roughly ten extra shell calls per worker to produce a log nobody reads mid-run. Two worked example reports became one — the `partial` one, which teaches the complete/partial boundary the schema above it cannot; the `complete` one only re-demonstrated the format that schema already specifies. `solve-issue` lost its `## Tracker Configuration` section (a one-link "lookup chain", now one line under `## Inputs`), its step-0 `feature-branch-setup.sh` call (**provably dead**: the script acts only on the default branch, which the mandatory guard directly above it has already refused), the §0.1 dirty-worktree pre-flight, and the step-6 checklist that re-asserted what steps 4 and 5 had just run — a checkbox cannot verify itself. Blocked-by resolution and the `tdd` planning gates were compressed rather than deleted, because each is the sole enforcement of its rule on a direct, non-orchestrated invocation. New `tests/worker-chain-token-budget.bats` puts a ceiling on the chain so the duplication cannot return as prose; `tests/crew-coder-per-agent-trace.bats`, `tests/trim-redundant-prescription.bats`, `tests/crew-coder-context-reading.bats`, `tests/prompt-integrity.bats` and `tests/implementation-skills-preamble.bats` were retargeted onto the surviving location of each rule, never deleted
- **`ACVERIFY` is traced by the script that writes its receipt.** It was the one marker an orchestrator hand-wrote, as a second bash call beside `receipts.sh write ac` — two calls for one event, and a marker a prompt can emit for a gate that never ran. `receipts.sh write ac` now emits it (verify receipts stay with `verify-worktree.sh`, which runs those checks), tracing failures can never fail the gate, and `tests/crew-afk-receipts.bats` asserts no variant hand-writes it. The merge/close/`state.sh complete` sequence is chained on the merge's success in one block, and the worktree is removed once (after verification) rather than twice
- **Nothing installs that no agent runs.** `skills/crew-afk/scripts/README.md` (2,082 words of maintainer notes) moved to `docs/crew-afk-scripts.md`, outside the installed tree — an agent that lists a skill directory reads what is in it. `skills/crew-afk/references/verification.md` is deleted: it was the third description of `verify-worktree.sh`, after the script's own header and each skill body, and its assertions in `tests/prompt-integrity.bats` moved onto the script and the bodies. `install.sh` sweeps a per-skill list of retired files on every install, keyed by skill name because `solve-issue` still ships its own `references/verification.md`. `caveman` is no longer a `deps` of `crew-afk` — it is a communication mode, not part of a sprint, and remains installable on its own

### Fixed

- **Copilot support was installed to a path Copilot does not read, and dispatched with a tool Copilot does not have.** Both halves failed silently, which is why a Copilot sprint looked configured and then did the work inline. (1) A project-level install wrote agents to `.copilot/agents/` and skills to `.copilot/skills/`; Copilot scans `.github/agents/` (or `.claude/agents/`) and `.github/skills/` in a repo, and only `~/.copilot/...` in `$HOME`. Verified against Copilot CLI 1.0.77: a skill under `.copilot/skills/` never appears in `copilot skill list`, and dispatching an agent stored there answers `Unknown agent_type: <name>. Valid types are: explore, task, general-purpose, …`. `adjust_platform_path()` now rewrites copilot's registry paths (written user-style) to `.github/…` for a project checkout — the mirror image of the existing pi rule — `install.sh` deletes the legacy `.copilot/` project copy when it writes the `.github/` one, and `uninstall.sh` sweeps both so a dead copy cannot survive a clean uninstall. (2) `crew-afk`'s Copilot body instructed `#runSubagent crew-coder`, which is **VS Code Copilot Chat** syntax with no equivalent in the Copilot CLI; the CLI's only subagent mechanism is the `task` tool, so every dispatch failed and the orchestrator fell back to implementing issues itself — the one thing the skill forbids. The copilot fragments now dispatch with `task(agent_type="crew-coder", prompt="…")` (and `general-purpose` for the AC-verification and coverage-validation steps), name the two locations Copilot actually loads agents from so `Unknown agent_type` is diagnosable rather than fatal, state that subagents share the parent working root (the `Working directory:` line is the isolation), batch dispatches to the plan's concurrency cap (Free 2 … Enterprise 32), and pre-approve `allowed-tools: shell, task` so an unattended sprint cannot stall on a permission prompt. `--model` is still accepted-and-ignored, now for the accurate reason: the model is session-selected and inherited by subagents, with per-agent overrides in `~/.copilot/settings.json` → `subagents.agents.<name>.model`. New `tests/copilot-platform.bats` (12 tests) covers install locations at both scopes, legacy-copy pruning, uninstall sweep, and the dispatch prose; `tests/crew-afk-pre-merge-review.bats` no longer passes its review-before-merge check on a `crew-code-reviewer` mention in the frontmatter description

## [1.23.0] - 2026-08-12

### Changed

- **Windows CI: 27+ minutes down to a sharded ~5.** The suite's cost is process spawning, not computation — one full `install.sh` spawns ~3,300 processes (1,564 of them `jq`), the tests run it ~84 times, and Git Bash emulates `fork()` at ~5-50ms a spawn. Four changes: the `jq()` CR-normalisation wrapper strips `\r` in-shell instead of piping through `tr` (three processes per lookup became one) and is now defined only on a jq that actually emits `\r`, so Linux and macOS call the binary directly; `.github/workflows/ci.yml` shards Windows across four matrix jobs via `scripts/ci-test-shard.sh` (bats' own `--jobs` needs GNU parallel, which the Windows runner lacks); bats-core is cloned at a pinned tag instead of `npm install -g bats`, dropping the Node setup entirely; and Defender excludes the runner temp and workspace trees, which the installs fill with thousands of small files. Sharding is only safe as a partition, so `tests/ci-test-shard.bats` asserts the union of shards is the whole suite, that no file appears twice, and that the matrix declares every index of each shard count it uses — a test file that fell out of every shard would otherwise stop running and CI would still go green. Remaining ~1,500 `jq` calls per install are tracked in `.scratch/ci-windows-speed/issues/open/01-batch-registry-jq-reads.md`

### Fixed

- **Windows installs no longer silently skip items.** jq on Windows (Git Bash) writes stdout in text mode, so every value read back carried a trailing `\r`. `--from-lockfile` looked up the skill name `tdd\r` in `registry.json`, missed, printed `Warning: skill 'tdd' not found in registry v1.17.0 — skipping`, and exited 0 having installed nothing. The `\r` was previously stripped per read loop, so every loop added afterwards (the `crew.lock` and manifest loops) was unguarded again — `install.sh`, `uninstall.sh` and `scripts/render-skill.sh` now normalise jq's output once in a single `jq()` wrapper (defined only when a probe shows jq appending `\r`; `$?` after the assignment is jq's own status, so `if ! jq empty` still works), which no new call site can forget. Guarded by three tests in `tests/install.bats` that stub jq to emit CRLF and assert a plain install, a `--from-lockfile` install, and an uninstall all still land their files

## [1.22.0] - 2026-08-12

### Added

- **Conditional code review references and asset infrastructure.** `crew-code-reviewer` now loads framework-specific checklists (React, backend, web security) only when the codebase contains signal files (package.json deps, `go.mod`, `requirements.txt`, `.tsx`/`.html` files), reducing token usage and review scope creep
  - New **review-context.sh** — detects stack signals and selects applicable references. Runs once per branch, output piped to the protocol as `STACK:` and one `REFERENCE:` line each
  - New **conditional references** — `quality.md` (always), `react.md` (React), `backend.md` (Go/Python/Ruby), `web-security.md` (web frameworks)
  - New **dependency-audit.sh** — runs language-specific audit tools (`npm audit`, `go mod verify`, `pip check`, `bundle check`) sequentially, verbatim output, always exits 0. Tool unavailability is `NOT RUN: <tool>` not a failure — audits are opt-in discovery, not blockers
  - Registry gains `install.assets` — platform-neutral runtime files copied once per install (never per platform), always overwritten on re-install, removed on uninstall. Asset paths are named in `install.sh` so build inputs are never shipped to consumers
  - Protocol now references `$ROOT/.coding-crew/code-review/` for all files; fallback reads every file in `references/` if script/assets are absent (older installs remain functional but unoptimized)
  - Covered by `tests/crew-code-reviewer-references.bats` (18 tests): reference union completeness (every pre-trim item still exists), no unused references, script signal detection, dependency audit tool discovery, install/uninstall asset handling, and pre-trim/post-trim file consistency

## [1.21.0] - 2026-08-12

### Changed

- **The worker's close is now mechanically impossible during a sprint (audit P4).** A worker that closes its own issue removes it from the `ready-for-agent` list, so an orchestrator gate that later demotes the result to `partial` has nothing left to re-dispatch and the unmerged branch is silently orphaned. Three `crew-coder` variants argued against this in ~150 words each while `solve-issue` step 7 told the worker to close anyway, with the contradiction resolved only by a prose exception. Prose cannot fail closed
  - New **`scripts/tracker/mark-issue-done.sh`**, installed to `.coding-crew/scripts/mark-issue-done.sh` — the implementation of the tracker's `mark-done` operation. Exit **3** when an orchestrator owns the close (`.scratch/<feature-slug>/.orchestrated` exists, or `CREW_ORCHESTRATED=1`), exit **4** when a `- [ ]` remains under `## Acceptance criteria` or `## Cross-cutting Requirements`, exit **0** (idempotent) when the issue is already in `done/`. `--force` overrides both refusals, for a marker left by a crashed sprint or a criterion recorded as descoped
  - `crew-afk`'s `session-init.sh` writes the `.orchestrated` marker; `crew-summary.sh` removes it on the **final** summary only (`--no-reminder` is the per-round rollup, when the sprint is still running), so a marker never outlives its sprint and blocks a standalone run. The orchestrator's own `close-issue.sh` is deliberately unaffected by the marker — it is the orchestrator, and it stays gated by its acceptance-criteria receipt instead
  - The tracker template's `mark-done` operation now delegates to the script and documents the two refusals as expected outcomes; it no longer ships a hand-rolled `sed`/`mv` that bypasses them
  - `solve-issue` step 7 lost the orchestrated-run exception (the script enforces it), and `crew-coder`'s **Issue Ownership** shrank from three paragraphs to two sentences that cite the refusal
- **Non-interactive branches for the two mandatory reads that had no addressee.** `tdd` §1 ("Confirm with user…", "Get user approval on the plan") and `solve-issue`'s unmet-criteria path ("ask the user how to proceed") are read by headless `pi -p` workers with nobody to ask. Both now name the non-interactive case explicitly: `tdd` treats the issue's acceptance criteria as the approved plan and proceeds; `solve-issue` records `## Unmet criteria` and reports `partial` instead of stalling on a question no one will read
- `registry.json` gained a `docs.scripts` map for tracker mechanism. Unlike `docs.templates` (user-customisable, never overwritten, never uninstalled), these are always overwritten on install and removed on uninstall — a stale copy would be a gate that no longer matches the operation calling it
- Covered by `tests/worker-close-guard.bats` (24 tests): each refusal and its exit code, that the issue is still listed as open after a refusal, `--force`, the section-scoped criteria check (an unchecked box under `## Notes` does not block), marker write/removal across the sprint lifecycle, `close-issue.sh` still closing with the marker present, install/overwrite/uninstall of the script, and the documents pointing at the mechanism instead of re-arguing it. `tests/workflow-integrity.bats`' B4 prose grep was rewritten to assert the refusal. Suite: 487 → 511 tests

## [1.20.0] - 2026-08-12

### Changed

- **`crew-afk` (1.18.0) — the orchestrator's mechanism moved out of the prompt and into scripts (audit P3).** An orchestrator is a state machine, and the parts of this one that were prose behaved like prose: a sprint re-derived the feature slug with `jq -r .feature_slug "$(ls -1 .scratch/*/sprint-state.json | head -n1)"` — an alphabetical-first glob that picks the wrong feature in any repo with two sprint dirs — sitting directly beneath a comment reading "Never re-derive it"; `[DISPATCH]` was traced twice, once by `dispatch-agent.sh` and once by an instruction to echo the same line; and the summary was a ~430-word print template filled in from lists carried in context since round 1, which is the one place a dropped entry is invisible (a retained branch missing from the summary reads as a clean teardown)
  - `session-init.sh` now writes **`sprint.env`** (`.scratch/<feature-slug>/sprint.env`, plus a `.scratch/sprint.env` pointer) exporting `MAIN_ROOT`, `FEATURE_SLUG`, `FEATURE_BRANCH`, `SPRINT_DIR`, `STATE_FILE`, `TRACE_LOG`, `DISPATCH_DIR`, `REVIEW_DIR`. Every body sources it at the top of each bash block; the slug is resolved once, where the issues actually live
  - New **`trace.sh`**: each script traces its own step (`SESSION`, `DISPATCH`, `VERIFY`, `MERGE`, `CLOSE`, `PROMOTE`, `FLUSH`, `CLEANUP`, `SQUASH`, `MODEL`, `ROUND`, `STATE`, `EXIT`), so a step that ran is always traced and a step that was skipped can no longer be traced as if it had run. The duplicate `[DISPATCH]` echo is gone. It resolves the log through `sprint.env` and is a silent no-op with no sprint present — tracing must never fail the caller making progress
  - New **`state.sh`** (`complete` / `retain` / `blocked` / `coverage-gap` / `model` / `round` / `resume` / `get`) replaces the raw jq one-liners and the "append to `all_merged` / `all_partial` / `all_blocked`" bookkeeping. `get merged` and `get retained` now feed `cleanup-worktrees.sh`, so the certified lists come from disk; `retain` is the one entry point for every branch that must survive, and `complete` clears the retention so a stale branch is never offered for resume
  - New **`crew-summary.sh`** renders the rollup, `## Verification Failures`, `## Coverage Gaps`, `## Retained Branches`, `## Promoted Findings` and the findings reminder from `sprint-state.json` and the review reports. A review gap is still never suppressed by a clean findings count, and still never counted as a finding — but that rule is now executed once instead of restated in four bodies
  - Orchestrator bodies: **4,345 → 2,828 words** (Claude) and **4,130 → 2,442 words** shared (pi/codex/copilot render at ~3,240), with the deleted text being narration of script internals, print templates, and re-explanations of decisions a script already enforces
- Covered by `tests/crew-afk-state.bats` (30 tests): `sprint.env` contents and that it names the sprint the issues live in rather than the alphabetically-first one, `trace.sh` resolution and its no-op path, per-script `MERGE`/`CLOSE`/`EXIT` markers, `state.sh` retain/complete/idempotence/`resume`/`get` disjointness, `crew-summary` rendering including the gap-vs-findings interaction and promoted-findings read-back, that no body re-derives the slug or hand-rolls a script's trace marker, and a 3,000-word budget per body
  - Six prose assertions in `tests/retain-partial-work.bats`, `tests/crew-afk-review-gaps.bats` and `tests/crew-afk-pre-merge-review.bats` were rewritten to assert the script's behaviour instead of the sentence that described it — the P0 half of the audit, applied where P3 touched. Suite: 455 → 487 tests


## [1.19.0] - 2026-08-12

### Changed

- **Unified dispatch skill rendering via fragments** — the `crew-afk` skill variants (pi, codex, copilot) were three ~5,000-word files that were 85–90% identical and drifting. They now render from a shared `dispatch.SKILL.md` body by inlining platform-specific fragments from `fragments/<platform>/<key>.md`. A missing fragment or surviving `{{...}}` placeholder is a hard error — preventing body gaps from shipping to consumers
  - New `scripts/render-skill.sh <skill> <platform>` — renders bodies by substituting `{{FRAGMENT:<key>}}` and `{{PLATFORM}}` inline. `install.sh` calls it for every skill it installs
  - Rendered bodies are self-contained and require no build inputs; fragment directories are build inputs and never installed. A fragment tree left by an older install is pruned on re-install
  - Parity held by `tests/shared-dispatch-body.bats`: tests run against the **rendered** body (not a source variant), asserting identical section structure and pipeline order across platforms, and verifying install renders and ships no build inputs
- **Platform file support in registry.json** — each skill may declare `platform-files`, a map of paths that are installed only for specific platforms. Other platform-specific files are copied to `platform-files` and pruned on re-install
- `install.sh` now idempotent across platforms: files from unselected platforms are deleted on re-install, so downgrading (e.g., pi-only) cleans up `.claude/`, `.copilot/`, `.codex/` artifacts
## [1.18.0] - 2026-08-12

### Fixed

- **`crew-afk` (1.16.0) — a code review that never ran was reported as a clean review.** Review is advisory by design and never blocks a merge, but the failure shape made "advisory" decay into "reported as clean": a dead reviewer dispatch (timeout, killed process, crashed CLI) writes no `--out` file, so nothing is appended to `.scratch/<slug>/reviews/`, so `remind` globs an empty directory and prints `FINDINGS: none`. The sprint ended telling the user there was nothing to triage, on branches nobody had looked at
  - Observed in the wild as the orchestrator improvising `Reviewer timed out. I'll perform the review inline` — a fallback that appears in no variant, because none of them specified what to do when a reviewer fails. An inline self-review is strictly worse than none: it writes no report, so `defer` has nothing to read (it hard-dies on a missing `--report`), CRITICAL/HIGH findings never reach Phase 2, and the review exists only in the orchestrator transcript, lost at session end. It also discards the reviewer's fresh read-only context, which is the entire reason review is a separate agent
  - New `promote-findings.sh mark-not-run` records the gap as a stub `## Branch:` block carrying `Review: not_run — <reason>`, **creating the report if no branch produced one** — that is the load-bearing part, since an absent file is what made the gap invisible. Idempotent per branch, so a dispatch retried and failed twice counts once
  - `remind` now counts unreviewed branches separately from findings and prints `REVIEW-GAPS: branches=<N>` with a `gap: <branch> — <reason>` line each, *in addition* to the findings line and never folded into its count (a not_run branch produces no findings by definition). `No open review findings.` can no longer stand alone while a gap exists
  - All four variants now specify the failure path explicitly and forbid the inline self-review, so the model has an instruction to follow instead of a hole to improvise into
  - Same `not_run` convention `verify-worktree.sh` already uses for undiscoverable check commands: an unknown result is recorded as unknown, never as a pass
- Covered by `tests/crew-afk-review-gaps.bats` (14 tests), including the exact silent-loss case (zero findings + one unreviewed branch), that the marker is not miscounted as a finding, that promotion subtraction still works alongside a gap, and that all four variants carry the failure path and the `REVIEW-GAPS` handling

### Notes

- Not related to the v1.17.3 dispatcher fix, though it surfaced while investigating the same sprint: verified that bash 4.4 and 5.2 perform the offending whole-string substitution in 0ms even at 100KB, so Linux was never affected by that bug
- The reviewer's timeout exposure itself is unchanged and still open: reviews run as serial blocking calls while coders are backgrounded in parallel, and review cost scales with diff size and finding count. This release makes a timed-out review *visible*, not less likely

## [1.17.3] - 2026-08-12

### Fixed

- **`crew-afk` (1.15.1) — both dispatchers burned 40–140s of CPU per worker before starting work.** `dispatch-agent.sh` (pi) and `dispatch-codex-agent.sh` (codex) validate that an agent definition's instruction body is not blank, and both did it with `[[ -n "${VAR//[[:space:]]/}" ]]`. Pattern substitution over a multi-KB string is O(n²) in bash 3.2 — the system `/bin/bash` on macOS, which is where `#!/usr/bin/env bash` lands by default — so answering a yes/no question rebuilt the whole string one character at a time
  - Measured on macOS bash 3.2: **40s** for `crew-coder.md` (10KB body), **142s** for `crew-code-reviewer.md` (15KB). Paid on every dispatch, serially and single-threaded, before any model call — so a 4-coder sprint with 4 reviews spent roughly **12 minutes** of pure CPU deciding that non-empty strings were non-empty, while starving the parallel workers it had just spawned
  - Replaced with `[[ "$VAR" =~ [^[:space:]] ]]`, which short-circuits on the first non-space character: **0.005s vs 47s** on the same 10KB input, identical semantics across `""`, `"   "`, `"\n\t "`, and `"x"`
  - Linux CI never saw this: bash 4+ does not have the quadratic behaviour, so the bug was invisible to the matrix and only ever hurt macOS users
- Covered by `tests/dispatch-blank-body-check.bats` (5 tests): the check still rejects a whitespace-only body on both platforms, still accepts a body whose only content sits 4KB in (so a first-N-chars shortcut cannot pass), neither script reintroduces the pattern substitution, and a realistic 10KB body completes well inside a deliberately loose 15s bound. Against the previous code the bound test measures **76s**

### Changed

- Test suite wall time drops from **~330s to ~74s** (`tests/codex-platform.bats` alone: 263.5s → 10.4s). The suite was never bloated — 23 of its 27 files already finished in under a second, and 78% of the total runtime was this one production bug being exercised three times

## [1.17.2] - 2026-08-11

### Added

- **Release automation** (`.github/workflows/release.yml`): pushing a `vX.Y.Z` tag now publishes the matching GitHub Release automatically, with notes lifted from that version's `CHANGELOG.md` section and the title taken from the tag annotation
  - This closes a silent distribution failure: `bootstrap.sh` and `install.sh` resolve `--version latest` through GitHub's `/releases/latest` redirect, which only sees Release **objects** — a bare tag is invisible to it. `v1.15.0`, `v1.16.0`, and `v1.17.0` were each tagged hours to days before their Release existed, so every `--version latest` install in those windows resolved to `v1.14.1` and wrote it into `crew.lock`. The lockfile was correct; the release process was not
  - Fatal if the tagged version has no `CHANGELOG.md` section — a release with no notes is the failure mode being removed. Idempotent: re-running (or re-pushing a tag) edits the existing release instead of failing
- **CI release parity check** (`release-parity` job in `ci.yml`): fails the build when any `v*` tag has no corresponding GitHub Release, so the gap is caught on the next push rather than from a consumer's stale `crew.lock`
  - Backfilled the three tags this check found already orphaned: `v1.8.1`, `v1.9.1`, `v1.10.0` (the last had never been pushed at all)

### Changed

- **`crew-grill`** (1.2.0): Phase 1 now filters every frontier node through **two** gates instead of one. The existing router (now **Gate 2 — Consequence**) only ever decided *who owns a fork*; it never asked whether the node was a fork at all, so questions a staff engineer would have looked up sailed through it and reached the user. **Gate 1 — Competence** is that missing question: *would a staff engineer on this team need to ask this, or would they be embarrassed to?* Seven disqualifiers retire a node before it can be routed — **discoverable**, **already answered** (in this conversation or the plan handed over), **testable** by a read-only experiment, **conventional**, **analysis** dressed up as preference ("will this scale?" — the user's answer would be a guess), **deferrable** to implementation time, and **rubber-stamp** (asking permission, not asking for a decision)
  - The root cause was textual: every mention of homework was scoped to the repo — "look up anything discoverable **in the codebase**", "already settled by an **existing repo pattern**" — so a silent repo read as "not discoverable" and licensed asking the user. Lookups now explicitly cover project docs, dependency and vendor documentation, and the open web, and research is *required* before any question turning on third-party behaviour: a library's API, a service's limits, a format's spec are never the user's to answer
  - `wire formats and external contracts` left the *annoyed* list, which had been inviting questions about the one area most likely to be answerable from a vendor's docs. The bullet now splits along the same fact/decision line the gates draw: *what the wire format requires* is a lookup you owe, *which of our shipped formats we break* is a decision you owe the user
  - Ecosystem convention now counts as precedent alongside repo pattern, under the same citation discipline — `path:line` for the repo, the doc or spec for a convention — because an uncited convention is exactly how a preference gets laundered into a fact
  - Each `❓` carries a `checked:` clause naming what was consulted. It is Gate 1's receipt, in the spirit of `crew-afk`'s gate receipts: a prose gate with no artifact cannot be seen to have run, and a question with nothing to cite is research that has not happened yet
  - Two consistency fixes the new gate would otherwise fight: *escalation is cheap* is now scoped to trading between lanes and "never resurrects a node that failed Gate 1", and a quiet round is no longer a smell when its nodes were discharged with citations — with Gate 1 working, quiet rounds are the expected case, and the old rule would have pushed the model back toward asking to prove it was grilling
  - The `~4` cap is restated as "as few as the frontier genuinely blocks on" with the depth instruction made mechanical: drop the round's weakest question outright and spend the freed slot deepening the strongest. A forced deletion produces an edit; an open-ended "review your questions" produces a verdict
  - Gate 1 research is expensive, so the Phase 1 summary and the Phase 2 handoff now carry the **established facts and their citations** into `PRD.md`'s `## Decisions` section — otherwise the implementing agent re-derives them, or re-asks them
  - Covered by `tests/crew-grill-question-gates.bats` (10 tests), all of which fail against the previous wording

## [1.17.1] - 2026-08-11

### Fixed

- **`install.sh` / `bootstrap.sh`**: the `crew.lock` round trip worked in neither direction — three bugs that compounded
  - `write_lockfile` records the release as `v1.17.0`, but `--from-lockfile` built its tarball URL as `v${version}` → `.../tags/vv1.17.0.tar.gz` → 404. Any lockfile written by `--version` was uninstallable, which is the entire team-distribution path in the README. Versions are now normalised to bare semver on read (`lock_bare_version`), so both `v1.2.0` and `1.2.0` lockfiles resolve
  - `--update` compared the lockfile's `v1.17.0` against `fetch_latest_release_version`'s `1.17.0` with plain `==`, so the `Already at v… — nothing to update` branch was unreachable: every `--update` re-downloaded the tarball, reinstalled everything, and announced `Update available: vv1.17.0 → v1.17.0`
  - `crew.lock` never recorded the platform, so `--update` (which prefers the lockfile over the manifest) fell back to `all` and widened a `pi`-only install into `.claude/`, `.copilot/`, and `.codex/`. `write_lockfile` now records `platform`, and both `--update` and `--from-lockfile` install for it; lockfiles predating the field fall back to `manifest.json`'s platform, then to `all`
  - Item versions are also read tolerantly: `write_lockfile` emits `{"version": "1.2.3"}` but the update path read `.agents[$n]` as a string (getting the whole object), so every item looked changed. `run_update_from_lockfile` now rewrites entries in the same object form it reads, instead of flattening them to bare strings and breaking the next run
  - `bootstrap.sh` normalises `--version 1.2.0` to the `v`-prefixed tag before building its own tarball URL
  - Covered by four new tests in `tests/install.bats`

## [1.17.0] - 2026-08-11

### Added

- **`crew-afk`** (1.14.0): the verify and acceptance-criteria gates are now mechanical instead of prose — `skills/crew-afk/scripts/receipts.sh` records the gated commit SHA at `.scratch/<feature-slug>/dispatch/<issue-slug>.<verify|ac>.ok`
  - `verify-worktree.sh` writes the `verify` receipt on exit 0 and clears it on failure; `merge-branches.sh` refuses any `crew/<feature>/<issue>` branch whose receipt is missing or stale (commits landed after verification), while non-`crew/` branches stay ungated
  - `close-issue.sh` refuses to close an issue without a receipt for **that issue's own slug**, so a sibling branch's evidence can no longer close it — the failure mode observed in one sprint, which merged a branch whose `VERIFY` result was `fail` and then reported `merged=2` after a single dispatch
  - All four platform variants record the `ac` receipt after `AC: all-met`, covered by a parity test so a variant cannot silently drop it. `CREW_RECEIPTS=off` disables receipt *checking* for tests and out-of-sprint script use
  - Covered by `tests/crew-afk-receipts.bats`

- **`crew-afk`** (1.15.0): worktree/branch teardown is now a mechanical step — `skills/crew-afk/scripts/cleanup-worktrees.sh` replaces the hand-rolled `git worktree remove` / `git branch -D` / `git worktree prune` snippets in all four platform variants
  - Removes each merged branch's worktree **before** its ref (git refuses to delete a ref a worktree still has checked out), then prunes stale worktree metadata
  - Fails safe: a `--retain` branch is never touched, a worktree with uncommitted changes is never removed, and a *swept* branch whose commits are not already in `HEAD` is never deleted (override with `--force`) — while branches passed as `--merged` are exempt from the ancestry test, since cleanup runs after squash and a squashed merge leaves no ancestry to check. Every refusal is reported as `kept`, not as a failure, and the run ends with a machine-readable `CLEANUP: removed=N kept=M failed=K` line
  - **Sweeps** leftovers no variant ever named: `crew/<feature-slug>/*` worktrees stranded by an earlier round or a crashed sprint, plus the runtime-managed `worktree-agent-*` worktrees under `.claude/worktrees/` that Claude's `isolation: worktree` creates. Those accumulated indefinitely because cleanup only ever listed branches the orchestrator remembered
  - Idempotent by construction, so it is safe to re-run at any time — including out of band, to clear a repo that already leaked worktrees: `bash scripts/cleanup-worktrees.sh --feature-slug <slug> --dry-run`
  - Covered by `tests/crew-afk-cleanup-worktrees.bats`

## [1.16.0] - 2026-08-11

### Added

- **`crew-afk`** (1.13.0): CRITICAL/HIGH review findings are now routed back into the same sprint as a second fix phase instead of waiting for a human. Policy lives in `skills/crew-afk/references/findings-promotion.md`; the mechanical half is `scripts/promote-findings.sh` (`guard` / `defer` / `flush` / `list` / `remind`) so all four platform variants behave identically
  - **Phase 1** — after a branch's review is written, its CRITICAL/HIGH findings become a *parked* fix issue with `Status: deferred-findings` (one issue per reviewed branch, one acceptance criterion per finding). Parked issues are invisible to the loop's `ready-for-agent` selection, so they never delay the original queue. Grouping per branch rather than per finding is deliberate: findings from one branch cite one diff, so they cluster in the same files and cannot conflict with each other
  - **Phase 2** — when the loop is about to exit, via *either* the no-issues path or the stall path, `flush` flips parked issues to `ready-for-agent`, resets the stall counter, and re-enters the loop. Fix issues run the identical pipeline: worktree, TDD, `verify-worktree.sh`, AC verification, their own review, merge
  - Termination is structural, not counted: every fix issue carries a `Source:` line and `guard` refuses to promote findings raised against a `Source:`-bearing issue, so there is never a Phase 3. Phase is deliberately *not* mirrored into `sprint-state.json` — the on-disk `Status:` lines are the only record, which is what makes flush idempotent and crash-safe
  - MEDIUM/LOW are never promoted. Because promotion is partial by design, every variant ends the sprint with `promote-findings.sh remind`, which counts the findings **not** covered by a promotion marker and prints either `## Next Step` with a real count and the report paths, or `No open review findings.` — so the user is never nudged toward an empty queue, and a CRITICAL raised against a Phase 2 fix branch (report-only by the depth bound) never ends the sprint in silence
  - Self-tests in `skills/crew-afk/references/test-promote-findings.sh` (not installed — `install.sh` skips `test-*.sh`)

### Changed

- **`crew-address-findings`** (1.3.0): skips findings listed under a report's `## Promoted Findings` section — those `(branch, severity)` pairs were auto-promoted and already fixed in a later round of the same sprint. Findings from the same branch at *other* severities are still triaged normally, and skipped pairs are reported once under **Skipped**

## [1.15.0] - 2026-08-11

### Added

- **`crew-grill`**: Phase 1 now routes every frontier decision before asking it, so the user is only interrupted for choices they'd regret not being consulted on. Each node gets a single counterfactual — *if I decide this myself and the user only finds out at review time, would they be annoyed I didn't ask?* — which sorts it into one of three lanes: **Ask** (full `❓`/`➡️` treatment, and the round waits), **Notify** (one `🔎 Decided on your behalf:` line, no response required), or **Silent** (nothing in-flight). Trivia is *not* reported as it happens: listing it for the user to check merely trades a questioning burden for a reporting burden.
  - *Annoyed* topics are named explicitly and always asked: schema/migrations/data model, wire formats and external contracts, auth/permissions/PII, anything costing money or moving scope, user-visible behaviour, and **conflicting** in-repo precedent (two live patterns means the user picks the winner)
  - A claimed repo precedent must cite `path:line`. An uncited precedent is not a precedent and escalates to Notify or Ask
  - Bias is stated asymmetrically — **escalation is cheap, silence is expensive** — because silently deciding something important is a far worse failure than asking about something trivial. Notify is the release valve, so the Silent criteria never have to be perfect
  - Guards both directions: a round with zero questions that touched an *annoyed* topic is flagged as a routing smell, Notify is capped at ~3 per round (more than that means they were really Silent), and a user override forces a re-check of anything derived from it

### Changed

- **`crew-grill`**: the `~4 questions per round` cap is now explicitly a *budget* to spend on **depth rather than breadth** — sub-questions on the consequential fork and assumption-probing — on the grounds that trivia both consumes slots consequential questions need and trains the user to skim, degrading the answers to the questions that mattered
- **`crew-grill`**: the instruction "The *decisions* are the user's — put each one and wait" contradicted the new routing and was reworded rather than supplemented: "A decision with one dominant answer is not a decision — it is a fact lookup plus a default, and it is yours. Genuine forks are the user's: put each one and wait"
- **`crew-grill`**: the Phase 1 summary and the Phase 2 PRD handoff now carry Silent/Notify decisions tagged `(auto)`. Since these were never put to the user, `PRD.md`'s `## Decisions` section is the only place a reviewer or `crew-code-reviewer` can catch them

## [1.14.1] - 2026-08-08

### Fixed

All of the following were found by running the pi crew-afk pipeline end to end against a fresh
`git init` repo with no remote, no lint command and no typecheck command — the configuration under
which a sprint previously failed at every stage. Regression tests live in
`tests/workflow-integrity.bats`.

- **`feature-branch-setup.sh`**: `git symbolic-ref refs/remotes/origin/HEAD` exits 128 when a repo has no remote or an unset `origin/HEAD`. With `set -euo pipefail` and stderr suppressed, that aborted the script — and therefore `session-init.sh` — with **exit 128 and no output**. Failure is now swallowed explicitly so the `main` default applies. Affected both `crew-afk` and `solve-issue`
- **`crew-coder` (all platforms)**: the worker no longer closes its own issue. `solve-issue` step 7 moved the file to `issues/done/` before the orchestrator ran check verification, acceptance-criteria verification, and code review. A result later demoted to `partial` was then invisible to the next round (which lists only `issues/open/`), so the issue was never re-dispatched and its unmerged branch was silently orphaned. New **Issue Ownership** section in all four agent variants; `solve-issue` step 7 gains an explicit carve-out for orchestrated runs; dispatchers export `CREW_ORCHESTRATED=1`
- **`crew-afk` (all four variants)**: the schema pre-filter demoted any `complete` result whose report contained `not_run`, while `verify-worktree.sh` deliberately treats a missing lint/typecheck as a non-fatal coverage gap. Since `crew-coder` is *required* to report `not_run` for absent commands, every sprint in a repo without both lint and typecheck stalled at zero merges. The pre-filter now demotes on `fail`, or on `not_run` for the **test** category only, matching `verify-worktree.sh`
- **`squash-commits.sh`**: an issue with no `## What to build` section made `grep -v` filter everything out and return 1, killing the script under `pipefail` before the existing `-z "$TITLE"` slug fallback could run. The sprint ended with commits unsquashed and no error message. The fallback is now reachable
- **`session-init.sh` / `crew-afk` (all variants) / `squash-commits.sh`**: the feature slug was derived three incompatible ways (first issue's slug, branch basename minus `-NN-`, branch minus `feature/` and JIRA prefix). Running `/crew-afk` without a path argument created a second `.scratch/<first-issue-slug>/` tree and wrote sprint state, traces and `session-start-sha` there while the issues, PRD and dispatch files stayed in the real feature directory. `session-init.sh` now derives the slug from the issue path and records it as `.feature_slug` in `sprint-state.json`, which is the single source of truth everywhere downstream
- **`crew-coder` / `crew-code-reviewer` (pi)**: both pinned `model: sonnet`, a Claude alias. `dispatch-agent.sh` forwarded it as `pi --model sonnet`, which fuzzy-matched an inaccessible `amazon-bedrock` entry and killed **every** dispatch with `Validation error: The provided model identifier is invalid` and an empty report. Neither definition pins a model now, matching the policy `tests/model-policy.bats` already asserted for the reviewer
- **`crew-afk` (pi, codex)**: the per-branch reviewer dispatch omitted `$MODEL_FLAG`, so review ran on a different model than the sprint was asked to use — and, before the fix above, failed outright
- **`close-issue.sh`**: now idempotent. An issue already in `done/` is normalised and reported as `already closed` (exit 0) instead of aborting the orchestrator mid-pipeline
- **`crew-code-reviewer`**: only emits `## Session Review Summary` for multi-branch invocations. Per-branch dispatch (what `crew-afk` does) produced N duplicate "session" summaries, dependency audits and one-row totals tables in the appended report
- **`crew-coder` (all platforms)**: "Never write files outside `$PROJECT_ROOT`" contradicted the same file's requirement to write a trace log under `$MAIN_ROOT`. The rule now names its two exceptions
- **`verify-worktree.sh`**: pluralises `(2 categories not run)`

### Changed

- **`crew-coder` / `crew-code-reviewer` (pi)**: `tools:` no longer lists `grep`, `find` and `ls` — tool names carried over from the Claude definitions that the pi CLI does not provide. pi ignores unknown names silently, so the agents were being told they had capabilities they lacked
- **`dispatch-agent.sh`**: preflights the frontmatter `tools:` list against pi's tool registry and warns on unknown names, so the next cross-platform copy-paste is caught at dispatch time
- **`install.sh`**: warns when a user-level copy of `crew-afk`, `crew-coder`, `crew-code-reviewer` or `solve-issue` exists that may shadow the project install (pi resolves the user-level definition first, which makes a project install look like a no-op)

## [1.14.0] - 2026-08-07

### Added

- **New platform: `codex`** — `./install.sh codex` (and `bootstrap.sh codex`) installs skills to `.agents/skills/` (the repo/user location Codex actually scans) and agents to `.codex/agents/<name>.toml` (Codex's custom-agent format)
- **`crew-coder` / `crew-code-reviewer`**: `codex.agent.toml` definitions with `name`, `description`, `developer_instructions`, `model_reasoning_effort`, and `sandbox_mode` (`workspace-write` for the coder, `read-only` for the reviewer)
- **`crew-afk`**: `codex.SKILL.md` variant plus `scripts/dispatch-codex-agent.sh` — each worker runs as its own `codex exec` process pinned to the issue's worktree via `--cd`, with the report captured through `--output-last-message`; Codex's native subagents are deliberately not used for implementation because they share the parent's working root
- **`squash-commits.sh`**: `--platform codex` writes a Codex `Co-authored-by` trailer

### Changed

- **`install.sh`**: installing over existing files no longer prints a unified diff. A changed file is reported as a single `path (updated)` line; unchanged files are silent. This supersedes the diff-before-overwrite behaviour added in 1.0.0

### Fixed

- **`install.sh`**: skills that ship a platform-specific `SKILL.md` variant (`crew-afk` under `pi` and `codex`) no longer report `SKILL.md` as updated on every re-install. The variant is now resolved before the copy loop and written straight to `SKILL.md`, instead of copying the shared fallback and selecting the variant afterwards — which compared the incoming shared file against the previously installed variant and always saw a difference

## [1.13.1] - 2026-07-28

### Fixed

- **`uninstall.sh`**: read the manifest from `.coding-crew/manifest.json` (where `install.sh` writes it) instead of the legacy top-level `.coding-crew.manifest.json`, with a fallback to the legacy path for repos installed by older versions
- **`uninstall.sh`**: `.coding-crew/` is removed only when empty, so a customised `docs/issue-tracker.md` and the tracker templates survive an uninstall
- **`install.sh`**: `--update` now actually falls back to the legacy `.coding-crew.manifest.json` its error message already advertised, and reports the canonical manifest path when neither exists

## [1.13.0] - 2026-07-28

### Added

- **New platform: `pi`** — `./install.sh pi` (and `bootstrap.sh pi`) installs agents to `.pi/agents/` and skills to `.pi/skills/`, or `~/.pi/agent/{agents,skills}/` for a user-level install, which is where pi actually discovers them
- **`crew-coder` / `crew-code-reviewer`**: `pi.agent.md` definitions using pi's built-in tool names (`read`, `bash`, `edit`, `write`, `grep`, `find`, `ls`)
- **`crew-afk`**: `pi.SKILL.md` variant plus `scripts/dispatch-agent.sh` — pi has no native subagent tool, so each worker runs as its own `pi -p` process in the issue's worktree, with the agent definition supplying system prompt, tool allowlist, and model; reports are written to `.scratch/<slug>/dispatch/<slug>.report.md`
- **`verify-worktree.sh`**: check discovery now falls back to `AGENTS.md` when `CLAUDE.md` is absent
- **`install.sh` / `bootstrap.sh`**: `--version latest` resolves the newest published GitHub release before pinning, so `crew.lock` always records a concrete tag (never the moving `latest` alias)

### Fixed

- **`install.sh`**: agents are now deduplicated per platform, so a `platform=all` skill install writes the agent shims for every platform instead of only the first
- **`install.sh`**: SSH git remotes (`git@github.com:owner/repo.git`) are normalised to `https://` before being used for release lookups or written into `crew.lock`

## [1.8.0] - 2026-06-21

### Added

- **`crew-code-reviewer`**: Reads `.scratch/<feature-slug>/design.md` and `PRD.md` before per-branch review; documented architectural constraints (e.g. tracker abstraction rules) now inform finding severity and proposed fixes
- **`crew-address-findings`**: Step 1.5 loads `.scratch/<feature-slug>/design.md` and `PRD.md` before triage; findings whose proposed fix contradicts a documented design decision are classified Dismiss or Debatable
- **`crew-coder`**: Per-agent trace logging to `.scratch/<feature-slug>/traces/<branch>.log` with `[START]`, `[PHASE]`, `[CMD]`, `[READ]`, `[WRITE]`, `[DONE]` events
- **`crew-afk`**: Orchestrator trace logging to `.scratch/<feature-slug>/traces/orchestrator.log` with `[SESSION]`, `[ROUND]`, `[DISPATCH]`, `[RESULT]`, `[MERGE]`, `[EXIT]` events
- **`crew-afk`**: Coverage validation at exit now checks `issues/done/` (sibling of `issues/open/`)
- **`solve-issue`**: Reference test script `references/test-blocked-dep-path.sh`

### Changed

- **`crew-afk`**: Session SHA and sprint reviews now written under `.scratch/<feature-slug>/` (not `.scratch/` root)
- **`crew-afk`**: Step 5 Agent A delegates to `mark-done` operation from `issue-tracker.md` instead of hardcoding `sed` + `mv`
- **`crew-afk`**: `FEATURE_SLUG` derivation in orchestrator trace uses `sed 's|^feature/||'` + JIRA-strip, matching `session-init.sh`
- **`crew-afk`**: Issue Tracker Conventions blocked-issue description references tracker's `done` set abstractly (no hardcoded path)
- **`crew-afk`**: `session-init.sh` creates `issues/open/` instead of `issues/`, archives `traces/` dir as `traces-<timestamp>/`, writes `session-start-sha` under feature dir, removes `commands.log` handling, adds `.gitignore` safety warning
- **`crew-address-findings`**: Auto-detect scans `.scratch/*/reviews/*.md` grouped by feature; auto-selects when single result; moves report to feature-scoped `reviews/done/` on completion
- **`solve-issue`**: Blocked dependency check uses `$(dirname "$ISSUE_PATH")/../done/` for the `issues/open/` layout
- **`crew-brainstorm`**: Explicit do-not-commit guard for `design.md` (`git add -f` named as anti-pattern)
- **`to-prd`**: Explicit do-not-commit guard for `PRD.md` (`git add -f` named as anti-pattern)
- **`docs/agents/issue-tracker.md`** and **`docs/templates/trackers/local.md`**: `list` op greps `issues/open/*.md`; `mark-done` moves `open/` → `done/` as siblings; workspace layout diagram updated; both files kept in sync

### Fixed

- **`crew-coder`**: `commands.log` section removed from both `claude.agent.md` and `copilot.agent.md`

## [1.7.0] - 2026-06-21

### Added

- **to-issues**: Cross-cutting requirements extraction from design.md/PRD.md with automatic mapping to vertical slices
- **to-issues**: Context Documents section in issue template (references to design.md and PRD.md)
- **to-issues**: Cross-cutting Requirements section with checklist format for 10 requirement categories
- **to-issues**: Part of Flow section for multi-issue flow annotations
- **crew-coder**: Context document reading step that automatically reads design.md/PRD.md before implementation
- **solve-issue**: Step 1.5 "Validate Issue Context" to read context documents and validate cross-cutting requirements
- **crew-afk**: Coverage validation step at exit that compares design.md/PRD.md requirements against completed issues

### Changed

- **to-issues**: Enhanced issue template with optional sections (Context Documents, Cross-cutting Requirements, Part of Flow)
- **to-issues**: Extraction logic scans design.md for error handling, logging, security, performance, testing, architecture constraints, data validation, observability, interfaces & contracts, and multi-issue flows
- **to-issues**: Falls back to PRD.md Decisions section when design.md doesn't exist
- **crew-coder**: Structured output now includes both feature acceptance criteria and cross-cutting requirements
- **solve-issue**: Validation now checks both feature criteria and cross-cutting requirements before completion
- **crew-afk**: Summary format includes coverage report section before per-issue details

### Fixed

- **crew-afk**: JIRA prefix stripping in coverage-validation.sh now matches session-init.sh behavior
- **crew-coder**: Context reading instructions now explicitly specify using View/Read tools instead of bash comment placeholders
- **solve-issue**: Context reading instructions now explicitly specify using View/Read tools instead of bash comment placeholders

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.5.0] - 2026-06-20

### ⚠️ BREAKING CHANGES

**`crew-plan` renamed to `crew-grill`**

The skill has been renamed to better reflect its role as the grill/interview phase of the design pipeline. The new `crew-brainstorm` skill now serves as the full end-to-end design orchestrator.

| Old Name    | New Name     |
| ----------- | ------------ |
| `crew-plan` | `crew-grill` |

**Migration:** Uninstall and reinstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

### Added

- **`crew-brainstorm` skill**: Full design pipeline — captures slug, explores context, conducts Q&A, proposes approaches, builds `design.md` section by section, then auto-transitions to `to-prd` and `to-issues`.

### Changed

- **`to-issues`**: Reads `design.md` from the feature workspace when present, feeding it as context for issue generation. Issue template gains an optional `## Interfaces` section. Skill version bumped to `1.2.0`.

---

## [1.4.0] - 2026-06-20

### ⚠️ BREAKING CHANGES

**`address-code-review` renamed to `crew-address-findings`**

The skill has been renamed to clarify its purpose (acts on the `crew-code-reviewer` report, not inline PR comments) and avoid confusion with `address-pr-comments`.

| Old Name              | New Name                |
| --------------------- | ----------------------- |
| `address-code-review` | `crew-address-findings` |

**`grill-me` and `grill-with-docs` removed**

Both skills have been removed and replaced by the new `domain-modeling` skill and an inlined grill loop inside `crew-plan`.

| Removed            | Replacement            |
| ------------------ | ---------------------- |
| `/grill-me`        | `/crew-plan`           |
| `/grill-with-docs` | `/crew-plan with docs` |

> Note: `crew-plan` was itself renamed to `crew-grill` in v1.5.0.

**Tracker install simplified to project-level only**

The `--user` flag and user-level tracker fallback path have been removed from `install.sh` and all skills. All tracker operations now target the project-level path only.

**Migration:** Uninstall and reinstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

### Added

- **`domain-modeling` skill**: Extracted from `grill-with-docs`. Handles CONTEXT.md glossary and ADR updating behavior. Reference format files live under `skills/domain-modeling/references/`.

### Changed

- **`crew-plan`**: Inlines the grill interview loop directly; lite mode runs the grill only; `with docs` mode invokes the new `domain-modeling` skill.
- **`improve-codebase-architecture`**: Updated dep reference from `grill-with-docs` to `domain-modeling`.
- **`crew-afk`, `solve-issue`, `crew-address-findings`, `to-issues`, `to-prd`, `configure-tracker`**: Simplified tracker lookup to project-level only (no user-level fallback).

### Removed

- **`grill-me` skill**: Use `/crew-plan` instead.
- **`grill-with-docs` skill**: Use `/crew-plan with docs` instead.

---

## [1.3.0] - 2026-06-20

### Added

- **`configure-tracker` skill**: Interactive menu to select and install an issue tracker template. Presents available templates from `docs/templates/trackers/`, then writes the chosen template to `docs/agents/issue-tracker.md` in the target repo.

---

## [1.2.0] - 2026-06-17

### ⚠️ BREAKING CHANGES

**`crew-` prefix removed from skills (except `crew-afk` and `crew-plan`)**

Skills have been renamed to drop the `crew-` prefix. `crew-afk` and `crew-plan` are unchanged.

| Old Name                             | New Name                        |
| ------------------------------------ | ------------------------------- |
| `crew-karpathy-guidelines`           | `karpathy-guidelines`           |
| `crew-tdd`                           | `tdd`                           |
| `crew-dep-install`                   | `dep-install`                   |
| `crew-solve-issue`                   | `solve-issue`                   |
| `crew-address-code-review`           | `address-code-review`           |
| `crew-address-pr-comments`           | `address-pr-comments`           |
| `crew-improve-codebase-architecture` | `improve-codebase-architecture` |
| `crew-grill-me`                      | `grill-me`                      |
| `crew-grill-with-docs`               | `grill-with-docs`               |
| `crew-to-issues`                     | `to-issues`                     |
| `crew-to-prd`                        | `to-prd`                        |
| `crew-caveman`                       | `caveman`                       |

**Migration:** Uninstall and reinstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

Install paths change accordingly: `.claude/skills/tdd/`, `.claude/skills/solve-issue/`, etc.

---

## [1.1.0] - 2026-06-16

### Added

- **`--version` flag for bootstrap**: `bash -s -- --version v1.0.0` pins the install to a specific GitHub release tag instead of always pulling `main`
- **Automatic doc updates in `crew-solve-issue`**: New Step 4.5 prompts the agent to update `README.md`, `CLAUDE.md`, or `docs/` when a change affects user-facing behavior, public API, or architecture. Purely internal changes skip the step.

---

## [1.0.0] - 2026-06-16

### ⚠️ BREAKING CHANGES

**Skill and agent names now use `crew-` namespace prefix**

All skills and agents have been renamed to prevent collisions when installed alongside other skill registries:

| Old Name                        | New Name                             |
| ------------------------------- | ------------------------------------ |
| `crew:afk`                      | `crew-afk`                           |
| `crew:plan`                     | `crew-plan`                          |
| `solve-issue`                   | `crew-solve-issue`                   |
| `address-code-review`           | `crew-address-code-review`           |
| `address-pr-comments`           | `crew-address-pr-comments`           |
| `tdd`                           | `crew-tdd`                           |
| `karpathy-guidelines`           | `crew-karpathy-guidelines`           |
| `dep-install`                   | `crew-dep-install`                   |
| `grill-me`                      | `crew-grill-me`                      |
| `grill-with-docs`               | `crew-grill-with-docs`               |
| `to-issues`                     | `crew-to-issues`                     |
| `to-prd`                        | `crew-to-prd`                        |
| `improve-codebase-architecture` | `crew-improve-codebase-architecture` |
| `caveman`                       | `crew-caveman`                       |
| `coder` (agent)                 | `crew-coder`                         |
| `code-reviewer` (agent)         | `crew-code-reviewer`                 |

**Migration:**

If you have existing skills installed, you must uninstall and reinstall:

```bash
# Uninstall old version
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash

# Install new version
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

All skill invocations now use the `crew-` prefix:

- `/crew:afk` → `/crew-afk`
- `/crew:plan` → `/crew-plan`
- `/crew:solve-issue` → `/crew-solve-issue`
- etc.

Install destination directories also use the prefix: `.claude/skills/crew-afk/`, `.claude/skills/crew-tdd/`, etc.
Agent files also use the prefix: `.claude/agents/crew-coder.md`, `.claude/agents/crew-code-reviewer.md`.

### Added

- **Lockfile-based version pinning**: `install.sh --from-lockfile crew.lock` installs specific versions from a lockfile, enabling reproducible team distributions
- **Lockfile update command**: `install.sh --update` with an existing `crew.lock` checks for newer releases, upgrades, and rewrites the lockfile with updated versions
- **Diff-before-overwrite**: When installing over existing files, `install.sh` now prints a unified diff to show exactly what changed before overwriting
- **CI coverage**: Automated tests now run on macOS, Linux, and Windows (Git Bash)

### Changed

- `registry.json`: All skill and agent keys, install paths, and dependency references updated to use `crew-` prefix
- `install.sh`: Identifier validation updated for `crew-` style names
- `README.md`: All examples updated to use new skill and agent names
- `CLAUDE.md`: Documentation updated to reflect new naming convention

