# Coding Crew

AI agents that take your ideas from planning to code.

---

## The flow

```
                      an idea or plan
                             │
              ┌──────────────┴──────────────┐
              ▼                             ▼
      /crew-brainstorm                /crew-grill
      explore & build        OR        stress-test
          a design                     every flaw
              └─────────────┬───────────────┘
                            │ PRD + issues
                            │
                            ▼
  ┌─────────────────────────────────────────────────────┐
  │  /crew-afk                                          │
  │                                                     │
  │          ┌───────────────┬───────────────┐          │
  │          ▼               ▼               ▼          │
  │        coder          coder           coder         │
  │       issue 1        issue 2         issue 3        │
  │              (TDD, isolated worktrees)              │
  │          └───────────────┼───────────────┘          │
  │                          │ parallel, committed      │
  │                          ▼                          │
  │              verify-worktree.sh (per branch)        │
  │              independent check run before merge     │
  │                          │                          │
  │                          ▼                          │
  │              code-reviewer (per branch)             │
  │              before merge, findings advisory        │
  │                          │                          │
  │                          ▼                          │
  │                   merge + squash                    │
  └─────────────────────────────────────────────────────┘
                             │
                             ▼
                   /crew-address-findings
```

---

## 1. Plan and design

Two entry points depending on where you're starting from:

**Exploratory idea** — use `/crew-brainstorm`:

```
/crew-brainstorm
```

Collaborative dialogue: asks questions one at a time, proposes 2–3 approaches with trade-offs, builds a design doc, then hands off to PRD and issues. Best when the idea is still forming.

**Concrete plan** — use `/crew-grill`:

```
/crew-grill
```

Adversarial interrogation: challenges every assumption, resolves every dependency, then produces a PRD and issues. Best when you have a plan and want it stress-tested before a line of code is written.

Add `with docs` to also update `CONTEXT.md` and record ADRs (crew-grill only):

```
/crew-grill with docs
```

Both produce a PRD as the single source of truth — implementation agents read it to understand architecture decisions, integration constraints, and requirements.

Run `/to-prd` or `/to-issues` standalone to jump into any individual phase.

---

## 2. Handoff to agents

```
/crew-afk
```

Picks up every `ready-for-agent` issue, spawns crew-coder agents in parallel, commits, loops until done. Before any branch merges, the orchestrator independently runs the project's checks in the worker's worktree (`verify-worktree.sh`) — a branch that fails verification is treated as partial and never merged. Then a code reviewer reviews each verified branch's diff before the merge, with findings written to `.scratch/<feature>/reviews/`. Review is advisory and never blocks a merge.

**Partial work is committed and retained.** When a worker cannot finish (partial status or failed verification), it commits its work-in-progress with a `[WIP]` marker to its own branch. That branch is not merged and not deleted — it survives wrap-up so the next round's worker resumes on it instead of starting from scratch. Retained branches are listed in the sprint summary with their reason.

**Model selection**

By default, coders run on `sonnet`. Pass `--model` to use a different tier:

```
/crew-afk --model opus      # use a higher tier for this sprint
/crew-afk --model haiku     # use a lighter tier
/crew-afk --model inherit   # omit model param, inherit from session
```

The reviewer always inherits the session model — it is deliberately not pinned.

On Copilot, `--model` is accepted but has no effect: the IDE selects the model, and an explicit notice is printed when the flag is used.

The resolved model is written to the orchestrator trace log and included in the sprint summary.

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

| Skill                    | When                                                                 |
| ------------------------ | -------------------------------------------------------------------- |
| `/crew-brainstorm`       | Exploratory idea — collaborate, propose approaches, build spec → PRD |
| `/crew-grill`            | Concrete plan — stress-test every assumption → PRD                   |
| `/crew-afk`              | Parallel agents implement all ready issues, then code review         |
| `/crew-address-findings` | Triage and fix the post-sprint code review report with TDD           |

**Also available**

| Skill                  | When                                                             |
| ---------------------- | ---------------------------------------------------------------- |
| `/solve-issue`         | Implement a single issue end-to-end                              |
| `/address-pr-comments` | Fetch PR review comments from GitHub and implement sensible ones |
| `/configure-tracker`   | Select and install an issue tracker template                     |

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

Installs to `$HOME` (user-level, works in any project). Common flags:

| Flag                     | Effect                                                                                    |
| ------------------------ | ----------------------------------------------------------------------------------------- |
| `claude`                 | Claude only (default: all platforms)                                                      |
| `copilot`                | Copilot only                                                                              |
| `--project`              | Install into the current project instead of `$HOME`                                       |
| `--version v1.2.0`       | Pin to a specific release and write a `crew.lock` recording it                            |
| `--from-lockfile [path]` | Install the versions pinned in `crew.lock` (defaults to `./crew.lock`)                    |
| `--update`               | Check for and apply updates (uses `crew.lock` if present, otherwise the install manifest) |

**Requirements:** `bash` 4.0+, `jq`, `git`, `curl`, `tar`. Windows: WSL2 required.

To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
```

---

## Team distribution

Pinning to a version writes a `crew.lock` automatically — commit it to your dotfiles or team config repo:

```bash
./install.sh --version v1.2.0
# or, without a local clone:
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --project --version v1.2.0
```

Team members install from it (defaults to `./crew.lock`; pass a path for a different location):

```bash
./install.sh --from-lockfile
```

Or without a local clone:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --from-lockfile
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --update
```

---

## Guides

- [Consumer guide](docs/guide.md#part-2-using-this-repo-in-your-project) — full setup, issue lifecycle, troubleshooting
- [Contributor guide](docs/guide.md#part-1-contributing-to-this-repo) — adding agents/skills, registry schema, security rules

---

## Acknowledgements

Several skills are borrowed from [Matt Pocock's skills collection](https://github.com/mattpocock/skills) (MIT License, Copyright © 2026 Matt Pocock). See [LICENSE](LICENSE) for the full notice. Thanks Matt.

The `/crew-grill` design pipeline incorporates ideas from [obra/superpowers](https://github.com/obra/superpowers). Thanks Jesse.
