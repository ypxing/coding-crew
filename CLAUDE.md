# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## What this repo is

A distributable collection of AI agents and skills that other projects install via `install.sh`. Nothing runs here directly — this repo is the source; consuming projects are the target.

## Install

```bash
# Install everything into the current repo
./install.sh

# Install a specific agent for a specific platform
./install.sh claude crew-coder

# Install everything for pi only
./install.sh pi

# Install everything for Codex only
./install.sh codex

# Install a skill (and its agent deps)
./install.sh claude --skill crew-afk

# Install into a different repo
TARGET_REPO=/path/to/other/repo ./install.sh

# Install a standalone skill
./install.sh claude --skill to-issues

```

Platforms: `all` (default), `claude`, `copilot`, `pi`, `codex`. Agents: `all` (default), `crew-code-reviewer`, `crew-coder`.

## Architecture

### Agents

Two agents live under `agents/`:

- **`crew-coder`** — implements a single local markdown issue using TDD, verifies checks, commits, and returns a structured summary. Runs in an isolated git worktree on Claude (runtime-managed via `isolation: worktree`), Copilot, and pi (orchestrator-managed via `git worktree add`). Before implementing, reads `PRD.md` from `.scratch/<feature-slug>/` if it exists, keeping architecture decisions and requirements context in memory. On Claude, inherits all tools from the spawning session (`disallowedTools: [Agent]` only) — so it gets `Grep`, `WebFetch`, `WebSearch`, and any MCP servers the consumer configured. `Agent` is withheld to prevent recursive spawning and unpredictable rate-limit stalls in unattended runs.
- **`crew-code-reviewer`** — reviews branches before they merge in a crew-afk sprint; reports CRITICAL/HIGH/MEDIUM/LOW findings per branch with snippet-anchored citations at every severity. Findings are advisory and never block a merge. Invoked per-branch in Step 4 of crew-afk, before the merge and before squash.

  **Conditional checklists (agent assets).** `protocol.md` carries only what applies everywhere — the always-on CRITICAL security classes, the AI-code correctness priorities, the Pre-Report Gate, the snippet requirement, Common False Positives, Zero-Findings, and the output format. The framework checklists live in `agents/crew-code-reviewer/assets/references/` (`quality.md`, `web-security.md`, `react.md`, `backend.md`) and which ones apply is decided by `assets/scripts/review-context.sh` from signal files (`package.json` deps, `go.mod`, `requirements.txt`, `Gemfile`, `.tsx`/`.html` files), which prints `STACK:` and one `REFERENCE:` line per file to read. `quality.md` is language-agnostic and always selected; React and backend blocks are not loaded in a repo that is neither. The six-row dependency-audit table the model used to execute by hand is now `assets/scripts/dependency-audit.sh` (verbatim tool output, `NOT RUN: <tool> not found`, always exit 0 — a missing audit tool is not a failed review). Nothing was deleted: `tests/crew-code-reviewer-references.bats` asserts that every pre-trim checklist item still exists in the protocol-plus-references union, and negative greps keep the framework blocks from creeping back inline.

  Assets install **once**, to a platform-neutral path (`.coding-crew/code-review/`) declared as `install.assets` in `registry.json`, so four platforms do not get four copies of the same references; like `.coding-crew/scripts/` they are always overwritten and removed on uninstall, because a stale reference would be a checklist that no longer matches the protocol pointing at it. The reviewer always runs from the main checkout, so `$ROOT/.coding-crew/code-review/` resolves for every platform. When the scripts are absent (an older install) the protocol falls back to reading every file in `references/`, and with neither it reviews on the always-on classes alone.

`crew-afk` is a **skill** (see Skills below) that declares `agent-deps` on `crew-coder` and `crew-code-reviewer` — installing the skill also installs both agents.

### Platform files and protocol inlining

Each agent has platform files directly under `agents/<agent>/`:

