# Coding Crew

Turn an idea into merged, tested, reviewed code — while you're away from the keyboard.

You describe a feature. Coding Crew interviews you until the plan is solid, splits it into issues,
then runs a crew of AI coders in parallel — each in its own git worktree, test-first — and only
merges a branch after its checks pass and a separate reviewer has read it.

Works with **Claude Code**, **GitHub Copilot CLI**, **OpenAI Codex CLI** and
[**pi**](https://github.com/badlogic/pi-mono).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash
```

Installs for every supported platform into your home directory, so it works in any project.
Needs `bash` 4+, `git`, `jq`, `curl` and `tar` (on Windows, use WSL2).
For a single platform, a per-project install or updates, see [Install options](#install-options).

## How it works

👤 = you, 🤖 = runs on its own. Open your project in your AI coding tool:

```
 👤 /crew-grill            answer questions about your idea
    │                      (still shaping it? /crew-brainstorm instead)
    ▼
 🤖 PRD + issues
    │
    ▼
 👤 /crew-afk              then walk away
    │
    ▼
 🤖 preflight              clean tree · your checks pass on the feature branch
    │
    ▼
 🤖 per issue, in parallel, each in its own worktree:
      coder → verify → review → merge
        ▲       │ fail     │ criteria not met
        └── fix ┴──────────┘   same branch, up to 2 tries
    │ all issues done
    ▼
 🤖 integration check     your checks, on the merged feature branch
    │ red + fixable          → a fix issue, back into the per-issue loop (max 2); re-checked
    │ red + not fixable      → reported, no PR
    ▼
 🤖 full-feature review   one reviewer pass over the whole feature diff (not re-run after the fixes)
    │
    ▼
 🤖 PRD audit + HIGH/CRITICAL review findings → new issues → per-issue loop again (once)
    │
    ▼
 🤖 summary                (opens the PR with --open-pr; otherwise says how to)
    │
    ▼
 👤 /crew-address-findings pick which remaining findings to fix (optional)
 👤 review and merge
```

What you can rely on:

- **The issue is checked before coding.** The coder confirms the issue still matches the code;
  one that no longer does is blocked with evidence instead of guessed at.
- **Coding is test-first.** Each coder works with TDD in its own git worktree.
- **A failing branch is never merged.** Every branch must pass your project's own checks first.
- **A separate agent reviews every branch.** Unmet acceptance criteria send it back to the coder;
  other findings never block. They're written to `.scratch/<feature>/reviews/`.
- **The merged feature is checked as a whole.** Two branches can each pass and still break each
  other, so once the issues are done your checks run again on the merged feature branch. A red
  result is reported in the summary, and no PR is opened over it.
- **The whole feature diff is reviewed once.** A branch's review sees only its own diff, so when the
  issues are done a reviewer reads everything they merged together, for what only shows across
  issues (a helper written twice, error handling that differs between modules). Its findings are
  attributed to `feature` and handled like any others; it is skipped, and the summary says so, when
  the integration check is red.
- **The PRD is checked.** Once the issues are merged, the code is audited against the PRD and any
  requirement no issue covered becomes a new issue.
- **Work is never thrown away.** A retry continues on the same branch, and unfinished work is kept
  as `[WIP]` for the next run.
- **Nothing is pushed unless you ask.** Add `--open-pr` to push the feature branch and open a PR;
  without it, the summary ends with the `gh pr create` command for the branch (and the `Closes #n`
  lines, on GitHub).

## Common options

```bash
/crew-afk --model opus          # coder model: opus | sonnet (default) | haiku | inherit
/crew-afk --open-pr             # push the feature branch and open/update its PR at the end
/crew-afk --fix-findings none   # don't auto-fix review findings (default: high)
/crew-afk --max-parallel 2      # fewer concurrent coders
/crew-afk --no-integration-check # skip the checks on the merged feature branch (--no-baseline skips the one before dispatch)
```

