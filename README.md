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
  │  auto:   /crew-plan                                 │
  │                                                     │
  │  manual: /crew-grill-me (or /crew-grill-with-docs)  │
  │          → /crew-to-prd → /crew-to-issues           │
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
       /crew-address-code-review
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
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --version v1.0.0
```

Combine options freely:
```bash
# Specific version, Claude only, into current project
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude --version v1.0.0 --project

# Specific version with selected skills
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --version v1.0.0 --skills crew-tdd,crew-caveman
```

---

## 2. Team distribution

For teams who want to standardize on specific versions of agents and skills:

### Step 1: Team lead — Create the lockfile

After installing, create a `crew.lock` manually to pin the versions you want to distribute:

```json
{
  "registry": "https://github.com/ypxing/coding-crew",
  "version": "1.0.0",
  "skills": {
    "crew-afk": "1.1.0",
    "crew-tdd": "1.1.0"
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
git commit -m "Add coding-crew lockfile for v1.0.0"
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
git commit -m "Upgrade coding-crew to v1.1.0"
```

Team members can then pull the updated lockfile and re-run:

```bash
./install.sh --from-lockfile crew.lock
```

---

## 3. Create issues

### Auto — from an idea

```
/crew-plan       ← grill → PRD → issues in one flow
```

### Manual — step by step

```
/crew-grill-me          ← stress-test your idea interactively
                         (or /crew-grill-with-docs — challenges against your domain model, creates one if you don't have it)
/crew-to-prd            ← turn the refined idea into a PRD
/crew-to-issues         ← break the PRD into ready-for-agent issues
```

---

## 4. Run the sprint

```
/crew-afk
```

Picks up every `ready-for-agent` issue, spawns crew-coder agents in parallel, commits, loops until done. Runs a code review pass on exit.

---

## 5. Address the review

```
/crew-address-code-review
```

Opens the review report, triages findings, implements fixes with TDD.

---

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash
```

---

## Skills

In order of use:

| Skill                                    | When                                                                              |
| ---------------------------------------- | --------------------------------------------------------------------------------- |
| `/crew-plan`                             | Full design pipeline — grill → PRD → issues in one automated flow                 |
| `/crew-grill-me`                         | Stress-test your idea interactively (step-by-step alternative to `/crew-plan`)   |
| `/crew-grill-with-docs`                  | Same, but challenges against your domain model — creates one if you don't have it |
| `/crew-to-prd`                           | Turn the refined idea into a PRD                                                  |
| `/crew-to-issues`                        | Break the PRD into ready-for-agent issues                                         |
| `/crew-solve-issue`                      | Implement one issue manually (what crew-coder uses internally)                    |
| `/crew-address-pr-comments`              | After a PR review — implement sensible comments with TDD                          |
| `/crew-improve-codebase-architecture`    | Ongoing — find refactoring opportunities                                          |
| `/crew-caveman`                          | Switch to ultra-compressed communication to reduce token usage ~75%               |

---

## Guides

- [Consumer guide](docs/guide.md#part-2-using-this-repo-in-your-project) — full setup, issue lifecycle, troubleshooting
- [Contributor guide](docs/guide.md#part-1-contributing-to-this-repo) — adding agents/skills, registry schema, security rules

---

## Acknowledgements

Several skills in this repo are borrowed directly from [Matt Pocock's skills collection](https://github.com/mattpocock/skills) (MIT License, Copyright © 2026 Matt Pocock). See [LICENSE](LICENSE) for the full copyright notice. Thanks Matt.

The `karpathy-guidelines` skill is derived from [multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills), itself based on Andrej Karpathy's coding observations.