- `claude.*` — installed to `.claude/agents/` (agents) or `.claude/skills/` (skills) in the target repo
- `copilot.*` — installed to `.github/agents/` in the target repo (`~/.copilot/agents/` for a user-level install, since Copilot scans `.github/agents/` in a repo and `~/.copilot/agents/` in `$HOME` — never `.copilot/agents/` inside a project)
- `pi.*` — installed to `.pi/agents/` in the target repo (`~/.pi/agent/agents/` for a user-level install, since that is where pi looks)
- `codex.agent.toml` — installed to `.codex/agents/<name>.toml` (Codex's custom-agent TOML format: `name`, `description`, `developer_instructions`, plus optional `model`, `model_reasoning_effort`, `sandbox_mode`). Put `{{PROTOCOL}}` inside the `'''` literal block so markdown needs no escaping.

Platform files may contain a `{{PROTOCOL}}` placeholder. During `install.sh`, this is replaced inline with the contents of `agents/<agent>/protocol.md` or `agents/<agent>/workflow.js` (whichever exists; `protocol.md` is tried first). The installed file is self-contained. Agents that are single-platform (like `crew-coder`) can put everything in one file with no protocol source.

An agent may also declare `install.assets` (`{ "source": "<dir under the agent dir>", "dest": "<repo-relative dir>" }`). That tree is copied once per install — not per platform — with `*.sh` made executable, always overwritten, and removed by `uninstall.sh --agent <name>`. Use it for runtime files the agent reads or executes itself (conditional references, helper scripts), not for prompt text: prompt text belongs inline via `{{PROTOCOL}}`.

### Platforms

`install.sh` supports four platforms, listed in the `PLATFORMS` array in `install.sh` (and mirrored in `uninstall.sh`):

| Platform  | Project paths                          | User-level paths (`TARGET_REPO=$HOME`)   |
| --------- | -------------------------------------- | ---------------------------------------- |
| `claude`  | `.claude/agents/`, `.claude/skills/`   | same                                     |
| `copilot` | `.github/agents/`, `.github/skills/`   | `.copilot/agents/`, `.copilot/skills/`   |
| `pi`      | `.pi/agents/`, `.pi/skills/`           | `.pi/agent/agents/`, `.pi/agent/skills/` |
| `codex`   | `.codex/agents/`, `.agents/skills/`    | same                                     |

`adjust_platform_path()` in `install.sh`/`uninstall.sh` owns the two platforms whose project and user paths differ. pi is written project-style in `registry.json` and rewritten for `$HOME`; **copilot is the mirror image** — written user-style (`.copilot/...`) and rewritten to `.github/...` for a project checkout. Copilot never reads `.copilot/` inside a repo, so a path written there is installed and dead: verified against Copilot CLI 1.0.77, a skill under `.copilot/skills/` is absent from `copilot skill list`, and an agent under `.copilot/agents/` answers `Unknown agent_type` when dispatched. `install.sh` deletes a legacy `.copilot/` project copy when it writes the `.github/` one, and `uninstall.sh` sweeps both. Guarded by `tests/copilot-platform.bats`.

Skill destinations resolve as: `install-<platform>` in `registry.json` if present, otherwise the `install` (Claude) path with `.claude/` swapped for `.<platform>/` — except `codex`, which swaps to `.agents/` because Codex scans `.agents/skills` (repo) and `~/.agents/skills` (user), never `.codex/skills`. See `default_skill_dest()` in `install.sh`/`uninstall.sh`. Other platform-specific files (e.g. `scripts/dispatch-agent.sh` for pi, `scripts/dispatch-codex-agent.sh` for codex) are gated with a `platform-files` map in `registry.json`: a path listed under a platform is copied only for that platform, and copies left behind by earlier installs are pruned on re-install.

#### Skill bodies (one body, many platforms)

The installed file is always `SKILL.md`. Which source becomes it is resolved, in order:

1. `body.<platform>` in `registry.json` — a **shared body** used by several platforms;
2. `skills/<skill>/<platform>.SKILL.md` — a single-platform variant;
3. `skills/<skill>/SKILL.md` — the shared fallback.

Every unselected `*.SKILL.md` is deleted from the destination after copy. `crew-afk` uses the first form: `pi`, `codex` and `copilot` all resolve to `skills/crew-afk/dispatch.SKILL.md`, and their differences live in `skills/crew-afk/fragments/<platform>/<key>.md`. `scripts/render-skill.sh <skill> <platform>` renders a body by inlining `{{FRAGMENT:<key>}}` from that platform's fragment dir and substituting `{{PLATFORM}}`; `install.sh` runs it for every `SKILL.md` it installs. A missing fragment or a surviving `{{...}}` is a hard error — a body with a hole in it would ship an instruction gap to the model. `fragments/` is a build input and is never installed (and a `fragments/` tree left by an older install is pruned).

Why: the three dispatch platforms were three ~5,000-word files that were 85–90% identical, and they drifted. Three of the four declared `review → close → merge` and closed the issue *before* merging, so a merge conflict moved the issue to `done/` with the work unmerged. Parity by review does not hold at that size; parity is now structural. Prose assertions in `tests/` therefore run against the **rendered** body via `tests/helpers/render.bash` (`afk_variant <platform>`), not against a source variant, and `tests/shared-dispatch-body.bats` guards the mechanism (fragment completeness, no unused fragments, identical section structure and pipeline order across platforms, install renders and ships no build inputs). The Claude variant stays its own file: it uses the native `Agent` tool and batches of 3, so it is genuinely different, not a copy.

To read what a platform actually receives:

```bash
bash scripts/render-skill.sh crew-afk codex | less
```

**pi specifics:** pi has no native subagent tool, so `crew-afk` on pi dispatches each worker as a separate `pi -p` process through `skills/crew-afk/scripts/dispatch-agent.sh`. That script resolves the agent definition (`.pi/agents/<name>.md`, then `~/.pi/agent/agents/<name>.md`), strips its frontmatter into `--append-system-prompt`, maps `tools:` onto `--tools`, applies `model:`/`--model`, and runs the worker with the issue's worktree as cwd. Workers write their structured report to `.scratch/<slug>/dispatch/<slug>.report.md`, which the orchestrator reads after `wait`.

**copilot specifics:** Copilot dispatches in-session, not as a subprocess: the fragments in `skills/crew-afk/fragments/copilot/` tell the orchestrator to call the **`task` tool** — `task(agent_type="crew-coder", prompt="…")` — which is the Copilot CLI's only subagent mechanism (`list_agents`, `read_agent`, `task`, `write_agent` are the delegation tools; `task` accepts a custom agent name since CLI v1.0.19). `#runSubagent` is **VS Code Copilot Chat** syntax and does not exist in the CLI — a body that instructs it makes every dispatch fail, and the observed failure mode is the orchestrator then implementing the issue itself. Because subagents share the parent's working root, per-issue isolation is carried by the `Working directory:` line in the prompt, and concurrency is capped by the user's Copilot plan (Free 2 … Enterprise 32), so the body dispatches in batches up to the cap. `crew-afk`'s SKILL.md pre-approves `allowed-tools: shell, task` so an unattended sprint cannot stall on a tool-permission prompt. The two agents' `tools:` lists use the CLI's own tool names — `bash`, `view`, `create`, `edit`, `grep`, `glob` (the reviewer gets only the read-only four) — not the generic `read`/`execute`/`search` names they were first written with. Unknown names are silently dropped rather than rejected, so the old list looked like it worked (`edit` and the shell survived by coincidence of naming) while leaving the worker with no `grep`/`glob` at all, forced to shell out for every search. `task` is deliberately withheld from both, mirroring Claude's `disallowedTools: [Agent]`: a worker that can dispatch workers recurses and stalls on rate limits in an unattended sprint. `--model` stays accepted-and-ignored, but for the right reason: the model is session-selected (`copilot --model`, `/model`) and inherited by subagents, with per-agent overrides living in `~/.copilot/settings.json` → `subagents.agents.<name>.model`.

**codex specifics:** Codex has native subagents, but they share the parent's working root, so `crew-afk` on codex dispatches each worker as a separate `codex exec` process through `skills/crew-afk/scripts/dispatch-codex-agent.sh`. That script resolves `.codex/agents/<name>.toml` (then `~/.codex/agents/<name>.toml`), prepends `developer_instructions` to the prompt (codex exec has no `--append-system-prompt`), maps `model`/`model_reasoning_effort`/`sandbox_mode` onto CLI flags, runs `codex exec --cd <worktree> --add-dir $MAIN_ROOT`, and captures the report via `--output-last-message`. Reports land in the same `.scratch/<slug>/dispatch/<slug>.report.md` path. This path targets the **local `codex` CLI only** — it needs a shell that can background child processes, a local clone for worktrees, and pre-existing auth. Hosted Codex (Codex in ChatGPT, Codex cloud/web) is out of scope: no parent process to `wait` on and no persistent working root.

### Registry

`registry.json` is the source of truth for:

- Install destination paths (per agent, per platform), plus `install.assets` for an agent's platform-neutral runtime files
- Which source body each platform's `SKILL.md` is rendered from (`body` map)
- Dependency graph (`deps` field — see each agent entry for its full dependency list)
- Which skills to bundle with each agent
- Which doc templates to copy

### Skills

`skills/` contains reusable skill files (`SKILL.md`). See `registry.json` under `skills` for the full list. Currently:

- `crew-afk` — orchestrator that spawns parallel `crew-coder` agents, merges completed branches, runs crew-code-reviewer, and loops until all ready-for-agent issues are done. Declares `agent-deps: [crew-coder, crew-code-reviewer]` — installing the skill pulls in both agents automatically. Skill-local scripts in `skills/crew-afk/scripts/`: `merge-branches.sh` (per-branch no-ff merge with conflict abort), `close-issue.sh` (Status rewrite + file move), `squash-commits.sh`, `session-init.sh` (also writes `sprint.env` — see below), `coverage-validation.sh`, `promote-findings.sh` (findings promotion — see below), `receipts.sh` (gate receipts — see below), `cleanup-worktrees.sh` (mechanical worktree/branch teardown — see below), `trace.sh` / `state.sh` / `crew-summary.sh` (sprint mechanism — see below), `verify-worktree.sh` (independently runs the project's typecheck, lint, and test checks in a worker's worktree before merge — merges are only permitted after this passes). Any check that fails exits non-zero. An undiscoverable check command is reported as `not_run` and listed as a coverage gap in the summary, never as passing; a missing test command is fatal (nothing was verified), while missing lint/typecheck are non-fatal so repos that legitimately have neither don't stall every sprint.. Pipeline order per branch: worker returns → schema pre-filter → verify-worktree → acceptance-criteria verification → per-branch code review → merge → close, then squash once per sprint. Acceptance criteria are verified **before** the merge, by the orchestrator (not by a crew-coder subagent); a branch whose criteria are unmet is demoted to `partial` and never merged. Cleanup deletes only merged branches, removing each merged worktree before its branch ref (a checked-out ref cannot be deleted); partial, verification-failed, and criteria-unmet branches are retained with their branch name recorded under `retained_branches` in `sprint-state.json` so the next round resumes in place.

  **Worktree teardown.** Cleanup was prose repeated across four variants, so an orchestrator that ran long simply never reached it, and no variant ever named the runtime-managed worktrees Claude creates for `isolation: worktree` agents — `.claude/worktrees/agent-*` and their `worktree-agent-*` refs piled up across sprints. `scripts/cleanup-worktrees.sh` makes teardown one mechanical, idempotent step: it removes each merged branch's worktree before its ref (a checked-out ref cannot be deleted), sweeps stranded `crew/<feature-slug>/*` and `worktree-agent-*` worktrees nobody passed in, prunes stale metadata, and fails safe — `--retain` branches, dirty worktrees, and *swept* branches with commits not yet in `HEAD` are reported as `kept` rather than deleted (`--force` overrides the last). Ancestry is deliberately **not** required for branches passed as `--merged`: cleanup runs after squash, which rewrites the feature branch, so no genuinely merged tip is an ancestor of `HEAD` by then and an ancestry gate there would retain every merged branch forever. It ends with `CLEANUP: removed=N kept=M failed=K`, and re-running is a clean no-op, so it doubles as the out-of-band way to clear a repo that already leaked worktrees.

  **Sprint mechanism (not prose).** An orchestrator prompt is not a state machine, and the parts of it that were one behaved accordingly: an observed sprint re-derived the feature slug with `jq -r .feature_slug "$(ls -1 .scratch/*/sprint-state.json | head -n1)"` — an alphabetical-first glob — directly beneath a comment reading "Never re-derive it", logged `[DISPATCH]` twice because both the prompt and `dispatch-agent.sh` wrote it, and rendered its summary from lists it had been carrying in context since round 1. Four scripts now own that:

  - `session-init.sh` writes **`sprint.env`** (`.scratch/<feature-slug>/sprint.env`, plus a `.scratch/sprint.env` pointer). Every body starts each bash block with `source "$(git rev-parse --show-toplevel)/.scratch/sprint.env"` and gets `MAIN_ROOT`, `FEATURE_SLUG`, `FEATURE_BRANCH`, `SPRINT_DIR`, `STATE_FILE`, `TRACE_LOG`, `DISPATCH_DIR`, `REVIEW_DIR`. The slug is known once, where the issues were found, so nothing downstream re-derives it.
  - `trace.sh` — every script traces its own step (`SESSION`, `DISPATCH`, `VERIFY`, `MERGE`, `CLOSE`, `PROMOTE`, `FLUSH`, `CLEANUP`, `SQUASH`, `MODEL`, `ROUND`, `STATE`, `EXIT`), so a step that ran is always traced and a step that was skipped cannot be traced as if it had. The orchestrator hand-writes only `ACVERIFY` (and `DISPATCH` on Copilot, which has no dispatch script). It resolves the log through `sprint.env` and is a silent no-op when there is no sprint — tracing must never fail the caller.
  - `state.sh` — `complete` / `retain` / `blocked` / `coverage-gap` / `model` / `round` / `resume` / `get`. `retain` is the single entry point for every branch that must survive (`partial`, `verification-failed`, `criteria-unmet`, `merge-failed`, `blocked`); its reason string is what the summary prints and `get retained` is what feeds `cleanup-worktrees.sh --retain`, while `get merged` feeds `--merged`, so the certified lists come from disk instead of recollection. `complete` clears the retention so a stale branch is never resumed, and `resume` answers `resume: <branch>` / `no prior branch` (recorded name + ref check).
  - `crew-summary.sh` — renders the rollup, `## Verification Failures`, `## Coverage Gaps`, `## Retained Branches` and `## Promoted Findings` from `sprint-state.json` and the review reports, writes the `EXIT` trace, and ends with the findings reminder rendered from `promote-findings.sh remind`. A review gap is never suppressed by a clean findings count and never added to it. `--no-reminder` gives the per-round rollup so the reminder prints exactly once, last.

  Both orchestrator bodies are held under 3,000 words by `tests/crew-afk-state.bats`, which also asserts the behaviour the deleted prose used to describe; a budget is the only thing that stops mechanism creeping back in as prose.

  **Gate receipts.** Both pipeline gates used to be prose only, so an orchestrator that skipped them left no trace and nothing downstream objected — one observed sprint merged a branch whose `VERIFY` result was `fail`, and closed a second issue off the first issue's branch to report `merged=2` after a single dispatch. `scripts/receipts.sh` makes both gates mechanical by writing `<main-root>/.scratch/<feature-slug>/dispatch/<issue-slug>.<verify|ac>.ok` containing the gated commit SHA. `verify-worktree.sh` writes the `verify` receipt on exit 0 and clears it on failure; `merge-branches.sh` refuses any `crew/<feature>/<issue>` branch whose receipt is missing or whose SHA no longer matches the branch tip (so commits added after verification cannot ride in on an earlier pass), while non-`crew/` branches stay ungated. Each variant writes the `ac` receipt itself after its acceptance-criteria check returns `AC: all-met`, and `close-issue.sh` refuses to close an issue without a receipt for **that issue's own slug** — derived from the filename the same way branch names are — which is what stops one issue closing on a sibling's evidence. Receipt checking (not writing) can be disabled with `CREW_RECEIPTS=off`, which exists for tests and out-of-sprint script use only.

  **Findings promotion (two-phase sprint).** Review findings are advisory and never block a merge, so CRITICAL/HIGH findings are routed back into the sprint instead of waiting for a human. Policy lives in `skills/crew-afk/references/findings-promotion.md`; the mechanical half is `scripts/promote-findings.sh` (`guard` / `defer` / `flush` / `list` / `remind`) so all four platform variants behave identically. In **Phase 1**, after a branch's review is written, CRITICAL/HIGH findings become a *parked* fix issue with `Status: deferred-findings` — one issue per reviewed branch (findings from one branch cite one diff, so grouping avoids sibling merge conflicts), one acceptance criterion per finding. Parked issues are invisible to the loop's `ready-for-agent` selection, so they never delay Phase 1. When the loop is about to exit — via **either** the no-issues path or the stall path — the flush flips parked issues to `ready-for-agent`, resets the stall counter, and re-enters the loop as **Phase 2**; fix issues run the identical pipeline including their own review. Termination is structural, not counted: each fix issue carries a `Source:` line, `guard` refuses to promote findings raised against a `Source:`-bearing issue, so there is never a Phase 3. Phase is deliberately *not* stored in `sprint-state.json` — the on-disk `Status:` lines are the only record, which makes flush idempotent and crash-safe. MEDIUM/LOW findings are never promoted; they stay in the report for a human, and `defer` appends a `## Promoted Findings` section (`<branch>: <severities> → <issue>`) that `crew-address-findings` uses to skip findings the sprint already fixed. Because promotion is partial by design, every variant ends the sprint with `promote-findings.sh remind`, which counts the findings **not** covered by a promotion marker (attributing each to its `## Branch:` section) and prints either `## Next Step` with a real count, the report paths, and `Run: /crew-address-findings`, or `No open review findings.` — so the user is never nudged toward an empty queue, and a CRITICAL raised against a Phase 2 fix branch (report-only by the depth bound) never ends the sprint in silence.
- `tdd` — red/green/refactor workflow. §1's "confirm with user" / "get user approval" boxes carry an explicit non-interactive branch, because this file is a mandatory read for headless `pi -p` workers that have no user to ask
- `solve-issue` — implement a single issue end-to-end: read, explore, install, TDD, verify, commit. The close is delegated to the tracker's `mark-done` operation (which refuses under an orchestrator), and the unmet-criteria path reports `partial` instead of asking a question when nobody is watching
- `crew-address-findings` — triage and fix findings from an afk-run code review report using TDD; skips findings listed under `## Promoted Findings` (already fixed by crew-afk's Phase 2)
- `address-pr-comments` — fetch PR review comments, challenge critically, implement sensible ones with TDD
- `improve-codebase-architecture` — find deepening opportunities for testability and AI-navigability
- `to-issues` — break a plan or PRD into independently-grabbable issues; extracts cross-cutting requirements from `PRD.md` and adds them as checklists in issues
- `to-prd` — synthesize conversation context into a PRD and publish to the issue tracker
- `crew-brainstorm` — collaborative design pipeline: explore intent, propose 2–3 approaches, build a design doc, then hand off to PRD and issues
- `crew-grill` — adversarial design pipeline: stress-test every assumption, capture decisions, then produce a PRD and issues
- `caveman` — ultra-compressed communication mode (~75% token reduction)
- `configure-tracker` — select and install an issue tracker template

Skills with `agent-deps` also install the listed agents (via `install.sh`) so the skill can invoke them at runtime.

Install copies these to `.claude/skills/<skill>/SKILL.md` in the target repo.

### Scripts Infrastructure

`scripts/skill-utils/git-workflow/` contains reusable bash scripts that are copied into skills during installation. This is **not** a skill itself — it's infrastructure for build-time script copying.

**Scripts:**

- `branch-safety-check.sh` — validates current branch is not default
- `feature-branch-setup.sh` — creates/switches to feature branches with optional JIRA prefix
- `commit-changes.sh` — safely stages specific files and commits with standardized messages

**How it works:**

- Skills declare needed scripts in `registry.json` via the `scripts` field
- During `install.sh`, scripts are copied from `scripts/skill-utils/git-workflow/` into each skill's `scripts/` directory
- Skills reference them locally: `bash scripts/branch-safety-check.sh`
- Each skill gets its own copy — no runtime cross-skill dependencies

See `scripts/skill-utils/git-workflow/README.md` for full documentation.

### Docs

`docs/templates/trackers/` contains tracker template files. `install.sh` copies the selected template to `.coding-crew/docs/issue-tracker.md` in the target repo (skip-if-exists). Consumers can switch trackers by running the `configure-tracker` skill.

- `docs/templates/trackers/local.md` — canonical local-markdown tracker template (source of truth)
- `.coding-crew/docs/issue-tracker.md` — installed copy in the target repo; edit to customise for the project

`registry.json` also has a `docs.scripts` map for tracker *mechanism* — the implementation of an operation the template only describes. Unlike templates, these are always overwritten on install (and removed on uninstall), because a stale copy would be a gate that no longer matches the operation calling it. One entry exists:

- `scripts/tracker/mark-issue-done.sh` → `.coding-crew/scripts/mark-issue-done.sh` — the `mark-done` operation. It refuses to close an issue in two cases, and both used to be prose that nothing enforced. Exit **3** when an orchestrator owns the close (`.scratch/<feature-slug>/.orchestrated` exists, written by crew-afk's `session-init.sh` and removed by `crew-summary.sh` at sprint end — or `CREW_ORCHESTRATED=1` is set by the dispatchers); exit **4** when a `- [ ]` remains under `## Acceptance criteria` or `## Cross-cutting Requirements`. `--force` overrides both, for a marker left by a crashed sprint or a criterion recorded as descoped.

  Why mechanical: a worker that closes its own issue takes it out of the `ready-for-agent` list, so an orchestrator gate that later demotes the result to `partial` has nothing left to re-dispatch and the unmerged branch is silently orphaned. Three crew-coder variants argued against this in prose while `solve-issue` step 7 told the worker to close, and prose cannot fail closed. The orchestrator's own close path (`skills/crew-afk/scripts/close-issue.sh`, receipt-gated) is deliberately unaffected by the marker — it *is* the orchestrator.

## Issue tracker (this repo)

Issues live in `.scratch/<feature-slug>/issues/open/<NN>-<slug>.md`. Triage state is a `Status:` line near the top. Move to `issues/done/` to close. See `.coding-crew/docs/issue-tracker.md` for valid status strings and workspace layout.

## Adding a new agent

1. Create `agents/<name>/protocol.md` (markdown instructions) or `agents/<name>/workflow.js` (a Workflow script) — whichever applies. `install.sh` tries `protocol.md` first, then `workflow.js`.
2. Create `agents/<name>/claude.<type>.md` and `agents/<name>/copilot.agent.md` directly under the agent directory (no `shims/` subdirectory). Use `{{PROTOCOL}}` where the protocol should be inlined.
3. Add the agent entry to `registry.json` (install paths, deps, skills, docs). Add `install.assets` if the agent ships references or scripts it reads at runtime.
4. Test: `TARGET_REPO=/tmp/test-repo ./install.sh claude <name>` and inspect the output.
