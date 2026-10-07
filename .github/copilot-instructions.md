# Copilot Instructions — Coding Crew

This repo is a **distributable collection** of AI skills, plus crew-afk's orchestrator and its roles. Nothing runs here directly — this is the source; consuming projects install skills via `./install.sh`.

---

## Installation

```bash
# Install everything into current repo
./install.sh

# Install everything for one platform
./install.sh claude

# Install a skill (and the skills it depends on)
./install.sh claude --skill crew-afk

# Install several skills
./install.sh claude --skills tdd,to-issues

# Install into a different repo
TARGET_REPO=/path/to/other/repo ./install.sh

# Update skills that changed since last install
./install.sh --update
```

**Prerequisites**: `git`, `jq`

**Platforms**: `all` (default), `claude`, `copilot`, `pi`, `codex`

There are no installable agents: crew-coder, crew-reviewer and crew-triage are crew-afk's roles. The old `./install.sh <platform> crew-coder` form prints a note and installs crew-afk; `uninstall.sh --agent` is refused (use `--skill crew-afk`).

---

## Architecture

### Key Components

- **`orchestrator/`** — crew-afk's program; `orchestrator/roles/` holds its three roles' protocols: `coder.md` (implements one issue using TDD in an isolated worktree), `reviewer.md` (+ `reviewer/{references,scripts}`; reviews each branch before merge, then the whole feature) and `triage.md` (classifies verify failures, findings and integration failures)
- **`skills/`** — Reusable skill files (tdd, solve-issue, domain-modeling, crew-grill, etc.); `skills/_shared/fragments/` holds shared fragments
- **`registry.json`** — Source of truth for install paths, dependencies, skill bundles, and the shared trees and scripts under `.coding-crew/`
- **`install.sh`** — Single installer that reads `registry.json` and copies files into target repos
- **`tracker/`** — The tracker CLI and backends, with their docs in `tracker/docs/{local,github}.md`, installed to `.coding-crew/tracker/`; the tracker choice is `.coding-crew/config.json`'s `tracker` section
- **`docs/templates/`** — Optional workflows

### How Install Works

1. Reads `registry.json` to determine what to install
2. Resolves skill `deps` recursively
3. Renders each skill to its platform dir (e.g. `.claude/skills/<name>/`, `.agents/skills/<name>/` for Codex), expanding `{{FRAGMENT:<key>}}` / `{{PLATFORM}}`
4. Copies each skill's `assets` (crew-afk: `orchestrator/` → `.coding-crew/crew-afk/`, roles included; plus `skills/_shared/fragments/` → `.coding-crew/skills/_shared/fragments/`)
5. Copies doc templates (skips if already exist) and tracker scripts (always overwritten)
6. On a crew-afk install, removes agent files older installs wrote (`retired-agents` in `registry.json`) and `.coding-crew/agents/`, `.coding-crew/code-review/`

### Roles, Not Agent Files

No per-platform agent file (`.claude/agents/`, `.github/agents/`, `.pi/agents/`, `.codex/agents/`) is ever written. The orchestrator renders a role's protocol per dispatch (`orchestrator/lib/adapters/render.mjs`) and hands it to the platform CLI through its adapter (`orchestrator/lib/adapters/<platform>.mjs`).

---

## Registry Schema

`registry.json` defines all skills and docs, plus `retired-agents` (old agent files to remove). Each skill entry includes:

### Skill Entry
```jsonc
"<skill-name>": {
  "version": "1.0.0",
  "description": "...",
  // installs to <projectSkills|userSkills>/<name> from orchestrator/platforms.json
  "deps": ["tdd", "dep-install"],      // other skills, installed recursively
  "assets": { "source": "...", "dest": ".coding-crew/<name>" },  // runtime files (optional)
  "source": "mattpocock/skills"                  // attribution (optional)
}
```

---

## Issue Tracker (This Repo)

Issues live in `.scratch/<feature-slug>/issues/<NN>-<slug>.md`

- **Triage state**: `Status:` line near top (see `tracker/docs/local.md`)
- **To close**: Move to `done/` subdirectory after verifying acceptance criteria
- **PRDs**: `.scratch/<feature-slug>/PRD.md`
- **Comments**: Append under `## Comments` heading

---

## Key Conventions

### Changing a crew-afk Role

1. Edit `orchestrator/roles/<role>.md`; put text shared with a skill in a `{{FRAGMENT:<key>}}` line backed by `skills/_shared/fragments/<key>.md`, and per-platform text behind `{{PLATFORM}}`
2. Bump crew-afk's `version` in `registry.json` (roles ship as its `assets`)
3. Test: `TARGET_REPO=/tmp/test ./install.sh claude --skill crew-afk`, then inspect `.coding-crew/crew-afk/roles/`

### Adding a New Skill

1. Create `skills/<name>/SKILL.md`
2. Add skill entry to `registry.json` with version, description, install path 
3. If the skill needs other skills, list them in `deps`
4. Test: `./install.sh claude --skill <name>`

### Dependency Resolution

- Skill `deps` are installed recursively with the skill
- crew-afk's roles come with crew-afk itself (its `assets`), not as dependencies

---

## Available Skills

| Skill | Description |
|-------|-------------|
| `crew-afk` | Orchestrator that dispatches each issue to a coder-role CLI process in its own worktree, reviews and merges every branch |
| `tdd` | Test-driven development with red-green-refactor loop |
| `solve-issue` | Implement one issue end-to-end: read, explore, install, TDD, verify, commit |
| `crew-address-findings` | Triage and fix code review findings using TDD |
| `address-pr-comments` | Fetch PR review comments, implement sensible ones with TDD |
| `domain-modeling` | Update CONTEXT.md glossary and create ADRs inline as decisions crystallise |
| `to-issues` | Break plan/PRD into independently-grabbable issues |
| `to-prd` | Synthesize conversation into PRD and publish to tracker |
| `crew-grill` | Full design pipeline: grill → PRD → issues. Add "with docs" to also update CONTEXT.md and ADRs |
| `dep-install` | Detect install mode (host/docker) and install dependencies once |

---

## Contributing

See [docs/guide.md](docs/guide.md) for:
- Part 1: Contributing to this repo (registry structure, security rules)
- Part 2: Using the skills in your project (setup, issue lifecycle, troubleshooting)

---

## Security Rules

When modifying `install.sh` or registry handling:

- Never execute arbitrary code from registry entries
- Always validate paths before writing files
- Use `set -euo pipefail` in all shell scripts
- Sanitize user input from command-line arguments
- Don't follow symlinks during installation
