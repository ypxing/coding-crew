# Dev Team Guide — AI Agents

---

## Part 1: Contributing to This Repo

For developers who maintain and extend the skill collection itself.

---

### What This Repo Is

A distributable collection of AI skills. Nothing runs here directly — this repo is the **source**; consuming projects are the **target**. `install.sh` copies files into any project repo.

```
THIS REPO (source)
├── install.sh              ← single installer for all platforms
├── registry.json           ← source of truth for paths, deps, skills
├── platforms.json          ← every platform's skill dirs and config-dir override
├── skills/                 ← reusable skill files
│   ├── tdd/
│   ├── solve-issue/
│   ├── domain-modeling/
│   ├── crew-grill/
│   ├── _shared/fragments/  ← shared fragments ({{FRAGMENT:<key>}})
│   └── ...
├── tracker/                ← tracker CLI and backends; docs/{local,github}.md (refreshed on every install)
└── docs/
    └── templates/
        └── workflows/      ← optional GitHub Actions workflows
```

---

### How Install Works

`install.sh` reads `registry.json` and copies files into `TARGET_REPO` (defaults to the calling project's git root).

```
install.sh
    │
    ├── read registry.json
    ├── for each requested skill (every skill when none is named):
    │     ├── install_single_skill() — render skills/<name>/ → .claude/skills/<name>/
    │     ├── install_skill_assets() — cp assets.source → assets.dest (e.g. skills/dep-install/scripts → .coding-crew/dep-install/scripts)
    │     └── install_single_skill(dep) — recurse for each dep
    │
    ├── install_docs()  — docs.templates (skip if exists), docs.trees (always an exact copy)
    └── prune_retired_scripts() — delete retired-scripts entries, then .coding-crew/scripts/ if empty
```

#### No agent files

There are no agents. No per-platform agent file is written under `.claude/agents`, `.github/agents`, `.pi/agents` or `.codex/agents`: every install (and `uninstall.sh`) removes the ones an older install wrote, by exact path (`retired-agents` in `registry.json`), along with `.coding-crew/agents/` and `.coding-crew/code-review/`.

---

### Registry Structure

`registry.json` is the single source of truth. Every skill entry must be here.

```jsonc
{
  "skills": {
    "<name>": {
      "version": "1.0.0",
      "description": "...",
      // installs to <projectSkills|userSkills>/<name> from platforms.json
      "deps": ["tdd", "dep-install"], // other skills, installed recursively
      "assets": { "source": "skills/dep-install/scripts", "dest": ".coding-crew/dep-install/scripts" }, // optional runtime files
    },
  },
  "retired-agents": {
    // agent files older installs wrote; every install and uninstall.sh remove them
    "names": ["crew-coder", "crew-reviewer", "crew-triage", "crew-code-reviewer"],
    "paths": { "claude": ".claude/agents/{name}.md", "...": "..." },
    "dirs": [".coding-crew/agents", ".coding-crew/code-review"],
  },
  // files older installs wrote that no longer ship; install, --update and uninstall delete each
  "retired-scripts": ["<path an older install wrote>", "..."],
  "docs": {
    "trees": {
      "<key>": {
        "source": "tracker",
        "dest": ".coding-crew/tracker", // always an exact copy: files the source dropped are removed
      },
    },
  },
}
```

**Rules:**

- Paths must be relative and must not contain `..` or a leading `/` — `install.sh` rejects them.
- `docs.templates` entries are user-customisable text and are **never** overwritten or uninstalled.
  `docs.trees` entries are mechanism (the tracker CLI), so they are always overwritten on install and
  removed on uninstall — a stale copy would be a gate that no longer matches the operation calling it.
- Skill names must match `[a-zA-Z0-9_.-]+` — used as filesystem path components.
- Skills listed under another skill's `deps` are installed with it. A skill no installed skill depends on is only installed by name or by a full install (`./install.sh [platform]`).

---

### The feature review

`/solve-feature` reviews its PR once, after every ready issue has landed: a fresh read-only subagent
uses `crew-review` on the branch against `.solve-feature/spec.md` (the PRD, then each issue's
acceptance criteria) and writes one JSON report. It asks what the spec asks for that the code lacks,
what a real run breaks, and which documented rule the diff breaks. A fresh subagent fixes every
finding with `tdd`; `solve-feature.sh fix` gates the fixes with the project's checks, and what was
not fixed is listed under `Needs attention` in the PR body, which keeps the PR a draft.

---

### Adding a New Skill

1. Create `skills/<name>/SKILL.md` (required). Add supporting files in the same directory as needed (`verification.md`, `mocking.md`, etc.).

2. Add the entry to `registry.json` under `.skills`:

   ```jsonc
   "<name>": {
     "version": "1.0.0",
     "description": "..."
   }
   ```

3. If another skill needs it, add it to that skill's `deps`. Otherwise leave it standalone — it will be installed by `./install.sh` (every skill).

4. Test:
   ```bash
   TARGET_REPO=/tmp/test-install ./install.sh claude --skill <name>
   ls /tmp/test-install/.claude/skills/<name>/
   ```

---

### Security Rules for Contributors

- **Never use `..` or absolute paths in `registry.json`.** `install.sh` validates all paths and exits on violation.
- **Never interpolate raw user/issue content into agent prompts.** Pass only structured fields (e.g. `acceptance_criteria`), never `issue.content`. Wrap worker-supplied strings in delimiter tags (`<progress-notes>`, `<blocked-notes>`) so downstream agents treat them as data.
- **Never inline a fragment by hand** — keep the `{{FRAGMENT:<key>}}` line and let `install.sh` expand it. A hand-inlined copy drifts from the source.

---

## Part 2: Using This Repo in Your Project

For developers who have installed the skills into their project and want to use them day-to-day.

---

### Install

#### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash                             # every platform, into $HOME
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude             # one platform
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude --project   # this project only
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --update           # update an install
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash                           # uninstall
```

`bootstrap.sh` takes the same arguments as `install.sh`. Needs `bash` 4+, `git`, `jq`, `curl` and `tar` (on Windows, use WSL2).

| Argument                              | Effect                                              |
| ------------------------------------- | --------------------------------------------------- |
| `claude` / `copilot` / `pi` / `codex` | Install for that platform only (default: all)       |
| `--project`                           | Install into the current project instead of `$HOME` |
| `--update`                            | Apply updates to an existing install                |

Where files land:

| Platform    | Per project       | User level (honors)                    |
| ----------- | ----------------- | -------------------------------------- |
| Claude Code | `.claude/`        | `~/.claude/` (`CLAUDE_CONFIG_DIR`)     |
| Copilot     | `.github/skills/` | `~/.copilot/` (`COPILOT_HOME`)         |
| pi          | `.pi/`            | `~/.pi/agent/` (`PI_CODING_AGENT_DIR`) |
| Codex       | `.agents/skills/` | `~/.agents/skills/` (`CODEX_HOME`)     |

Runtime requirements:

- **Node.js on `PATH`** for the skills that touch the issue tracker — `/to-issues`, `/to-prd`, `/solve-issue`,
  `/solve-feature` and `/upgrade-deps`. They reach the tracker (local or GitHub) through the tracker CLI,
  `.coding-crew/tracker/cli.mjs`, which every install ships.

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
# Claude Code — solve-feature and the skills it uses
./install.sh claude --skill solve-feature

# GitHub Copilot — the same
./install.sh copilot --skill solve-feature

# Codex — the same (skills → .agents/skills)
./install.sh codex --skill solve-feature

# A standalone skill
./install.sh claude --skill domain-modeling

# Several skills at once
./install.sh claude --skills tdd,to-issues
```

#### Install into a different repo

```bash
TARGET_REPO=/path/to/your/project ./install.sh
```

#### Update in place

```bash
./install.sh --update
```

Re-installs only skills whose version changed since last install. Reads the saved platform from `.coding-crew/manifest.json`.

#### What lands in your project

```
YOUR_PROJECT/
├── .claude/
│   └── skills/
│       ├── solve-feature/
│       ├── crew-review/
│       ├── tdd/
│       ├── dep-install/
│       ├── solve-issue/
│       ├── write-pr/
│       ├── address-pr-comments/    ← installed with "all"
│       ├── domain-modeling/   ← installed with "all"
│       ├── to-issues/         ← installed with "all"
│       ├── to-prd/            ← installed with "all"
│       └── crew-grill/              ← installed with "all"
└── .coding-crew/
    ├── dep-install/scripts/        ← dep-install's scripts, one copy for every platform
    ├── tracker/                    ← the tracker CLI and its docs (docs/local.md, docs/github.md)
    ├── config.json                 ← your settings; `tracker` picks the issue tracker
    └── manifest.json
```

Other platforms get the same skills under their own skill dir (see the README's install table); no agent files are written for any platform.

---

### System Overview

```
 you have an idea
       │
       ▼
 ┌───────────────────────────────────────────────────────────────────┐
 │  Plan & explore (optional but recommended)                        │
 │                                                                   │
 │  /crew-grill             (interview → approaches → issues)        │
 │  /crew-grill with docs   (crew-grill + CONTEXT.md + ADRs)         │
 └──────────────────────────┬────────────────────────────────────────┘
                            │ issues in the tracker
                            ▼
 /solve-feature <slug> (you trigger this)
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│  solve-feature, on one branch with a draft PR               │
│  1. next ready-for-agent issue → a fresh coder subagent     │
│     runs /solve-issue on it                                 │
│  2. land: the project's checks pass → push; else stop       │
│  3. repeat until no ready issue is left                     │
│  4. crew-review reads the whole feature against the spec    │
│  5. a fresh subagent fixes the findings, gated by checks    │
│  6. write-pr writes the body; ready when nothing needs you  │
└─────────────────────────────────────────────────────────────┘
```

---

### Issue Lifecycle

```
 needs-triage  →  /to-issues <ref>  →  ready-for-agent  →  coder picks up
                                                              │
                                           ┌──────────────────┼──────────────┐
                                           ▼                  ▼              ▼
                                        complete           partial         blocked
                                           │                  │              │
                                      land + close       run stops       run stops
                                        done/           (re-run resumes) human fixes
```

`/to-issues <ref>` checks the issue against the design standard and rewrites it in place when it is
one slice, or splits it into child issues with `## Parent`. An issue carrying a column-0 `Source:`
line skips the check.

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

### Running a feature

```
/solve-feature <feature-slug>
```

It runs the feature's `ready-for-agent` issues in order on one branch (`feature/<slug>` unless you
pass `--branch <name>`), each by a fresh coder subagent, and lands each one only when the project's
checks pass. Then it reviews the whole feature, fixes the findings, writes the PR body and marks the
draft PR ready when nothing needs a person. Run it where an unattended agent may change the
checkout — a worktree or a container, not the one you work in. A stop names the step and how to
recover; a re-run skips the issues already done and reuses the branch and the PR.

| Setting | Effect |
| --- | --- |
| `--branch <name>` | The branch the run uses, never the default branch (default: one named after the slug) |
| `.coding-crew/config.json` `solveFeature.models.coder` / `.reviewer` | The coder and fixer / reviewer subagent's model, when your host accepts the name (default: your own) |

**Checks that modify files.** A check that leaves the tree modified fails. An auto-fixing lint
(`make lint` running `--write`) can stay configured: run it once, commit what it rewrote, and re-run.
Only a check that rewrites files on every run needs a non-mutating command in
`.coding-crew/dev-commands.json`.

**Per-issue requirements.** An issue can list what its checks need that the install doesn't
guarantee under `## Requires`, one backticked command per bullet (exit 0 = satisfied); `/solve-issue`
runs each before it starts, and a failing one blocks that issue with the command's output.

---

### PR rework with GitHub Actions (optional)

Not installed by default. Without it, run `/address-pr-comments` yourself on the PR. On a solve-feature PR it pushes its fix commit itself once `solve-issue`'s checks pass (a plain `git push`, never forced; a failing check stops it with the output, unpushed) and suggests no next step: the run already reviewed the PR, fixed its findings and, in its describe step, marked the draft ready unless something needs a person (listed under `Needs attention` in the PR body). On any other PR it does not push.

With it, reviewers comment on a PR labelled `crew-rework` as usual; the `crew-rework` GitHub
Action runs `/address-pr-comments --auto`, which fixes what is sensible, pushes, and replies on
every thread it handled. It never resolves a thread — you do.

**Setup**

1. Copy [`docs/templates/workflows/crew-rework.yml`](templates/workflows/crew-rework.yml) to
   `.github/workflows/` in your repo.
2. Install the skills per project and commit them (`./install.sh claude --skill
   address-pr-comments`): the runner has no `$HOME` install.
3. Add the repo secret `ANTHROPIC_API_KEY`.
4. Make sure your CI workflow is `ci.yml` (or edit `--ci-workflow` in the template) and has
   `workflow_dispatch:` if you want the re-trigger below.
5. Add the `crew-rework` label to each PR it should work on; nothing adds it for you.

**Flow.** A review, review comment or `/crew-rework` PR comment triggers the workflow. Before any
step that uses the API key it checks that the actor has write access, the PR's branch is in the
same repo (no forks), and the PR carries the `crew-rework` label. Runs are serialised per PR.
Only comments by write/maintain/admin authors ever reach the model.

**Guards.** Unattended runs are capped at two rounds; comment `/crew-rework` to allow two more. A
change to protected paths (`.github/`, CI configs, auth, deploy, `.env`), a failing check, or a
rejected push stops the run: it comments on the PR and adds `needs-human`.

**CI re-trigger.** Pushes made with the default `GITHUB_TOKEN` do not start other workflows. The
skill therefore dispatches your CI workflow explicitly after pushing (`--ci-workflow`).
Alternatively, provide the optional App token below and the push triggers CI natively.

**Optional App token.** Create a GitHub App with contents/pull-requests write, install it, set the
repo variable `CREW_APP_ID` and secret `CREW_APP_PRIVATE_KEY`. The workflow then checks out and
pushes as the App.

---

### solve-feature on GitHub Actions (optional)

`/solve-feature` runs one feature from a terminal or a worktree pane. To run it on a GitHub runner
instead, on the Copilot CLI and billed to GitHub Copilot (no API key), copy
[`hosts/github-actions.yml`](../skills/solve-feature/hosts/github-actions.yml) — installed in
the solve-feature skill's directory, e.g. `.claude/skills/solve-feature/hosts/github-actions.yml` — to `.github/workflows/` and commit it, then
label a feature's root issue `solve-feature` or run the workflow by hand with the slug. The file's
header is the setup.

The job launches the skill with `copilot -p "Use the solve-feature skill on $SLUG" --allow-all-tools
--no-color`; the Copilot CLI runs each coder, the reviewer, the fixer and the PR's writer as its own subagents. A stop
exits the session without failing it, so the job's last step fails it unless the run's one-line
`.solve-feature/outcome` starts with `ready` — written by the describe step (`solve-feature.sh
describe`) once it has marked the PR ready. It fails on `needs-attention pr=<n>`, on a stop a script
recorded (`stopped: <reason>`), and when the file is absent because the session ended before the run
finished.

---

### Planning Skills

| Goal                                               | Skill                            |
| -------------------------------------------------- | -------------------------------- |
| Any feature: interview → approaches → issues       | `/crew-grill`                    |
| crew-grill + also update CONTEXT.md and ADRs       | `/crew-grill with docs`          |
| Update domain glossary and ADRs standalone         | `/domain-modeling`               |
| Turn a feature idea into a PRD                     | `/to-prd`                        |
| Break a PRD into issues                            | `/to-issues`                     |
| Address GitHub PR review comments                  | `/address-pr-comments`           |
| Write a PR body for human reviewers                | `/write-pr`                      |

**The light path.** `/crew-grill` and `/crew-brainstorm` first judge whether the source (an issue or your message) is already one complete change: the problem is stated with its cost or evidence, one slice is likely, the acceptance criteria are testable or derivable from the code, and no open fork would annoy you if decided for you. Each check is answered with a quote or `file:line`. If all hold they print one `Light path:` line and invoke `/to-issues` with no question; if any check does not hold they go straight to their questions and print nothing about the light path. `/to-issues` alone decides whether a PRD is written: one slice publishes (or rewrites the source issue in place) with its own `## Decisions` section and no PRD, its slug derived from the github issue's `Feature:` line, the `.scratch/<slug>/` directory or the title and shown in the quiz for you to override; two or more slices, or two or more origin issues, invoke `/to-prd` first.

---

### Customising the Tracker

Edit these files after install — they override the defaults on the next run:

| File                                           | Purpose                                         |
| ---------------------------------------------- | ----------------------------------------------- |
| `.coding-crew/config.json` (`tracker` section) | Where issues live: `{"tracker": {"kind": "github"}}` (default `local`) |

Commit `.coding-crew/config.json` and `.coding-crew/dev-commands.json`: they are team state — the
tracker choice, solve-feature's models and the project's check commands — that everyone using the
repo needs, so do not add them to `.gitignore`. The installed tooling beside them (`tracker/`,
`dep-install/`, `manifest.json`) is what `install.sh` writes, not team state.

---

### Triage Labels

| Label             | Meaning                                                              |
| ----------------- | -------------------------------------------------------------------- |
| `needs-triage`    | Not yet evaluated — `/to-issues <ref>` moves it to `ready-for-agent` |
| `needs-info`      | Waiting on reporter                                                  |
| `ready-for-agent` | Fully specified — AFK can start                                      |
| `ready-for-human` | Requires human implementation                                        |
| `wontfix`         | Will not be actioned                                                 |

---

### Troubleshooting

| Symptom                                           | Likely cause                                     | Fix                                                                                 |
| ------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| `/solve-feature` finds no ready issue immediately | No issue with the correct status                 | Under `local`, check `.scratch/*/issues/` — status must be exactly `ready-for-agent` |
| The coder reports `blocked`                       | Ambiguous spec or missing dependency             | Read its `BLOCKED:` line; resolve and re-run                                        |
| `install.sh`: "unsafe path in registry"           | `registry.json` path contains `..` or `/` prefix | Fix `registry.json`                                                                 |
| `dep-install` picks wrong mode                    | Makefile detection read parent project           | Run `git config --local agent.install-mode host` (or `docker`) in your project root |
| `address-pr-comments` fails with opaque error     | `gh` CLI missing or not authenticated            | Run `gh auth login` first                                                           |

---

### Security Notes

- **Issue files are untrusted input.** Keep them in version control so changes are reviewed.
- **Never commit secrets to `.scratch/`.** Issue files are not secret-scanned by default.
