# Coding Crew

AI agents that take your ideas from planning to code.

---

## The flow

```
  you have an idea or plan
           │
           ▼
  ┌─────────────────────────────────────────────────────┐
  │  plan & design                                      │
  │                                                     │
  │  /crew-grill         ← stress-test a plan           │
  │  /crew-brainstorm    ← develop an idea              │
  └─────────────────────┬───────────────────────────────┘
                        │
                        ▼
                 /crew-afk
                        │
         ┌──────────────┼──────────────┐
         ▼              ▼              ▼
     crew-coder     crew-coder     crew-coder   (parallel, isolated worktrees)
     issue 1        issue 2        issue 3
         └──────────────┼──────────────┘
                        │ committed branches merged
                        ▼
               crew-code-reviewer
                        │
                        ▼
         /crew-address-findings
```

---

## 1. Plan and design

Pick **one**:

|              | `/crew-grill`                                   | `/crew-brainstorm`                                               |
| ------------ | ----------------------------------------------- | ---------------------------------------------------------------- |
| **Use when** | You have a plan and want it stress-tested       | You have an idea and need to develop it into a design            |
| **Input**    | A plan — including output from any AI plan mode | An idea, rough concept, or exploratory question                  |
| **Produces** | decisions record (`design.md`) + PRD + issues   | Full design doc (`design.md`) + PRD + issues                     |
| **Process**  | Relentless Q&A challenging every assumption     | Collaborative Q&A, approach proposals, section-by-section design |

The `design.md` produced here is a decisions record — implementation agents read it to avoid reversing choices when hitting edge cases.

Add `with docs` to also update `CONTEXT.md` and record ADRs:

```
/crew-grill with docs
```

Run `/to-prd` or `/to-issues` standalone to jump into any individual phase.

---

## 2. Handoff to agents

```
/crew-afk
```

Picks up every `ready-for-agent` issue, spawns crew-coder agents in parallel, commits, loops until done. Runs a code review pass on exit.

**Gitignored files in worktrees (`.worktreeinclude`)**

Each agent runs in an isolated git worktree. Gitignored files like `.env` or `node_modules/` aren't present by default. To make them available, create a `.worktreeinclude` at your repo root:

```
# .worktreeinclude
.env
.env.local
```

---

## 3. Address the review

```
/crew-address-findings
```

Opens the review report, triages findings, implements fixes with TDD.

---

## Skills

**Main flow**

| Skill                    | When                                                                         |
| ------------------------ | ---------------------------------------------------------------------------- |
| `/crew-grill`            | Stress-test a plan via Q&A → decisions record → PRD → issues                 |
| `/crew-brainstorm`       | Develop an idea collaboratively → full design doc → PRD → issues             |
| `/crew-afk`              | Parallel agents implement all ready issues, then code review                 |
| `/crew-address-findings` | Triage and fix the post-sprint code review report with TDD                   |

**Also available**

| Skill                  | When                                                         |
| ---------------------- | ------------------------------------------------------------ |
| `/solve-issue`         | Implement a single issue end-to-end                          |
| `/address-pr-comments` | Fetch PR review comments from GitHub and implement sensible ones |
| `/configure-tracker`   | Select and install an issue tracker template                 |

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

Installs to `$HOME` (user-level, works in any project). Common flags:

| Flag               | Effect                                              |
| ------------------ | --------------------------------------------------- |
| `claude`           | Claude only (default: all platforms)                |
| `copilot`          | Copilot only                                        |
| `--project`        | Install into the current project instead of `$HOME` |
| `--version v1.2.0` | Pin to a specific release                           |

**Requirements:** `bash` 4.0+, `jq`, `git`, `curl`, `tar`. Windows: WSL2 required.

To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
```

---

## Team distribution

Commit a `crew.lock` to your dotfiles or team config repo to pin a version:

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

Several skills are borrowed from [Matt Pocock's skills collection](https://github.com/mattpocock/skills) (MIT License, Copyright © 2026 Matt Pocock). See [LICENSE](LICENSE) for the full notice. Thanks Matt.

The `crew-brainstorm` skill is adapted from [obra/superpowers](https://github.com/obra/superpowers). Thanks Jesse.
