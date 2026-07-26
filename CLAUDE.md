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

# Install a skill (and its agent deps)
./install.sh claude --skill crew-afk

# Install into a different repo
TARGET_REPO=/path/to/other/repo ./install.sh

# Install a standalone skill
./install.sh claude --skill to-issues

```

Platforms: `all` (default), `claude`, `copilot`. Agents: `all` (default), `crew-code-reviewer`, `crew-coder`.

## Architecture

### Agents

Two agents live under `agents/`:

- **`crew-coder`** — implements a single local markdown issue using TDD, verifies checks, commits, and returns a structured summary. Runs in an isolated git worktree on both Claude (runtime-managed via `isolation: worktree`) and Copilot (orchestrator-managed via `git worktree add`). Before implementing, reads `PRD.md` from `.scratch/<feature-slug>/` if it exists, keeping architecture decisions and requirements context in memory. On Claude, inherits all tools from the spawning session (`disallowedTools: [Agent]` only) — so it gets `Grep`, `WebFetch`, `WebSearch`, and any MCP servers the consumer configured. `Agent` is withheld to prevent recursive spawning and unpredictable rate-limit stalls in unattended runs.
- **`crew-code-reviewer`** — reviews branches before they merge in a crew-afk sprint; reports CRITICAL/HIGH/MEDIUM/LOW findings per branch with snippet-anchored citations at every severity. Findings are advisory and never block a merge. Invoked per-branch in Step 4 of crew-afk, before the merge and before squash.

`crew-afk` is a **skill** (see Skills below) that declares `agent-deps` on `crew-coder` and `crew-code-reviewer` — installing the skill also installs both agents.

### Platform files and protocol inlining

Each agent has platform files directly under `agents/<agent>/`:

- `claude.*` — installed to `.claude/agents/` (agents) or `.claude/skills/` (skills) in the target repo
- `copilot.*` — installed to `.copilot/agents/` in the target repo

Platform files may contain a `{{PROTOCOL}}` placeholder. During `install.sh`, this is replaced inline with the contents of `agents/<agent>/protocol.md` or `agents/<agent>/workflow.js` (whichever exists; `protocol.md` is tried first). The installed file is self-contained. Agents that are single-platform (like `crew-coder`) can put everything in one file with no protocol source.

### Registry

`registry.json` is the source of truth for:

- Install destination paths (per agent, per platform)
- Dependency graph (`deps` field — see each agent entry for its full dependency list)
- Which skills to bundle with each agent
- Which doc templates to copy

### Skills

`skills/` contains reusable skill files (`SKILL.md`). See `registry.json` under `skills` for the full list. Currently:

- `crew-afk` — orchestrator that spawns parallel `crew-coder` agents, merges completed branches, runs crew-code-reviewer, and loops until all ready-for-agent issues are done. Declares `agent-deps: [crew-coder, crew-code-reviewer]` — installing the skill pulls in both agents automatically. Skill-local scripts in `skills/crew-afk/scripts/`: `merge-branches.sh` (per-branch no-ff merge with conflict abort), `close-issue.sh` (Status rewrite + file move), `squash-commits.sh`, `session-init.sh`, `coverage-validation.sh`, `verify-worktree.sh` (independently runs the project's typecheck, lint, and test checks in a worker's worktree before merge — merges are only permitted after this passes). Any check that fails exits non-zero. An undiscoverable check command is reported as `not_run` and listed as a coverage gap in the summary, never as passing; a missing test command is fatal (nothing was verified), while missing lint/typecheck are non-fatal so repos that legitimately have neither don't stall every sprint.. Pipeline order per branch: worker returns → schema pre-filter → verify-worktree → per-branch code review → merge → squash. Cleanup deletes only merged branches, removing each merged worktree before its branch ref (a checked-out ref cannot be deleted); partial and verification-failed branches are retained with their branch name recorded under `retained_branches` in `sprint-state.json` so the next round resumes in place.
- `tdd` — red/green/refactor workflow
- `solve-issue` — implement a single issue end-to-end: read, explore, install, TDD, verify, commit
- `crew-address-findings` — triage and fix findings from an afk-run code review report using TDD
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

## Issue tracker (this repo)

Issues live in `.scratch/<feature-slug>/issues/open/<NN>-<slug>.md`. Triage state is a `Status:` line near the top. Move to `issues/done/` to close. See `.coding-crew/docs/issue-tracker.md` for valid status strings and workspace layout.

## Adding a new agent

1. Create `agents/<name>/protocol.md` (markdown instructions) or `agents/<name>/workflow.js` (a Workflow script) — whichever applies. `install.sh` tries `protocol.md` first, then `workflow.js`.
2. Create `agents/<name>/claude.<type>.md` and `agents/<name>/copilot.agent.md` directly under the agent directory (no `shims/` subdirectory). Use `{{PROTOCOL}}` where the protocol should be inlined.
3. Add the agent entry to `registry.json` (install paths, deps, skills, docs).
4. Test: `TARGET_REPO=/tmp/test-repo ./install.sh claude <name>` and inspect the output.
