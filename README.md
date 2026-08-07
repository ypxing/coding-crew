# Coding Crew

AI agents that take your ideas from planning to code.

---

## The flow

```
                      an idea or plan
                             │
              ┌──────────────┴──────────────┐
              ▼                             ▼
         /crew-grill                /crew-brainstorm
         stress-test        OR       explore & build
         every flaw                     a design
              └─────────────┬───────────────┘
                            │ PRD + issues
                            │
                            ▼
  ┌─────────────────────────────────────────────────────┐
  │  /crew-afk — runs unattended, you can walk away     │
  │                                                     │
  │          ┌───────────────┬───────────────┐          │
  │          ▼               ▼               ▼          │
  │        coder          coder           coder         │
  │       issue 1        issue 2         issue 3        │
  │              (TDD, isolated worktrees)              │
  │          └───────────────┼───────────────┘          │
  │                          │ parallel, committed      │
  │                          ▼                          │
  │             verify checks (per branch)              │
  │        typecheck + lint + test, before merge        │
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

Two entry points — **pick one, not both.** They differ only in how they interrogate you; both end at the same PRD + issues.

**Concrete plan** — use `/crew-grill`:

```
/crew-grill
```

Adversarial interrogation: challenges every assumption, resolves every dependency, then produces a PRD and issues. Best when you have a plan and want it stress-tested before a line of code is written.

**Exploratory idea** — use `/crew-brainstorm`:

```
/crew-brainstorm
```

Collaborative dialogue: asks questions one at a time, proposes 2–3 approaches with trade-offs, builds a design doc, then hands off to PRD and issues. Best when the idea is still forming.

Add `with docs` to also update `CONTEXT.md` and record ADRs (crew-grill only):

```
/crew-grill with docs
```

Both produce a PRD as the single source of truth — implementation agents read it to understand architecture decisions, integration constraints, and requirements.

Run `/to-prd` or `/to-issues` standalone to jump into any individual phase.

---

## 2. Build, verify, review

```
/crew-afk
```

**AFK = Away From Keyboard.** Start it and leave — the sprint runs autonomously end to end: it picks up every `ready-for-agent` issue, spawns crew-coder agents in parallel, verifies, reviews, merges, and loops until nothing is left. No prompts, no approvals, no babysitting. Come back to merged code and a review report.

Before any branch merges, the orchestrator independently runs the project's checks in the worker's worktree (`verify-worktree.sh`) — a branch that fails verification is treated as partial and never merged. Then a code reviewer reviews each verified branch's diff before the merge, with findings written to `.scratch/<feature>/reviews/`. Review is advisory and never blocks a merge.

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

## 3. Address the review findings

```
/crew-address-findings
```

Opens the review report, triages findings, implements fixes with TDD.

---

## Skills

**Main flow**

| Step                       | Skill                    | What it does                                                          |
| -------------------------- | ------------------------ | --------------------------------------------------------------------- |
| 1. design                  | `/crew-grill`            | Concrete plan — stress-test every assumption → PRD + issues           |
| 2. build + verify + review | `/crew-afk`              | Away From Keyboard — autonomous parallel sprint over all ready issues |
| 3. address findings        | `/crew-address-findings` | Triage and fix the post-sprint code review report with TDD            |

> **Step 1 alternative:** if the idea is still forming, use `/crew-brainstorm` instead of `/crew-grill` — collaborative dialogue that proposes 2–3 approaches and builds a spec. Pick one or the other, never both: they end at the same PRD + issues.

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
| `pi`                     | pi only                                                                                   |
| `codex`                  | Codex only                                                                                |
| `--project`              | Install into the current project instead of `$HOME`                                       |
| `--version v1.2.0`       | Pin to a specific release and write a `crew.lock` recording it                            |
| `--version latest`       | Resolve the newest published release, then pin to it (`crew.lock` records the real tag)   |
| `--from-lockfile [path]` | Install the versions pinned in `crew.lock` (defaults to `./crew.lock`)                    |
| `--update`               | Check for and apply updates (uses `crew.lock` if present, otherwise the install manifest) |

**Requirements:** `bash` 4.0+, `jq`, `git`, `curl`, `tar`. Windows: WSL2 required.

**Supported agents:** Claude Code (`.claude/`), GitHub Copilot (`.copilot/`),
[pi](https://github.com/badlogic/pi-mono) (`.pi/` per project, `~/.pi/agent/` when installed
user-level), and OpenAI Codex (skills in `.agents/skills/`, agents in `.codex/agents/*.toml`). pi has
no built-in subagent tool, so `/crew-afk` dispatches each coder as its own `pi -p` process via
`scripts/dispatch-agent.sh` — same isolation, one process per issue. The `pi` CLI must be on `PATH`.
On Codex, each coder runs as its own `codex exec` process via `scripts/dispatch-codex-agent.sh` (a
native subagent would share the parent's working root, which breaks per-issue worktree isolation);
the `codex` CLI must be on `PATH`.

**Codex support means the local Codex CLI only.** The `codex` platform requires a real shell where
`codex exec` can be spawned as a child process, a local git clone to create worktrees in, and
already-completed auth (there is no interactive login inside a dispatch). The hosted Codex surfaces
— Codex in ChatGPT and the Codex cloud/web agent — are not supported: the orchestrator cannot launch
and `wait` on background worker processes there, and there is no persistent working root for
per-issue worktrees or the `.scratch/<slug>/dispatch/*.report.md` files it reads back.
Same applies to `pi`: local CLI only.

To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
```

---

## Team distribution

Pinning to a version writes a `crew.lock` automatically — commit it to your dotfiles or team config repo:

```bash
./install.sh --version v1.2.0
# newest published release, resolved to a concrete tag before pinning:
./install.sh --version latest
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
