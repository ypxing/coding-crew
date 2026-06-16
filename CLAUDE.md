# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working in this repository.

## What this repo is

A distributable collection of AI agents and skills that other projects install via `install.sh`. Nothing runs here directly — this repo is the source; consuming projects are the target.

## Install

```bash
# Install everything into the current repo
./install.sh

# Install a specific agent for a specific platform
./install.sh claude coder

# Install a skill (and its agent deps)
./install.sh claude --skill crew:afk

# Install into a different repo
TARGET_REPO=/path/to/other/repo ./install.sh

# Install a standalone skill
./install.sh claude --skill crew:to-issues

```

Platforms: `all` (default), `claude`, `copilot`. Agents: `all` (default), `code-reviewer`, `coder`.

## Architecture

### Agents

Two agents live under `agents/`:

- **`coder`** — implements a single local markdown issue using TDD, verifies checks, commits, and returns a structured summary. Runs in an isolated git worktree.
- **`code-reviewer`** — reviews all branches merged in a sprint session; reports CRITICAL/HIGH/MEDIUM/LOW findings per branch. Findings are advisory. Invoked once at the end of every sprint by crew:afk.

`crew:afk` is a **skill** (see Skills below) that declares `agent-deps` on `coder` and `code-reviewer` — installing the skill also installs both agents.

### Platform files and protocol inlining

Each agent has platform files directly under `agents/<agent>/`:

- `claude.*` — installed to `.claude/agents/` (agents) or `.claude/skills/` (skills) in the target repo
- `copilot.*` — installed to `.copilot/agents/` in the target repo

Platform files may contain a `{{PROTOCOL}}` placeholder. During `install.sh`, this is replaced inline with the contents of `agents/<agent>/protocol.md` or `agents/<agent>/workflow.js` (whichever exists; `protocol.md` is tried first). The installed file is self-contained. Agents that are single-platform (like `coder`) can put everything in one file with no protocol source.

### Registry

`registry.json` is the source of truth for:

- Install destination paths (per agent, per platform)
- Dependency graph (`deps` field — see each agent entry for its full dependency list)
- Which skills to bundle with each agent
- Which doc templates to copy

### Skills

`skills/` contains reusable skill files (`SKILL.md`). See `registry.json` under `skills` for the full list. Currently:

- `crew:afk` — orchestrator that spawns parallel `coder` agents, merges completed branches, runs code-reviewer, and loops until all ready-for-agent issues are done. Declares `agent-deps: [coder, code-reviewer]` — installing the skill pulls in both agents automatically.
- `crew:karpathy-guidelines` — coding principles (think first, surgical changes, goal-driven)
- `crew:tdd` — red/green/refactor workflow
- `crew:solve-issue` — implement a single issue end-to-end: read, explore, install, TDD, verify, commit
- `crew:address-code-review` — triage and fix findings from an afk-run code review report using TDD
- `crew:address-pr-comments` — fetch PR review comments, challenge critically, implement sensible ones with TDD
- `crew:improve-codebase-architecture` — find deepening opportunities for testability and AI-navigability
- `crew:grill-me` — interview the user relentlessly about a plan until reaching shared understanding
- `crew:grill-with-docs` — grilling session that challenges a plan against the domain model
- `crew:to-issues` — break a plan or PRD into independently-grabbable issues
- `crew:to-prd` — synthesize conversation context into a PRD and publish to the issue tracker
- `crew:plan` — full design pipeline: grill → PRD → issues in one automated flow
- `crew:caveman` — ultra-compressed communication mode (~75% token reduction)

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

`docs/agents/` contains default template files that install copies to `docs/agents/` in the target repo. Consumers edit these to match their tracker and label conventions.

- `issue-tracker.md` — how to list, fetch, and close issues in the local markdown tracker
- `triage-labels.md` — maps canonical triage roles to this repo's label strings

## Issue tracker (this repo)

Issues live in `.scratch/<feature-slug>/issues/<NN>-<slug>.md`. Triage state is a `Status:` line near the top. Move to `done/` subdirectory to close. See `docs/agents/triage-labels.md` for valid status strings.

## Adding a new agent

1. Create `agents/<name>/protocol.md` (markdown instructions) or `agents/<name>/workflow.js` (a Workflow script) — whichever applies. `install.sh` tries `protocol.md` first, then `workflow.js`.
2. Create `agents/<name>/claude.<type>.md` and `agents/<name>/copilot.agent.md` directly under the agent directory (no `shims/` subdirectory). Use `{{PROTOCOL}}` where the protocol should be inlined.
3. Add the agent entry to `registry.json` (install paths, deps, skills, docs).
4. Test: `TARGET_REPO=/tmp/test-repo ./install.sh claude <name>` and inspect the output.
