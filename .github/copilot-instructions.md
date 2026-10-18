# Copilot Instructions — Coding Crew

This repo is a **distributable collection** of AI skills. Nothing runs here directly — this is the source; consuming projects install skills via `npx skills add ypxing/coding-crew --all` or `./install.sh`.

---

## Installation

```bash
# Any Agent-Skills agent: from inside the consuming repo (add -g for user level); re-run to update
npx skills add ypxing/coding-crew --all

# From a clone: install everything at user level ($HOME)
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

**Prerequisites**: `bash` ≥ 4, `git`, `jq`

**Platforms**: `all` (default), `claude`, `copilot`, `pi`, `codex` (`codex` is the shared `.agents/skills` location most Agent-Skills agents read)

There are no installable agents: `./install.sh <platform> <name>` with anything but `--skill`/`--skills` is refused, and so is `uninstall.sh --agent`.

---

## Architecture

### Key Components

- **`skills/`** — Reusable skill files (tdd, solve-issue, domain-modeling, crew-grill, etc.); `skills/_shared/fragments/` holds shared fragments
- **`registry.json`** — Source of truth for the skills, their dependencies and the libraries each uses (`libs`)
- **`install.sh`** — Single installer that reads `registry.json` and copies files into target repos
- **`platforms.json`** — Every platform's skill dirs and config-dir override, read by `install.sh` and `uninstall.sh`
- **`lib/`** — Libraries the skills share: `tracker/` (the tracker CLI, backends and `docs/{local,github}.md`), `checks/` (run-checks.sh and dep-install's scripts), `git-workflow/`; each skill whose `libs` names one commits `skills/<skill>/scripts/<name>` as a link to `../../../lib/<name>`, and every install copies through it. The tracker choice is `.coding-crew/config.json`'s `tracker` section

### How Install Works

1. Reads `registry.json` to determine what to install
2. Resolves skill `deps` recursively
3. Copies each skill as committed — rendered (`scripts/render-skill.sh`), through its `scripts/<lib>` links into `lib/` — to its platform dir (e.g. `.claude/skills/<name>/`, `.agents/skills/<name>/` for Codex), with real directories and no links
4. Removes the shared library directory an older install linked every skill to (`remove_legacy_lib`)
5. Writes `.coding-crew/manifest.json`: the platforms and skills, no versions

No per-platform agent file (`.claude/agents/`, `.github/agents/`, `.pi/agents/`, `.codex/agents/`) is ever written.

---

## Registry Schema

`registry.json` defines all skills. Each skill entry includes:

### Skill Entry
```jsonc
"<skill-name>": {
  "source-dir": "<skill-name>",        // skills/<source-dir>/ holds SKILL.md and its files
  "description": "...",
  // installs to <projectSkills|userSkills>/<name> from platforms.json
  "deps": ["tdd", "dep-install"],      // other skills, installed recursively
  "libs": ["tracker", "checks"],       // lib/<name>, linked from skills/<skill>/scripts/<name> (optional)
  "source": "mattpocock/skills"                  // attribution (optional)
}
```

---

## Issue Tracker (This Repo)

The tracker is `.coding-crew/config.json`'s `tracker` section (`github` today); how each kind works is in `lib/tracker/docs/<kind>.md`.

- **One writer per issue:** change an issue's status or checkboxes only through the tracker CLI (`tick`, `mark-done`), never by editing it directly
- **Local tracker:** issues live in `.scratch/<feature-slug>/issues/{open,done}/`, PRDs in `.scratch/<feature-slug>/PRD.md`

---

## Key Conventions

### Adding a New Skill

1. Create `skills/<name>/SKILL.md`
2. Add skill entry to `registry.json` with its description, and `libs` for any library it runs
3. If the skill needs other skills, list them in `deps`
4. Test: `./install.sh claude --skill <name>`

### Dependency Resolution

- Skill `deps` are installed recursively with the skill

### Working Rules

`CLAUDE.md` is the full guide for any agent here; in short:

- **Tests:** `bash scripts/ci-run-bats.sh tests/*.bats`
- **CHANGELOG:** add one entry at the top of `[Unreleased]` (component prefix, what changed for a user, issue/PR number)
- **Comments:** follow solve-issue's comment rule (`skills/solve-issue/SKILL.md`, Step 4)
- **Layer ownership:** `solve-feature` → `solve-issue` → `tdd` / `dep-install`; `solve-issue` owns the procedure and must not know its caller, `tdd` / `dep-install` own one technique each (`tests/layer-ownership.bats`)
- **Skills stay boring:** a skill uses another skill by name, and shares code through a library linked into its own `scripts/` (a committed link into `lib/`, copied through at install), never a path into another skill's directory

---

## Available Skills

| Skill | Description |
|-------|-------------|
| `setup-coding-crew` | Take a repo from a fresh install to a working /solve-feature: tracker, check commands, and the Actions workflow with the github tracker |
| `configure-tracker` | Choose where the project's issues live: local markdown files or GitHub Issues |
| `crew-afk` | Start one feature's solve-feature run unattended in its own worktree, locally, in orca or in herdr |
| `solve-feature` | Run one feature's issues on one branch, each by a fresh coder subagent gated by the checks, then review, fix and describe its PR |
| `crew-review` | Review a branch or PR against a spec, from a context that did not write it and can run what it reviews; write one JSON report |
| `tdd` | Test-driven development with red-green-refactor loop |
| `solve-issue` | Implement one issue end-to-end: read, explore, install, TDD, verify, commit |
| `write-pr` | Write a short PR body for a human reviewer: Why, What changes, Risk and Tested |
| `address-pr-comments` | Fetch PR review comments, implement sensible ones with TDD |
| `domain-modeling` | Update CONTEXT.md glossary and create ADRs inline as decisions crystallise |
| `to-issues` | Break plan/PRD into independently-grabbable issues |
| `to-prd` | Synthesize conversation into PRD and publish to tracker |
| `crew-grill` | Full design pipeline: grill → PRD → issues. Add "with docs" to also update CONTEXT.md and ADRs |
| `crew-brainstorm` | Collaborative design pipeline: explore intent, propose approaches, build a spec, then hand off to to-issues |
| `add-tests` | Rank under-covered files by risk and turn the findings into ready-for-agent issues |
| `upgrade-deps` | Audit outdated npm/yarn/pnpm dependencies and plan safe upgrades as issues |
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
- Follow only the committed `skills/<skill>/scripts/<lib>` links into `lib/` (`find -L` on the source), never a link in the destination; install writes no link
