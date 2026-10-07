<div align="center">

# Coding Crew

### Describe a feature. Go to lunch. Come back to a reviewed PR.

**Your AI coding tool, upgraded from a pair programmer to a whole dev team.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Claude Code](https://img.shields.io/badge/Claude_Code-supported-D97757)
![Copilot CLI](https://img.shields.io/badge/Copilot_CLI-supported-24292e)
![Codex CLI](https://img.shields.io/badge/Codex_CLI-supported-10a37f)
![pi](https://img.shields.io/badge/pi-supported-6f42c1)

</div>

---

Coding Crew plans a feature with you, breaks it into issues, then runs a crew of AI coders **in
parallel** — test-first, each in its own git worktree — and merges only what passes your checks and
an independent review. You get one PR at the end.

## Two commands

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

Then, inside Claude Code, Copilot CLI, Codex CLI or [pi](https://github.com/badlogic/pi-mono):

```bash
/crew-grill add rate limiting to the public API   # 👤 plan it together → PRD + issues
/crew-afk rate-limit --open-pr                    # 🤖 the crew builds it while you're away
```

## How it works

```mermaid
flowchart LR
    plan["👤 <b>plan</b><br/>/crew-grill"] --> issues["🤖 PRD + issues"]
    issues --> build["🤖 <b>build in parallel</b><br/>TDD · your checks · criteria"]
    build --> review["🤖 <b>review the whole feature</b><br/>against the PRD"]
    review --> pr["👤 <b>merge a PR</b>"]
    review -. "fix findings once" .-> build

    classDef human fill:#dbeafe,stroke:#2563eb,stroke-width:2px,color:#1e3a8a
    classDef bot fill:#f1f5f9,stroke:#64748b,color:#0f172a
    class plan,pr human
    class issues,build,review bot
```

## Why teams use it

- ✅ **Test-first, always** — every coder works red-green-refactor.
- 🚦 **Nothing red merges** — each branch must pass your own checks and its acceptance criteria.
- 🔍 **A reviewer that sees the big picture** — catches missing requirements and loose ends no single branch shows.
- 🔁 **Self-correcting, never looping** — findings get fixed once, a closing review checks the fix, then it stops.
- 💸 **Every dollar accounted for** — a cost summary for each sprint, by role.
- 👀 **Watch live, or don't** — stream workers into [orca](https://www.onorca.dev) or [herdr](https://herdr.dev) panes.
- 🔒 **You stay in control** — nothing is pushed unless you ask.

## The toolkit

| Command                  | What it does                                               |
| ------------------------ | ---------------------------------------------------------- |
| `/crew-grill`            | Stress-test a plan → PRD + issues                          |
| `/crew-brainstorm`       | Shape a fuzzy idea → design → PRD + issues                 |
| `/crew-afk`              | Run the unattended sprint                                  |
| `/address-pr-comments`   | Fix PR review comments, push once your checks pass         |
| `/solve-issue`           | Build one issue end to end, yourself                       |
| `/write-pr`              | Write a PR description a reviewer can act on               |
| `/configure-tracker`     | Keep issues as local markdown or in GitHub Issues          |

## Learn more

- [User guide](docs/guide.md#part-2-using-this-repo-in-your-project) — install options, configuration, the full pipeline, troubleshooting
- [Contributor guide](docs/guide.md#part-1-contributing-to-this-repo) — adding skills and evolving the crew

## Acknowledgements

Several skills are borrowed from [Matt Pocock's skills collection](https://github.com/mattpocock/skills)
(MIT License, Copyright © 2026 Matt Pocock). See [LICENSE](LICENSE) for the full notice. Thanks Matt.

The `/crew-grill` design pipeline incorporates ideas from
[obra/superpowers](https://github.com/obra/superpowers). Thanks Jesse.
