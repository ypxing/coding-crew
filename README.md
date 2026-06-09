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
  │  auto:   /grill-me (or /grill-with-docs)            │
  │          → /to-prd → /to-issues                     │
  │                                                     │
  │  manual: write .scratch/.../issues/*.md             │
  └─────────────────┬───────────────────────────────────┘
                    │
                    ▼
             /afk-sprint
                    │
       ┌────────────┼────────────┐
       ▼            ▼            ▼
   coder         coder        coder      (parallel, isolated worktrees)
   issue 1       issue 2      issue 3
       └────────────┼────────────┘
                    │ committed branches merged
                    ▼
             code-reviewer
                    │
                    ▼
       /address-code-review
```

---

## 1. Install

Prerequisites: `git`, `jq`

```bash
TARGET_REPO=/path/to/your/project ./install.sh claude afk-sprint
```

---

## 2. Create issues

### Auto — from an idea

```
/grill-me          ← stress-test your idea interactively
                   (or /grill-with-docs — challenges against your domain model, creates one if you don't have it)
/to-prd            ← turn the refined idea into a PRD
/to-issues         ← break the PRD into ready-for-agent issues
```

### Manual — write them directly

Create `.scratch/<feature>/issues/01-slug.md`:

```markdown
Status: ready-for-agent

## What to build

One paragraph describing the end-to-end behavior.

## Acceptance criteria

- [ ] Criterion one
- [ ] Criterion two

## Blocked by

- None - can start immediately
```

---

## 3. Run the sprint

```
/afk-sprint
```

Picks up every `ready-for-agent` issue, spawns coder agents in parallel, commits, loops until done. Runs a code review pass on exit.

---

## 4. Address the review

```
/address-code-review
```

Opens the review report, triages findings, implements fixes with TDD.

---

## More install options

```bash
./install.sh                              # everything, all platforms
./install.sh claude                       # all agents + skills for Claude Code (claude.ai/code)
./install.sh copilot afk-sprint           # afk-sprint for GitHub Copilot
./install.sh claude --skill grill-me      # a standalone skill only
./install.sh --update                     # update changed agents/skills in place
```

---

## Skills

In order of use:

| Skill                            | When                                                                              |
| -------------------------------- | --------------------------------------------------------------------------------- |
| `/grill-me`                      | Stress-test your idea interactively                                               |
| `/grill-with-docs`               | Same, but challenges against your domain model — creates one if you don't have it |
| `/to-prd`                        | Turn the refined idea into a PRD                                                  |
| `/to-issues`                     | Break the PRD into ready-for-agent issues                                         |
| `/solve-issue`                   | Implement one issue manually (what coder uses internally)                         |
| `/address-pr-comments`           | After a PR review — implement sensible comments with TDD                          |
| `/improve-codebase-architecture` | Ongoing — find refactoring opportunities                                          |

---

## Guides

- [Consumer guide](docs/guide.md#part-2-using-this-repo-in-your-project) — full setup, issue lifecycle, troubleshooting
- [Contributor guide](docs/guide.md#part-1-contributing-to-this-repo) — adding agents/skills, registry schema, security rules

---

## Acknowledgements

Several skills in this repo are borrowed directly from [Matt Pocock's skills collection](https://github.com/mattpocock/skills) (MIT License, Copyright © 2026 Matt Pocock). See [LICENSE](LICENSE) for the full copyright notice. Thanks Matt.

The `karpathy-guidelines` skill is derived from [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills), itself based on Andrej Karpathy's coding observations.
