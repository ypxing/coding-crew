<div align="center">

# Coding Crew

### Describe a feature. Go to lunch. Come back to a reviewed PR.

**Turn the AI coding tool you already use into a whole dev team: a planner, a coder per issue, and a reviewer.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Claude Code](https://img.shields.io/badge/Claude_Code-supported-D97757)
![Copilot CLI](https://img.shields.io/badge/Copilot_CLI-supported-24292e)
![Codex CLI](https://img.shields.io/badge/Codex_CLI-supported-10a37f)
![pi](https://img.shields.io/badge/pi-supported-6f42c1)

</div>

---

A coding agent pairs with you one prompt at a time. Coding Crew works more like a team: you agree the
plan together, then it builds the feature **test-first, one issue at a time, each by a fresh coder**.
It lands only what passes your checks, reviews the whole feature, fixes what the review found, and you
get one PR at the end.

## Get going

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

That installs every skill at user level (under `~`). To install into one repo instead, run it from
inside the repo with `| bash -s -- --project` (or `./install.sh <platform> --project` from a clone).

Then, inside your coding agent:

```bash
/setup-coding-crew                                # once per repo: tracker + your check commands
/crew-grill add rate limiting to the public API   # 👤 plan it together → PRD + issues
/crew-afk rate-limit                              # 🤖 the crew builds it in its own worktree while you're away
/crew-afk status                                  # which PRs are ready for you
```

That's the whole workflow.

## How it works

```mermaid
flowchart LR
    plan["👤 <b>Plan together</b><br/>/crew-grill → issues"] --> coder
    subgraph away ["🤖 /crew-afk · while you're away"]
        coder["🧪 <b>Fresh coder per issue</b><br/>test-first"] --> gate{"🚦 <b>Your checks</b>"}
        gate -- "next issue" --> coder
        gate -- "all issues pass" --> review["🔍 <b>Review the whole feature</b><br/>at most two fix rounds"]
    end
    review -- "nothing needs you" --> ready(["✅ <b>PR marked ready</b>"])
    review -- "something does" --> needs(["🙋 <b>PR lists what needs you</b>"])
```

1. **Plan.** `/crew-grill` questions your idea until the edge cases are decided, then splits the work
   into small issues with testable acceptance criteria. If you're starting from a fuzzy idea,
   `/crew-brainstorm` shapes it first.
2. **Build.** `/crew-afk` starts the build in the feature's own worktree and returns at once.
   It hands each issue, in order, to a fresh coder on one branch. Each one has to pass
   your own checks and meet its acceptance criteria before it lands in the feature's draft PR.
3. **Review.** A reviewer reads the whole feature against the plan and catches what no single issue
   shows. The crew fixes the findings, gated by your checks, and reviews once more only when it fixed a
   critical, high or medium one; after that second round the run stops.
4. **Ship.** The PR is marked ready when nothing needs a person; otherwise it lists what does. You
   review one PR.

## What people use it for

| You want to…                              | Run                                                          |
| ----------------------------------------- | ------------------------------------------------------------ |
| 🚀 **Ship a feature overnight**           | `/crew-grill <idea>` → `/crew-afk <slug>`                    |
| 🌫️ **Start from a fuzzy idea**            | `/crew-brainstorm <idea>` → `/crew-afk <slug>`               |
| 🐛 **Burn down a bug backlog**            | `/to-issues <the bugs>` → `/crew-afk <slug>`                 |
| 🧪 **Cover risky untested code**          | `/add-tests` → `/crew-afk <slug>`                            |
| 📦 **Upgrade dependencies safely**        | `/upgrade-deps` → `/crew-afk <slug>`                         |
| 🔀 **Build several features in parallel** | one `/crew-afk <slug>` per feature, then `/crew-afk status`  |
| 💬 **Clear a PR's review comments**       | `/address-pr-comments`                                       |
| 🎯 **Pair on a single issue yourself**    | `/solve-issue <issue>`                                       |

Small, well-defined changes skip the Q&A. `/crew-grill` hands them straight to the issue writer.

## Why teams use it

- ✅ **Test-first, always.** Every coder works red, green, refactor.
- 🚦 **Nothing red merges.** Your own checks are the gate, not the model's opinion of its own work.
- 🔍 **A reviewer that sees the whole feature.** It reviews against the plan, not one diff at a time.
- 🔁 **Fixes itself, within bounds.** At most two review rounds, the second only after it fixed a critical, high or medium finding, each fix gated by your checks; then it stops.
- 🙋 **Only what needs you.** A PR it could not finish lists what needs a person; one it could is marked ready.
- 🧩 **Agent-agnostic.** Plain skills any skills-capable coding CLI can run; Claude Code, Copilot CLI, Codex CLI and [pi](https://github.com/badlogic/pi-mono) are supported today. Issues stay as local markdown or in GitHub Issues.

## The toolkit

<details>
<summary>All commands</summary>

| Command                  | What it does                                               |
| ------------------------ | ---------------------------------------------------------- |
| `/crew-grill`            | Stress-test a plan and turn it into issues                 |
| `/crew-brainstorm`       | Shape a fuzzy idea into a design, then issues              |
| `/to-issues`             | Split a plan into issues, or sharpen an existing one       |
| `/crew-afk`              | Start a feature's run in its own worktree; see how it ended |
| `/solve-feature`         | Run one feature's issues on one branch, each one verified  |
| `/address-pr-comments`   | Fix PR review comments, push once your checks pass         |
| `/solve-issue`           | Build one issue end to end, yourself                       |
| `/add-tests`             | Find risky untested code and plan tests for it             |
| `/upgrade-deps`          | Audit outdated packages and plan safe upgrades             |
| `/write-pr`              | Write a PR description a reviewer can act on               |
| `/setup-coding-crew`     | Set up tracker, checks and the optional Actions workflow   |
| `/configure-tracker`     | Choose local markdown or GitHub Issues                     |

</details>

## Learn more

- [User guide](docs/guide.md#part-2-using-this-repo-in-your-project): install options, configuration, the full pipeline, troubleshooting
- [Contributor guide](docs/guide.md#part-1-contributing-to-this-repo): adding skills and evolving the crew

## Acknowledgements

Several skills are borrowed from [Matt Pocock's skills collection](https://github.com/mattpocock/skills)
(MIT License, Copyright © 2026 Matt Pocock). See [LICENSE](LICENSE) for the full notice. Thanks Matt.

The `/crew-grill` design pipeline incorporates ideas from
[obra/superpowers](https://github.com/obra/superpowers). Thanks Jesse.
