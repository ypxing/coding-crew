# Dev Team Guide — AI Agents

---

## Part 1: Contributing to This Repo

For developers who maintain and extend the agent/skill collection itself.

---

### What This Repo Is

A distributable collection of AI agents and skills. Nothing runs here directly — this repo is the **source**; consuming projects are the **target**. `install.sh` copies files into any project repo.

```
THIS REPO (source)
├── install.sh              ← single installer for all platforms
├── registry.json           ← source of truth for paths, deps, skills
├── agents/
│   ├── crew-coder/         ← single-issue worker agent
│   └── crew-code-reviewer/ ← post-sprint reviewer agent
├── skills/                 ← reusable skill files
│   ├── tdd/
│   ├── solve-issue/
│   ├── domain-modeling/
│   ├── crew-grill/
│   ├── caveman/
│   └── ...
└── docs/
    └── agents/
        ├── issue-tracker.md    ← default tracker template (copied on install)
        └── triage-labels.md    ← default triage labels (copied on install)
```

---

### How Install Works

`install.sh` reads `registry.json` and copies files into `TARGET_REPO` (defaults to the calling project's git root).

```
install.sh
    │
    ├── read registry.json
    ├── for each agent:
    │     ├── install_skills()   — cp -r skills/<name>/ → .claude/skills/<name>/
    │     ├── install_docs()     — cp docs/<file> → docs/agents/<file>  (skip if exists)
    │     ├── expand_shim()      — replace {{PROTOCOL}} in platform file → write to dest
    │     └── install_agent(dep) — recurse for each dep
    │
    └── (when AGENT=all) install every skill in registry.json
```

#### `{{PROTOCOL}}` inlining

Platform files (`claude.*.md`, `copilot.agent.md`) may contain a `{{PROTOCOL}}` placeholder. During install, this is replaced line-by-line with the contents of `protocol.md` or `workflow.js` from the same agent directory. The installed file is self-contained — no runtime file references.

```
agents/crew-coder/
├── claude.agent.md       ← contains {{PROTOCOL}}
├── copilot.agent.md      ← contains full inline instructions (no {{PROTOCOL}})
└── protocol.md           ← inlined into claude.agent.md on install
```

---

### Registry Structure

`registry.json` is the single source of truth. Every agent and skill entry must be here.

```jsonc
{
  "agents": {
    "<name>": {
      "version": "1.0.0",
      "description": "...",
      "deps": ["<other-agent>"], // installed recursively before this agent
      "deps-copilot": ["..."], // platform-specific dep override (optional)
      "skills": ["tdd", "solve-issue"], // skills copied for this agent
      "docs": ["issue-tracker.md"], // doc templates copied (skipped if exist)
      "platforms": ["claude", "copilot"], // omit to support all
      "install": {
        "shims": {
          "claude": ".claude/agents/<name>.md",
          "copilot": ".github/agents/<name>.agent.md",
        },
      },
    },
  },
  "skills": {
    "<name>": {
      "version": "1.0.0",
      "description": "...",
      "install": ".claude/skills/<name>", // destination dir in target repo
    },
  },
  "docs": {
    "<file.md>": {
      "description": "...",
      "install": "docs/agents/<file.md>",
    },
  },
}
```

**Rules:**

- Paths must be relative and must not contain `..` or a leading `/` — `install.sh` rejects them.
- Skill/agent names must match `[a-zA-Z0-9_.-]+` — used as filesystem path components.
- Skills listed under `agents.<name>.skills` are installed as agent deps. Skills not listed under any agent are only installed when `AGENT=all`.

---

### Adding a New Agent

1. Create the agent directory: `agents/<name>/`

2. Write the protocol source — one of:
   - `protocol.md` — markdown instructions (tried first by `install.sh`)
   - `workflow.js` — a Workflow script (used if no `protocol.md`)

3. Create platform files directly under `agents/<name>/` (no `shims/` subdirectory):
   - `claude.<type>.md` — use `{{PROTOCOL}}` where the protocol should be inlined
   - `copilot.agent.md` — inline the full instructions (or use `{{PROTOCOL}}`)

4. Add the entry to `registry.json` (paths, deps, skills, docs).

5. Test locally:

   ```bash
   TARGET_REPO=/tmp/test-install ./install.sh claude <name>
   ls /tmp/test-install/.claude/agents/
   ```

6. Verify no `..` or absolute paths crept into registry:
   ```bash
   jq '.agents, .skills, .docs | .. | objects | .install? // empty' registry.json
   ```

---

### Adding a New Skill

1. Create `skills/<name>/SKILL.md` (required). Add supporting files in the same directory as needed (`verification.md`, `mocking.md`, etc.).

2. Add the entry to `registry.json` under `.skills`:

   ```jsonc
   "<name>": {
     "version": "1.0.0",
     "description": "...",
     "install": ".claude/skills/<name>"
   }
   ```

3. Wire it to an agent if it is a hard dependency (add to that agent's `skills` array). Otherwise leave it standalone — it will be installed by `./install.sh all`.

4. Test:
   ```bash
   TARGET_REPO=/tmp/test-install ./install.sh claude --skill <name>
   ls /tmp/test-install/.claude/skills/<name>/
   ```

---

### Security Rules for Contributors

- **Never use `..` or absolute paths in `registry.json`.** `install.sh` validates all paths and exits on violation.
- **Never interpolate raw user/issue content into agent prompts.** Pass only structured fields (e.g. `acceptance_criteria`), never `issue.content`. Wrap worker-supplied strings in delimiter tags (`<progress-notes>`, `<blocked-notes>`) so downstream agents treat them as data.
- **Never expand `{{PROTOCOL}}` yourself** — let `install.sh` do it. Manually inlined protocols will drift from the source.
- **Only one `claude.*` or `copilot.*` file per agent directory.** `install.sh` errors on multiples to prevent non-deterministic selection.

---

## Part 2: Using This Repo in Your Project

For developers who have installed the agents into their project and want to use them day-to-day.

---

### Install

#### Prerequisites

```bash
git --version   # any modern version
jq --version    # required
```

#### Install everything

```bash
# from the coding-crew source repo
./install.sh
```

#### Install only what you need

```bash
# Claude Code — full sprint suite
./install.sh claude --skill crew-afk

# GitHub Copilot — full sprint suite
./install.sh copilot --skill crew-afk

# A standalone skill
./install.sh claude --skill domain-modeling

# A doc template only
./install.sh claude --doc issue-tracker.md
```

#### Install into a different repo

```bash
TARGET_REPO=/path/to/your/project ./install.sh
```

#### Update in place

```bash
./install.sh --update
```

Re-installs only agents and skills whose version changed since last install. Reads the saved platform from `.coding-crew.manifest.json`.

#### What lands in your project

```
YOUR_PROJECT/
├── .claude/
│   ├── agents/
│   │   ├── crew-coder.md           ← crew-coder agent (Claude)
│   │   └── crew-code-reviewer.md   ← reviewer agent (Claude)
│   └── skills/
│       ├── crew-afk/SKILL.md
│       ├── tdd/
│       ├── dep-install/
│       ├── solve-issue/
│       ├── crew-address-findings/
│       ├── caveman/           ← installed with crew-afk
│       ├── address-pr-comments/    ← installed with "all"
│       ├── improve-codebase-architecture/  ← installed with "all"
│       ├── domain-modeling/   ← installed with "all"
│       ├── to-issues/         ← installed with "all"
│       ├── to-prd/            ← installed with "all"
│       └── crew-grill/              ← installed with "all"
├── .github/
│   └── agents/
│       ├── crew-afk.agent.md
│       ├── crew-coder.agent.md
│       └── crew-code-reviewer.agent.md
└── docs/
    └── agents/
        ├── issue-tracker.md        ← edit to match your tracker
        └── triage-labels.md        ← edit to match your labels
```

---

### System Overview

```
 you have an idea
       │
       ▼
 ┌─────────────────────────────────────────────────────────────┐
 │  Plan & explore (optional but recommended)                  │
 │                                                             │
 │  /crew-grill             (lightweight: Q&A → PRD → issues)  │
 │  /crew-brainstorm        (thorough: Q&A + design.md → PRD)  │
 │  /crew-grill with docs   (crew-grill + CONTEXT.md + ADRs)   │
 └──────────────────────────┬──────────────────────────────────┘
                            │ .scratch/.../issues/*.md
                            ▼
 /crew-afk (you trigger this)
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│  crew-afk orchestrator                                      │
│  1. List "ready-for-agent" issues from .scratch/            │
│  2. Spawn crew-coder workers — up to 8 in parallel          │
│  3. Validate output, merge complete branches                │
│  4. Write progress / blocked notes, loop                    │
│  5. Run crew-code-reviewer on exit                          │
└────────────────────┬────────────────────────────────────────┘
                     │ isolated git worktrees
          ┌──────────┴──────────┐
          ▼                     ▼
    ┌───────────┐         ┌───────────┐
    │ crew-coder│   ...   │ crew-coder│
    │ (1 issue) │         │ (1 issue) │
    └───────────┘         └───────────┘
          │ branches merged
          ▼
    ┌──────────────────────┐
    │  crew-code-reviewer  │  advisory findings → .scratch/reviews/
    └──────────────────────┘
          │
          ▼
    /crew-address-findings (you trigger this)
```

---

### Issue Lifecycle

```
 needs-triage  →  ready-for-agent  →  crew-coder picks up
                                            │
                         ┌──────────────────┼──────────────┐
                         ▼                  ▼              ▼
                      complete           partial         blocked
                         │                  │              │
                    merge + close     ## Progress     ## Blocked
                      done/           next round      human fixes
```

---

### Writing Issues

Create files under `.scratch/<feature>/issues/NN-slug.md`:

```markdown
Status: ready-for-agent

## What to build

One paragraph — describe the end-to-end behavior, not layer-by-layer steps.

## Acceptance criteria

- [ ] Criterion one
- [ ] Criterion two

## Blocked by

- 01-prior-issue.md ← or: None - can start immediately
```

Use `/to-prd` → `/to-issues` to generate these from a feature description automatically.

---

### Running the Sprint

**Claude Code:**

```
/crew-afk
```

**Copilot:** invoke `@crew-afk` from the chat panel.

Sprint runs until all issues are complete, or two consecutive rounds produce zero completions (stall). On exit it saves a code review report to `.scratch/reviews/sprint-review-<timestamp>.md`.

---

### Reviewing Code Review Findings

```
/crew-address-findings
```

Opens the latest sprint review, shows a triage table (Actionable / Debatable / Dismiss), implements fixes with TDD, commits, and archives the report.

---

### Planning Skills

| Goal                                                  | Skill                            |
| ----------------------------------------------------- | -------------------------------- |
| Well-understood feature: Q&A → PRD → issues (fast)    | `/crew-grill`                    |
| Complex/exploratory: Q&A + design doc with code → PRD | `/crew-brainstorm`               |
| crew-grill + also update CONTEXT.md and ADRs          | `/crew-grill with docs`          |
| Update domain glossary and ADRs standalone            | `/domain-modeling`               |
| Turn a feature idea into a PRD                        | `/to-prd`                        |
| Break a PRD into issues                               | `/to-issues`                     |
| Address GitHub PR review comments                     | `/address-pr-comments`           |
| Find architecture improvement opportunities           | `/improve-codebase-architecture` |
| Reduce token usage during long sessions               | `/caveman`                       |

---

### Customising the Tracker

Edit these files after install — they override the defaults on the next run:

| File                           | Purpose                                   |
| ------------------------------ | ----------------------------------------- |
| `docs/agents/issue-tracker.md` | Where issues live, how to list/close them |
| `docs/agents/triage-labels.md` | Map canonical roles to your label strings |

---

### Triage Labels

| Label             | Meaning                         |
| ----------------- | ------------------------------- |
| `needs-triage`    | Not yet evaluated               |
| `needs-info`      | Waiting on reporter             |
| `ready-for-agent` | Fully specified — AFK can start |
| `ready-for-human` | Requires human implementation   |
| `wontfix`         | Will not be actioned            |

---

### Troubleshooting

| Symptom                                           | Likely cause                                     | Fix                                                                                 |
| ------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| "No unblocked ready-for-agent issues" immediately | No `.md` files with correct `Status:` line       | Check `.scratch/*/issues/` — status must be exactly `ready-for-agent`               |
| Worker returns `blocked` every round              | Ambiguous spec or missing dependency             | Read `## Blocked` in the issue file; resolve and re-trigger                         |
| `install.sh`: "unsafe path in registry"           | `registry.json` path contains `..` or `/` prefix | Fix `registry.json`                                                                 |
| `install.sh`: "multiple claude.\* files"          | Agent dir has more than one `claude.*`           | Remove the extra file                                                               |
| Code review says "skipped (no commits)"           | No commits this session                          | Normal — nothing to review                                                          |
| `dep-install` picks wrong mode                    | Makefile detection read parent project           | Run `git config --local agent.install-mode host` (or `docker`) in your project root |
| `address-pr-comments` fails with opaque error     | `gh` CLI missing or not authenticated            | Run `gh auth login` first                                                           |

---

### Security Notes

- **Issue files are untrusted input.** Only structured fields (`acceptance_criteria`) are passed to workers — never raw file content. Keep issue files in version control so changes are reviewed.
- **Workers cannot write outside their worktree.** The crew-coder agent enforces `PROJECT_ROOT` boundaries.
- **Code review findings are advisory.** Nothing is auto-blocked or re-queued — a human always decides.
- **Never commit secrets to `.scratch/`.** Issue files are not secret-scanned by default.
