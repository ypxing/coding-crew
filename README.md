# Coding Crew

AI agents that take your ideas from planning to code.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

Installs for Claude Code, GitHub Copilot, [pi](https://github.com/badlogic/pi-mono), and OpenAI
Codex into `$HOME` (works in any project). Requires `bash` 4.0+, `jq`, `git`, `curl`, `tar`
(Windows: WSL2). See [Install options](#install-options) below for per-platform/per-project setup,
version pinning, and updates.

## Quickstart

1. **`/crew-grill`** — turn an idea into a PRD + issues (use `/crew-brainstorm` instead if the idea
   is still forming)
2. **`/crew-afk`** — unattended sprint: implements every issue in parallel, verifies, reviews, merges
3. **`/crew-address-findings`** — triage and fix whatever the review flagged

That's the whole loop. Details on each step below.

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

Two entry points — **pick one, not both.** They differ only in how they interrogate you; both end
at the same PRD + issues.

- **`/crew-grill`** — adversarial interrogation: challenges every assumption, resolves every
  dependency, then produces a PRD and issues. Best when you have a plan and want it stress-tested
  before a line of code is written.
- **`/crew-brainstorm`** — collaborative dialogue: asks questions one at a time, proposes 2–3
  approaches with trade-offs, builds a design doc, then hands off to PRD and issues. Best when the
  idea is still forming.

Add `with docs` to `/crew-grill` to also update `CONTEXT.md` and record ADRs. Run `/to-prd` or
`/to-issues` standalone to jump into a single phase.

## 2. Build, verify, review

```
/crew-afk
```

**AFK = Away From Keyboard.** It picks up every `ready-for-agent` issue, spawns crew-coder agents in
parallel worktrees, verifies, reviews, merges, and loops until nothing is left. Come back to merged
code and a review report.

Before any branch merges: the project's own checks run in that worker's worktree, and a failing
branch is never merged. A code reviewer then reviews the diff — findings land in
`.scratch/<feature>/reviews/` and are advisory, never blocking.

**Partial work is retained, not lost.** A worker that can't finish commits its work-in-progress with
a `[WIP]` marker on its own branch instead of merging; the next round resumes from there.

Two knobs worth knowing about:

- **Model tier** — `/crew-afk --model opus|sonnet|haiku|inherit` (default `sonnet`). The reviewer
  and triage judge run on the same model as the coder unless you name another, so the review
  standard doesn't silently drop. Applies on every platform, including Copilot — each worker is
  its own `copilot -p` process now, so the flag reaches the CLI.
- **Per-role runtime and model** — `.coding-crew/config.json` can put any role (`coder`, `reviewer`,
  `triage`, `commandsDiscovery`, `coverageValidation`) on another installed runtime, and name
  models per runtime:

  ```json
  { "afk": { "runtime": { "reviewer": "codex" },
             "models":  { "claude": { "triage": "opus" }, "codex": { "reviewer": "gpt-5.1-codex" } } } }
  ```

  A model is only ever passed to its own runtime's CLI. A role moved to another runtime doesn't
  inherit the coder's model; with none named under that runtime, the CLI picks its default. Each
  runtime a role uses must be installed (`./install.sh codex --skill crew-afk`); `crew-afk doctor`
  checks. `config.json` holds only settings you write; an older `.coding-crew/afk-models.json` is
  moved into it on the next run.

  It's read at two levels: `~/.coding-crew/config.json` for this machine, under the repo's
  `.coding-crew/config.json` for the team. They merge per setting, the repo's winning, and
  `crew-afk plan` tags each value with the file it came from. Keep the repo's file to aliases,
  since it's committed. Provider-specific IDs belong at user level, or in env such as
  `ANTHROPIC_DEFAULT_SONNET_MODEL`, which every dispatch inherits.
- **Gitignored files in worktrees** — each coder runs in an isolated worktree, so `.env` and similar
  files aren't there by default. List them in a `.worktreeinclude` file at your repo root to carry
  them over.
- **Worktree location** — worktrees live under `.scratch/worktrees/` by default. Set
  `CREW_WORKTREE_ROOT` (absolute, or relative to the repo root) to put them elsewhere — e.g. off the
  main checkout's disk/volume. Whatever you set won't be covered by the default `.scratch/` gitignore
  entry, so add it to `.gitignore` yourself if it lands inside the repo.

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

> **Step 1 alternative:** if the idea is still forming, use `/crew-brainstorm` instead of
> `/crew-grill` — pick one or the other, never both.

**Also available**

| Skill                  | When                                                             |
| ---------------------- | ---------------------------------------------------------------- |
| `/solve-issue`         | Implement a single issue end-to-end                              |
| `/address-pr-comments` | Fetch PR review comments from GitHub and implement sensible ones |
| `/configure-tracker`   | Select and install an issue tracker template — local markdown files or GitHub Issues |

---

## Install options

| Flag                     | Effect                                                                                    |
| ------------------------ | ----------------------------------------------------------------------------------------- |
| `claude`                 | Claude only (default: all platforms)                                                      |
| `copilot`                | Copilot only                                                                              |
| `pi`                     | pi only                                                                                   |
| `codex`                  | Codex only                                                                                |
| `--project`              | Install into the current project instead of `$HOME`                                       |
| `--update`               | Check for and apply updates, based on `.coding-crew/manifest.json`                        |

**Where things land:** Claude Code → `.claude/`; Copilot → `.github/agents/` + `.github/skills/`
per project, `~/.copilot/` when installed user-level (Copilot does not read `.copilot/` inside a
repo); pi → `.pi/` per project, `~/.pi/agent/` when installed user-level; Codex → skills in
`.agents/skills/`, agents in `.codex/agents/*.toml`.

A user-level install honors each platform's own config-dir override instead of assuming `$HOME`:
`CLAUDE_CONFIG_DIR` (Claude Code), `COPILOT_HOME` (Copilot CLI), `PI_CODING_AGENT_DIR` (pi),
`CODEX_HOME` (Codex). Set the one(s) you use before installing user-level and files land where
that CLI actually looks; unset, each falls back to its own `$HOME`-relative default above.

On every platform, `/crew-afk` runs each coder as its own child process in its own git worktree —
the matching CLI (`pi`, `codex`, `claude`, or `copilot`) must be on `PATH`. Two platform-specific
requirements:

- **Copilot** resolves `--agent` from the worker's own directory, so agent definitions must be
  either committed (`.github/agents/` is tracked) or installed user-level with `TARGET_REPO=$HOME`.
  A sprint refuses to start otherwise and says which.
- **pi and Codex support the local CLI only** — a sprint spawns background child processes against
  a local git clone, which the hosted Codex surfaces (Codex in ChatGPT, the Codex cloud/web agent)
  cannot support.

To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
```

---

## Guides

- [Consumer guide](docs/guide.md#part-2-using-this-repo-in-your-project) — full setup, issue
  lifecycle, troubleshooting
- [Contributor guide](docs/guide.md#part-1-contributing-to-this-repo) — adding agents/skills,
  registry schema, security rules

---

## Acknowledgements

Several skills are borrowed from [Matt Pocock's skills collection](https://github.com/mattpocock/skills)
(MIT License, Copyright © 2026 Matt Pocock). See [LICENSE](LICENSE) for the full notice. Thanks Matt.

The `/crew-grill` design pipeline incorporates ideas from
[obra/superpowers](https://github.com/obra/superpowers). Thanks Jesse.