To keep settings between runs, put them in `.coding-crew/config.json` (per repo) or
`~/.coding-crew/config.json` (per machine):

```json
{ "afk": { "openPr": true, "maxParallel": 2 } }
```

Coders run in fresh worktrees, so gitignored files such as `.env` aren't there. `.env` and
`docker-compose.override.yml` are copied automatically; list anything else in a
`.worktreeinclude` file at the repo root.

Every setting — per-role models and runtimes, timeouts, budgets, worktree location — is in the
[crew-afk configuration reference](docs/guide.md#configuring-crew-afk).

## All commands

| Command                  | Use it to                                                                               |
| ------------------------ | --------------------------------------------------------------------------------------- |
| `/crew-grill`            | Stress-test a plan → PRD + issues. Add `with docs` to also update `CONTEXT.md` and ADRs |
| `/crew-brainstorm`       | Explore an unformed idea → design → PRD + issues                                        |
| `/crew-afk`              | Run the unattended sprint over all `ready-for-agent` issues                             |
| `/crew-address-findings` | Triage and fix the sprint's review findings                                             |
| `/solve-issue`           | Implement one issue yourself, end to end                                                |
| `/to-prd`, `/to-issues`  | Run just the PRD step or just the issue-splitting step                                  |
| `/address-pr-comments`   | Fix sensible GitHub PR review comments and reply to them                                |
| `/configure-tracker`     | Choose where issues live: local markdown files (default) or GitHub Issues               |

Want PR review comments fixed automatically too? See the optional
[PR rework with GitHub Actions](docs/guide.md#pr-rework-with-github-actions-optional).

## Install options

`bootstrap.sh` takes the same arguments as `install.sh`:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude             # one platform
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude --project   # this project only
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --update           # update an install
```

| Argument                              | Effect                                              |
| ------------------------------------- | --------------------------------------------------- |
| `claude` / `copilot` / `pi` / `codex` | Install for that platform only (default: all)       |
| `--project`                           | Install into the current project instead of `$HOME` |
| `--update`                            | Apply updates to an existing install                |

Where files land:

| Platform    | Per project                          | User level (honors)                                    |
| ----------- | ------------------------------------ | ------------------------------------------------------ |
| Claude Code | `.claude/`                           | `~/.claude/` (`CLAUDE_CONFIG_DIR`)                     |
| Copilot     | `.github/agents/`, `.github/skills/` | `~/.copilot/` (`COPILOT_HOME`)                         |
| pi          | `.pi/`                               | `~/.pi/agent/` (`PI_CODING_AGENT_DIR`)                 |
| Codex       | `.agents/skills/`, `.codex/agents/`  | `~/.agents/skills/`, `~/.codex/agents/` (`CODEX_HOME`) |

Requirements for `/crew-afk`:

- The platform's **CLI must be on `PATH`** (`claude`, `copilot`, `codex` or `pi`) — each coder runs
  as its own process. `crew-afk doctor` reports anything missing.
- **Copilot:** agents must be committed (`.github/agents/`) or installed user-level; the sprint
  tells you which if neither.
- **Codex and pi:** local CLI only. Hosted surfaces (Codex in ChatGPT, Codex cloud) can't run a sprint.

Uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
```

## Learn more

- [User guide](docs/guide.md#part-2-using-this-repo-in-your-project) — writing issues, issue
  lifecycle, configuration, reading the logs, troubleshooting
- [Contributor guide](docs/guide.md#part-1-contributing-to-this-repo) — adding agents and skills,
  registry schema, security rules

## Acknowledgements

Several skills are borrowed from [Matt Pocock's skills collection](https://github.com/mattpocock/skills)
(MIT License, Copyright © 2026 Matt Pocock). See [LICENSE](LICENSE) for the full notice. Thanks Matt.

The `/crew-grill` design pipeline incorporates ideas from
[obra/superpowers](https://github.com/obra/superpowers). Thanks Jesse.
