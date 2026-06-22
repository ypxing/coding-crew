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

## 1. Create issues

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

## 2. Run the sprint

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

This file is optional. If absent, agents only see tracked files.

---

## 3. Address the review

```
/crew-address-findings
```

Opens the review report, triages findings, implements fixes with TDD.

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

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

This installs to `$HOME` (user-level, works in any project). Common flags:

| Flag | Effect |
| ---- | ------ |
| `claude` | Claude only (default: all platforms) |
| `copilot` | Copilot only |
| `--project` | Install into the current project instead of `$HOME` |
| `--version v1.2.0` | Pin to a specific release |

**Requirements:** `bash` 4.0+, `jq`, `git`, `curl`, `tar`. Windows: WSL2 required.

To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
```

---

## Team distribution

To standardize on a specific version across a team, commit a `crew.lock` to your dotfiles or team config repo:

```json
{
  "registry": "https://github.com/ypxing/coding-crew",
  "version": "1.2.0"
}
```

Generate one from the current install:

```bash
./install.sh --update
```

Team members install from it:

```bash
./install.sh --from-lockfile crew.lock
```

---

## Guides

- [Consumer guide](docs/guide.md#part-2-using-this-repo-in-your-project) — full setup, issue lifecycle, troubleshooting
- [Contributor guide](docs/guide.md#part-1-contributing-to-this-repo) — adding agents/skills, registry schema, security rules

---

## Acknowledgements

Several skills in this repo are borrowed directly from [Matt Pocock's skills collection](https://github.com/mattpocock/skills) (MIT License, Copyright © 2026 Matt Pocock). See [LICENSE](LICENSE) for the full copyright notice. Thanks Matt.

The `crew-brainstorm` skill is adapted from [obra/superpowers](https://github.com/obra/superpowers) `brainstorming` skill. Thanks Jesse.
