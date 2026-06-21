# Coding Crew

A distributable collection of AI agents and skills that automate the issue → implementation → review cycle.

---

## The flow

```
  you have an idea
       │
       ▼
  ┌─────────────────────────────────────────────────────┐
  │  Create issues                                      │
  │                                                     │
  │  /crew-grill             ← stress-test a plan       │
  │  OR                                                 │
  │  /crew-brainstorm        ← develop an idea          │
  └─────────────────┬───────────────────────────────────┘
                    │
                    ▼
             /crew-afk
                    │
       ┌────────────┼────────────┐
       ▼            ▼            ▼
   crew-coder   crew-coder   crew-coder  (parallel, isolated worktrees)
   issue 1       issue 2      issue 3
       └────────────┼────────────┘
                    │ committed branches merged
                    ▼
             crew-code-reviewer
                    │
                    ▼
       /crew-address-findings
```

---

## Prerequisites

Required tools:

- `bash` (4.0+)
- `jq` (for JSON processing)
- `git` (for version control)
- `curl` (for fetching remote releases)
- `tar` (for extracting release archives)

**Windows users:** You must install WSL2 (Windows Subsystem for Linux 2). Native Windows is not supported.

---

## 1. Install

Install everything to `$HOME` (user-level, works in any project):

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

Claude only:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude
```

Copilot only:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- copilot
```

Into the current project instead of `$HOME`:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --project
```

Pin to a specific release:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --version v1.2.0
```

Combine options freely:

```bash
# Specific version, Claude only, into current project
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude --version v1.2.0 --project

# Specific version with selected skills
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --version v1.2.0 --skills tdd,caveman
```

---

## 2. Team distribution

For teams who want to standardize on specific versions of agents and skills:

### Step 1: Team lead — Create the lockfile

After installing, create a `crew.lock` manually to pin the versions you want to distribute:

```json
{
  "registry": "https://github.com/ypxing/coding-crew",
  "version": "1.2.0",
  "skills": {
    "crew-afk": "1.0.0",
    "tdd": "1.0.0"
  }
}
```

Or use `--update` after an install to generate one from the current manifest:

```bash
./install.sh --update
```

This creates/rewrites `crew.lock` with the latest available versions.

### Step 2: Commit the lockfile

Add `crew.lock` to your dotfiles repo or team configuration repo:

```bash
git add crew.lock
git commit -m "Add coding-crew lockfile for v1.2.0"
```

### Step 3: Team members — Install from lockfile

Team members install the exact same versions using the lockfile:

```bash
./install.sh --from-lockfile crew.lock
```

This guarantees everyone uses identical agent and skill versions.

### Step 4: Upgrading — Update and review

To upgrade to a newer release:

```bash
./install.sh --update
```

This fetches the latest release, upgrades all agents and skills, and rewrites `crew.lock` with the new versions. Review the diff to see what changed:

```bash
git diff crew.lock
```

If everything looks good, commit the updated lockfile:

```bash
git add crew.lock
git commit -m "Upgrade coding-crew to v1.2.0"
```

Team members can then pull the updated lockfile and re-run:

```bash
./install.sh --from-lockfile crew.lock
```

---

## 3. Create issues

Pick **one**:

|              | `/crew-grill`                                   | `/crew-brainstorm`                                               |
| ------------ | ----------------------------------------------- | ---------------------------------------------------------------- |
| **Use when** | You have a plan and want it stress-tested       | You have an idea and need to develop it into a design            |
| **Input**    | A plan — including output from any AI plan mode | An idea, rough concept, or exploratory question                  |
| **Produces** | decisions record (`design.md`) + PRD + issues   | Full design doc (`design.md`) + PRD + issues                     |
| **Process**  | Relentless Q&A challenging every assumption     | Collaborative Q&A, approach proposals, section-by-section design |

**Tip:** Any plan — including output from an AI assistant's plan mode — is a natural input for `crew-grill`. Form your approach first, then run `/crew-grill` to challenge it and produce a PRD.

The `design.md` written by `crew-grill` is a **decisions record** (what was chosen and why). Implementation agents read it to understand the reasoning behind decisions and avoid reversing them when hitting edge cases.

Add `with docs` to `crew-grill` when you also want to update `CONTEXT.md` (domain glossary) and record architectural decisions as ADRs:

```
/crew-grill with docs
```

Run `/to-prd` or `/to-issues` standalone to jump into any individual phase.

---

## 4. Run the sprint

```
/crew-afk
```

Picks up every `ready-for-agent` issue, spawns crew-coder agents in parallel, commits, loops until done. Runs a code review pass on exit.

**Gitignored files in worktrees (`.worktreeinclude`)**

Each agent runs in an isolated git worktree. Files that are gitignored — like `.env`, `node_modules/`, or local config — are not present in a fresh worktree by default. To make them available to agents, create a `.worktreeinclude` file at your repo root listing the paths to symlink in:

```
# .worktreeinclude
.env
.env.local
```

This file is optional. If absent, agents only see tracked files. Both the Claude and Copilot platforms respect it — no per-platform configuration needed.

---

## 5. Address the review

```
/crew-address-findings
```

Opens the review report, triages findings, implements fixes with TDD.

---

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
```

---

## Skills

| Skill                    | When                                                                                                                     |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
| `/crew-grill`            | You have a plan — stress-test it via Q&A, writes decisions record, then PRD → issues. Accepts plan mode output as input. |
| `/crew-brainstorm`       | You have an idea — develop it collaboratively into a full design doc, then PRD → issues                                  |
| `/crew-afk`              | Run the sprint — parallel agents implement all ready issues                                                              |
| `/crew-address-findings` | Triage and fix the post-sprint code review report with TDD                                                               |
| `/solve-issue`           | Implement a single issue end-to-end                                                                                      |
| `/address-pr-comments`   | Fetch PR review comments from GitHub and implement sensible ones                                                         |
| `/configure-tracker`     | Select and install an issue tracker template                                                                             |

---

## Guides

- [Consumer guide](docs/guide.md#part-2-using-this-repo-in-your-project) — full setup, issue lifecycle, troubleshooting
- [Contributor guide](docs/guide.md#part-1-contributing-to-this-repo) — adding agents/skills, registry schema, security rules

---

## Acknowledgements

Several skills in this repo are borrowed directly from [Matt Pocock's skills collection](https://github.com/mattpocock/skills) (MIT License, Copyright © 2026 Matt Pocock). See [LICENSE](LICENSE) for the full copyright notice. Thanks Matt.

The `karpathy-guidelines` skill is derived from [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills), itself based on Andrej Karpathy's coding observations.

The `crew-brainstorm` skill is adapted from [obra/superpowers](https://github.com/obra/superpowers) `brainstorming` skill. Thanks Jesse.
