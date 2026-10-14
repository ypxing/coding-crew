# Copilot Instructions — Coding Crew

This repo is a **distributable collection** of AI skills. Nothing runs here directly — this is the source; consuming projects install skills via `./install.sh`.

---

## Installation

```bash
# Install everything at user level ($HOME)
./install.sh

# Install everything for one platform
./install.sh claude

# Install a skill (and the skills it depends on)
./install.sh claude --skill solve-feature

# Install several skills
./install.sh claude --skills tdd,to-issues

# Install into the current repo, or another one
./install.sh claude --project
./install.sh claude --project /path/to/other/repo

# Reinstall everything the manifest lists (add --project for a project install)
./install.sh --update
```

**Prerequisites**: `git`, `jq`

**Platforms**: `all` (default), `claude`, `copilot`, `pi`, `codex`

There are no installable agents: `./install.sh <platform> <name>` with anything but `--skill`/`--skills` is refused, and so is `uninstall.sh --agent`.

---

## Architecture

### Key Components

- **`skills/`** — Reusable skill files (tdd, solve-issue, domain-modeling, crew-grill, etc.); `skills/_shared/fragments/` holds shared fragments
- **`registry.json`** — Source of truth for the skills, their dependencies and the libraries each uses (`libs`)
- **`install.sh`** — Single installer that reads `registry.json` and copies files into target repos
- **`platforms.json`** — Every platform's skill dirs and config-dir override, read by `install.sh` and `uninstall.sh`
- **`lib/`** — Libraries the skills share: `tracker/` (the tracker CLI, backends and `docs/{local,github}.md`), `checks/` (run-checks.sh and dep-install's scripts), `git-workflow/`; each installed once to `.coding-crew/lib/<name>/` and linked as `<skill-dir>/scripts/<name>`. The tracker choice is `.coding-crew/config.json`'s `tracker` section
- **`docs/templates/`** — Optional workflows

### How Install Works

1. Reads `registry.json` to determine what to install
2. Resolves skill `deps` recursively
3. Renders each skill to its platform dir (e.g. `.claude/skills/<name>/`, `.agents/skills/<name>/` for Codex), expanding `{{FRAGMENT:<key>}}`
4. Links `<skill-dir>/scripts/<lib>` for each library in the skill's `libs` (relative at project level), and writes each library once to `.coding-crew/lib/<lib>/` (always overwritten)
5. Writes `.coding-crew/manifest.json`: the platform, skills and libraries, no versions

No per-platform agent file (`.claude/agents/`, `.github/agents/`, `.pi/agents/`, `.codex/agents/`) is ever written.

---

## Registry Schema

`registry.json` defines all skills. Each skill entry includes:

### Skill Entry
```jsonc
"<skill-name>": {
  "description": "...",
  // installs to <projectSkills|userSkills>/<name> from platforms.json
  "deps": ["tdd", "dep-install"],      // other skills, installed recursively
  "libs": ["tracker", "checks"],       // lib/<name>, linked as <skill-dir>/scripts/<name> (optional)
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

### Adding a New Skill

1. Create `skills/<name>/SKILL.md`
2. Add skill entry to `registry.json` with its description, and `libs` for any library it runs
3. If the skill needs other skills, list them in `deps`
4. Test: `./install.sh claude --skill <name>`

### Dependency Resolution

- Skill `deps` are installed recursively with the skill

---

## Available Skills

| Skill | Description |
|-------|-------------|
| `solve-feature` | Run one feature's issues on one branch, each by a fresh coder subagent gated by the checks, then review, fix and describe its PR |
| `crew-review` | Review a branch or PR against a spec in a fresh read-only subagent; write one JSON report |
| `tdd` | Test-driven development with red-green-refactor loop |
| `solve-issue` | Implement one issue end-to-end: read, explore, install, TDD, verify, commit |
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
- Don't follow symlinks during installation (a library link is written, never read through)
