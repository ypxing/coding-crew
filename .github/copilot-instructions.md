# Copilot Instructions — AI Agents

This repo is a **distributable collection** of AI agents and skills. Nothing runs here directly — this is the source; consuming projects install agents via `./install.sh`.

---

## Installation

```bash
# Install everything into current repo
./install.sh

# Install specific agent for specific platform
./install.sh claude crew-coder

# Install a skill (and its agent dependencies)
./install.sh claude --skill crew-afk

# Install into a different repo
TARGET_REPO=/path/to/other/repo ./install.sh

# Update agents/skills that changed since last install
./install.sh --update
```

**Prerequisites**: `git`, `jq`

**Platforms**: `all` (default), `claude`, `copilot`  
**Agents**: `all` (default), `crew-code-reviewer`, `crew-coder`

---

## Architecture

### Key Components

- **`agents/`** — Two agents: `crew-coder` (implements single issues using TDD in isolated worktrees) and `crew-code-reviewer` (reviews merged branches at sprint end)
- **`skills/`** — Reusable skill files (tdd, solve-issue, domain-modeling, crew-plan, etc.)
- **`registry.json`** — Source of truth for install paths, dependencies, skill bundles, and doc templates
- **`install.sh`** — Single installer that reads `registry.json` and copies files into target repos
- **`docs/agents/`** — Default templates (`issue-tracker.md`, `triage-labels.md`) copied to consuming repos

### How Install Works

1. Reads `registry.json` to determine what to install
2. Resolves agent dependencies recursively
3. Copies skills to `.claude/skills/<name>/` or `.copilot/skills/<name>/`
4. Copies doc templates to `docs/agents/` (skips if already exist)
5. Expands platform files (`claude.*.md`, `copilot.agent.md`):
   - Replaces `{{PROTOCOL}}` placeholder with contents of `protocol.md` or `workflow.js`
   - Creates self-contained files with inlined protocols

### Platform Files and Protocol Inlining

Each agent/skill has platform-specific files directly under `agents/<name>/`:

- **`claude.*.md`** — installed to `.claude/agents/` or `.claude/skills/`
- **`copilot.*.md`** — installed to `.copilot/agents/` or `.copilot/skills/`
- **`protocol.md` or `workflow.js`** — inlined at `{{PROTOCOL}}` during install

Example structure:
```
agents/crew-code-reviewer/
├── claude.agent.md      ← contains {{PROTOCOL}}
├── copilot.agent.md     ← contains {{PROTOCOL}}
└── protocol.md          ← inlined into both files during install
```

---

## Registry Schema

`registry.json` defines all agents, skills, and docs. Each entry includes:

### Agent Entry
```jsonc
"<agent-name>": {
  "version": "1.0.0",
  "description": "...",
  "deps": ["<other-agent>"],           // installed recursively
  "deps-copilot": ["..."],             // platform-specific override (optional)
  "skills": ["tdd", "solve-issue"],    // bundled skills
  "docs": ["issue-tracker.md"],        // doc templates (skip if exist)
  "install": {
    "shims": {
      "claude": ".claude/agents/<name>.md",
      "copilot": ".copilot/agents/<name>.agent.md"
    }
  }
}
```

### Skill Entry
```jsonc
"<skill-name>": {
  "version": "1.0.0",
  "description": "...",
  "install": ".claude/skills/<name>",
  "install-copilot": ".copilot/skills/<name>",  // optional
  "agent-deps": ["crew-coder"],                   // pulls in agents
  "deps": ["tdd", "dep-install"],      // other skills
  "docs": ["issue-tracker.md"],                  // doc templates
  "source": "mattpocock/skills"                  // attribution (optional)
}
```

**Important**: Skills with `agent-deps` automatically install those agents when the skill is installed.

---

## Issue Tracker (This Repo)

Issues live in `.scratch/<feature-slug>/issues/<NN>-<slug>.md`

- **Triage state**: `Status:` line near top (see `docs/agents/triage-labels.md`)
- **To close**: Move to `done/` subdirectory after verifying acceptance criteria
- **PRDs**: `.scratch/<feature-slug>/PRD.md`
- **Comments**: Append under `## Comments` heading

---

## Key Conventions

### Adding a New Agent

1. Create `agents/<name>/protocol.md` (or `workflow.js`)
2. Create `agents/<name>/claude.<type>.md` and `agents/<name>/copilot.agent.md` with `{{PROTOCOL}}` placeholder
3. Add agent entry to `registry.json` (use `crew-` prefix for agent names)
4. Test: `TARGET_REPO=/tmp/test ./install.sh claude <name>`

### Adding a New Skill

1. Create `skills/<name>/SKILL.md`
2. Add skill entry to `registry.json` with version, description, install path 
3. If skill depends on agents, add `agent-deps: ["<agent>"]`
4. Test: `./install.sh claude --skill <name>`

### Protocol Precedence

`install.sh` looks for protocol files in this order:
1. `protocol.md`
2. `workflow.js`

Use `protocol.md` for markdown instructions, `workflow.js` for Workflow scripts.

### Dependency Resolution

- Agent `deps` are installed recursively before the agent
- Skill `agent-deps` pull in full agents (and their deps)
- Skill `deps` only pull in other skills
- Use `deps-copilot` to override agent dependencies for Copilot platform

---

## Available Skills

| Skill | Description |
|-------|-------------|
| `crew-afk` | Orchestrator that spawns parallel crew-coder agents, merges branches, runs crew-code-reviewer |
| `karpathy-guidelines` | Coding principles to reduce LLM mistakes |
| `tdd` | Test-driven development with red-green-refactor loop |
| `solve-issue` | Implement one issue end-to-end: read, explore, install, TDD, verify, commit |
| `crew-address-findings` | Triage and fix code review findings using TDD |
| `address-pr-comments` | Fetch PR review comments, implement sensible ones with TDD |
| `improve-codebase-architecture` | Find deepening opportunities for testability and AI-navigability |
| `domain-modeling` | Update CONTEXT.md glossary and create ADRs inline as decisions crystallise |
| `to-issues` | Break plan/PRD into independently-grabbable issues |
| `to-prd` | Synthesize conversation into PRD and publish to tracker |
| `crew-plan` | Full design pipeline: grill → PRD → issues |
| `caveman` | Ultra-compressed communication mode (~75% token reduction) |
| `dep-install` | Detect install mode (host/docker) and install dependencies once |

---

## Contributing

See [docs/guide.md](docs/guide.md) for:
- Part 1: Contributing to this repo (registry structure, security rules)
- Part 2: Using agents in your project (setup, issue lifecycle, troubleshooting)

---

## Security Rules

When modifying `install.sh` or registry handling:

- Never execute arbitrary code from registry entries
- Always validate paths before writing files
- Use `set -euo pipefail` in all shell scripts
- Sanitize user input from command-line arguments
- Don't follow symlinks during installation
