# Dev Team Guide — AI Agents

---

## Part 1: Contributing to This Repo

For developers who maintain and extend the skill collection itself.

---

### What This Repo Is

A distributable collection of AI skills. Nothing runs here directly — this repo is the **source**; consuming projects are the **target**. `install.sh` copies the skills into `$HOME` (user level) or into a project repo (`--project`).

```
THIS REPO (source)
├── install.sh              ← single installer for all platforms
├── registry.json           ← source of truth for paths, deps, skills
├── platforms.json          ← every platform's skill dirs and config-dir override
├── skills/                 ← reusable skill files
│   ├── tdd/
│   ├── solve-issue/
│   ├── domain-modeling/
│   ├── crew-grill/
│   ├── _shared/fragments/  ← shared fragments (rendered between <!-- fragment:<key> --> markers)
│   └── ...
├── lib/                    ← libraries the skills share, linked into each skill that uses one
│   ├── tracker/            ← tracker CLI and backends; docs/{local,github}.md
│   ├── checks/             ← run-checks.sh, the dev commands file (discover/write-commands-cache) and dep-install's install/run scripts
│   └── git-workflow/       ← commit-changes, branch-safety-check
└── docs/
    └── templates/
        └── workflows/      ← optional GitHub Actions workflows
```

---

### How Install Works

`install.sh` reads `registry.json` and installs into `<root>`: `$HOME` by default, or a repo with
`--project [<path>]` (or `TARGET_REPO`).

```
install.sh
    │
    ├── read registry.json
    ├── for each requested skill (every skill when none is named):
    │     ├── install_single_skill() — copy skills/<name>/ as committed, its scripts/<lib>/ copies
    │     │                              included → <skills dir>/<name>/, an exact copy
    │     └── install_single_skill(dep) — recurse for each dep
    │
    └── write_manifest() — <root>/.coding-crew/manifest.json: the platforms and skills
```

An installed skill is a byte-for-byte copy of `skills/<name>/`, the same tree `npx skills add` writes,
with no link into anything outside it. `install.sh --update` uninstalls every skill the manifest lists,
then installs the listed skills the registry still has, for every platform it lists.

#### No agent files

There are no agents. No per-platform agent file is written under `.claude/agents`, `.github/agents`, `.pi/agents` or `.codex/agents`.

---

### Registry Structure

`registry.json` is the single source of truth. Every skill entry must be here.

```jsonc
{
  "skills": {
    "<name>": {
      "source": "...", // optional attribution for a skill adapted from elsewhere
      // installs to <projectSkills|userSkills>/<name> from platforms.json
      "deps": ["tdd", "dep-install"], // other skills, installed recursively
      "libs": ["tracker", "checks"], // lib/<lib>, copied by the renderer to skills/<name>/scripts/<lib>
    },
  },
}
```

**Rules:**

- No versions: only the release (CHANGELOG / tag) has one, and `--update` reinstalls everything.
- A skill reaches shared code only through a library its `libs` names, run as
  `<skill-dir>/scripts/<lib>/<file>`; its own `scripts/` holds no file named like a library.
- Skill and library names must match `[a-zA-Z0-9_.-]+` — used as filesystem path components.
- Skills listed under another skill's `deps` are installed with it. A skill no installed skill depends on is only installed by name or by a full install (`./install.sh [platform]`).
- `deps` match what the skill's text invokes: every skill its rendered SKILL.md or `references/` names is reachable through its `deps`, and every direct dep is named in its SKILL.md, `references/` or `scripts/`. `tests/skill-deps.bats` checks both; a mention that only points a person at another skill goes on its allowlist with a reason.

---

### The feature review

`/solve-feature` reviews its PR at most twice, after every ready issue has landed: a fresh read-only subagent
uses `crew-review` on the branch against `.solve-feature/spec.md` (the PRD, then each issue's
acceptance criteria) and writes one JSON report. It asks what the spec asks for that the code lacks,
what a real run breaks, and which documented rule the diff breaks. A fresh subagent fixes every
finding with `tdd`; `solve-feature.sh fix` gates the fixes with the project's checks. When the first
review had a CRITICAL, HIGH or MEDIUM finding and the fixer changed something, `fix` prints
`review-again=yes` and the run reviews and fixes once more; the second fix is not reviewed again. What
the last round did not fix is listed under `Needs attention` in the PR body, which keeps the PR a draft.

---

### Adding a New Skill

1. Create `skills/<name>/SKILL.md` (required). Add supporting files in the same directory as needed (`verification.md`, `mocking.md`, etc.).

2. Add the entry to `registry.json` under `.skills`:

   ```jsonc
   "<name>": {
     "description": "..."
   }
   ```

3. If another skill needs it, add it to that skill's `deps`. Otherwise leave it standalone — it will be installed by `./install.sh` (every skill).

4. Test:
   ```bash
   ./install.sh claude --skill <name> --project /tmp/test-install
   ls /tmp/test-install/.claude/skills/<name>/
   ```

---

### Security Rules for Contributors

- **Never name a path in `registry.json`.** Skills and libraries are names (`[a-zA-Z0-9_.-]+`); `install.sh` rejects anything else.
- **Never edit between fragment markers or under a skill's `scripts/<lib>/`** — edit `skills/_shared/fragments/<key>.md` or `lib/<lib>/`, then run `bash scripts/render-skill.sh` and commit what it rewrites. A hand edit there drifts from the source, and `tests/rendered-tree.bats` fails on it.

---

## Part 2: Using This Repo in Your Project

For developers who have installed the skills into their project and want to use them day-to-day.

---

### Install

#### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash                             # every platform, into $HOME
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude             # one platform
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude --project   # this project only
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --update           # update an install
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash                           # uninstall
```

`bootstrap.sh` takes the same arguments as `install.sh`. Needs `bash` 4+, `git`, `jq`, `curl` and `tar` (on Windows, use WSL2).

| Argument                              | Effect                                              |
| ------------------------------------- | --------------------------------------------------- |
| `claude` / `copilot` / `pi` / `codex` | Install for that platform only (default: all)       |
| `--project`                           | Install into the current project instead of `$HOME` |
| `--update`                            | Apply updates to an existing install                |

Where files land:

| Platform    | Per project       | User level (honors)                    |
| ----------- | ----------------- | -------------------------------------- |
| Claude Code | `.claude/`        | `~/.claude/` (`CLAUDE_CONFIG_DIR`)     |
| Copilot     | `.github/skills/` | `~/.copilot/` (`COPILOT_HOME`)         |
| pi          | `.pi/`            | `~/.pi/agent/` (`PI_CODING_AGENT_DIR`) |
| Codex       | `.agents/skills/` | `~/.agents/skills/` (`CODEX_HOME`)     |

Runtime requirements:

- **Node.js on `PATH`** for the skills that touch the issue tracker — `/to-issues`, `/to-prd`, `/solve-issue`,
  `/solve-feature` and `/upgrade-deps`. They reach the tracker (local or GitHub) through the tracker CLI,
  `<skill-dir>/scripts/tracker/cli.mjs`, the copy of the tracker library each of those skills ships.

#### Prerequisites

```bash
git --version   # any modern version
jq --version    # required
```

#### Install everything

```bash
# from the coding-crew source repo
./install.sh
```

#### Install only what you need

```bash
# Claude Code — solve-feature and the skills it uses
./install.sh claude --skill solve-feature

# GitHub Copilot — the same
./install.sh copilot --skill solve-feature

# Codex — the same (skills → .agents/skills)
./install.sh codex --skill solve-feature

# A standalone skill
./install.sh claude --skill domain-modeling

# Several skills at once
./install.sh claude --skills tdd,to-issues
```

These install at user level (`$HOME`). Add `--project` to install into the current repo instead,
or `--project <path>` (or `TARGET_REPO=<path>`) for another one:

```bash
./install.sh claude --project /path/to/your/project
```

#### Update in place

```bash
./install.sh --update             # user level
./install.sh --update --project   # the current repo
```

Uninstalls every skill and library `.coding-crew/manifest.json` lists, then installs those skills again
from this checkout, for every platform the manifest names. An install made before libraries (it has
`.coding-crew/tracker/` or `.coding-crew/dep-install/`) updates the same way; remove what it left once:
`rm -rf <root>/.coding-crew/{tracker,crew-afk,dep-install,solve-issue,to-issues,write-pr,skills}`.

#### What lands where

At project level (`--project`), with claude; a user-level install writes the same under `~`:

```
YOUR_PROJECT/
├── .claude/
│   └── skills/
│       ├── solve-feature/
│       ├── crew-review/
│       ├── tdd/
│       ├── dep-install/
│       ├── solve-issue/
│       ├── write-pr/
│       ├── address-pr-comments/    ← installed with "all"
│       ├── domain-modeling/   ← installed with "all"
│       ├── to-issues/         ← installed with "all"
│       ├── to-prd/            ← installed with "all"
│       └── crew-grill/              ← installed with "all"
└── .coding-crew/
    ├── config.json                 ← your settings; `tracker` picks the issue tracker
    └── manifest.json
```

Each skill's `scripts/<lib>/` is its own copy of the library (`tracker/` with its docs, `checks/`,
`git-workflow/`). A gitignored project install reaches a worktree only through `.worktreeinclude`.

Other platforms get the same skills under their own skill dir (see the README's install table); no agent files are written for any platform.

---

### System Overview

```
 you have an idea
       │
       ▼
 ┌───────────────────────────────────────────────────────────────────┐
 │  Plan & explore (optional but recommended)                        │
 │                                                                   │
 │  /crew-grill             (interview → approaches → issues)        │
 │  /crew-grill with docs   (crew-grill + CONTEXT.md + ADRs)         │
 └──────────────────────────┬────────────────────────────────────────┘
                            │ issues in the tracker
                            ▼
 /crew-afk <slug> → /solve-feature <slug> in the feature's own worktree (or run /solve-feature yourself)
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│  solve-feature, on one branch with a draft PR               │
│  1. next ready-for-agent issue → a fresh coder subagent     │
│     runs /solve-issue on it                                 │
│  2. land: the project's checks pass → push; else stop       │
│  3. repeat until no ready issue is left                     │
│  4. crew-review reads the whole feature against the spec    │
│  5. a fresh subagent fixes the findings, gated by checks;   │
│     after a CRITICAL/HIGH/MEDIUM fix, 4–5 run once more     │
│  6. write-pr writes the body; ready when nothing needs you  │
└─────────────────────────────────────────────────────────────┘
```

---

### What a feature looks like on the tracker

A feature is a slug and the issues filed under it. Where they live depends on the tracker
(`.coding-crew/config.json`'s `tracker` section):

- **github** — one root issue whose body carries a column-0 `Feature: <slug>` line (the feature's
  `PRD:` issue, or for a single-slice feature the work issue itself), and every other issue a native
  sub-issue of that root.
- **local** — a directory, `.scratch/<slug>/`: an optional `PRD.md`, and the issues as
  `issues/open/NN-<slug>.md`, moved to `issues/done/` once done.

Every issue has the same body on either tracker. A local issue's first line is its `Status:`; a
GitHub issue carries that status as a label instead:

```markdown
Status: ready-for-agent

## What to build

One paragraph — describe the end-to-end behavior, not layer-by-layer steps.

## Acceptance criteria

- [ ] Criterion one
- [ ] Criterion two

## Blocked by

- 01-prior-issue.md ← github: Issue #<n>; or: None - can start immediately
```

`/to-prd` → `/to-issues` write these for you from a feature description.

**Triage labels** — a local issue's `Status:` value, a GitHub issue's label:

| Label             | Meaning                                                              |
| ----------------- | -------------------------------------------------------------------- |
| `needs-triage`    | Not yet evaluated — `/to-issues <ref>` moves it to `ready-for-agent` |
| `needs-info`      | Waiting on reporter                                                  |
| `ready-for-agent` | Fully specified — AFK can start                                      |
| `ready-for-human` | Requires human implementation                                        |
| `wontfix`         | Will not be actioned (github: closed as `not-planned`, not a label)  |

GitHub adds two more. `blocked`, set by a person beside `ready-for-agent`, keeps an issue that needs a
human out of the queue. `awaiting-merge` is what an issue's `done` looks like there: implemented on the
feature branch, open until the PR that closes it merges. A local issue's `done` is `Status: done` in
`issues/done/`.

**What `next` and `land` read.** The feature is found by its slug — the `Feature:` line on github, the
directory on local. `next` picks an open `ready-for-agent` issue (not `blocked`) whose every
`## Blocked by` issue is done (on local, `issues-deps.json` takes the place of `## Blocked by` when
`/to-issues` wrote one); `land` asks `next` again after the coder, and an issue still first was not
closed. The status, `## Blocked by` and the `Feature:` line are all they read, so an issue missing one
of them is never found or never starts.

```
 needs-triage  →  /to-issues <ref>  →  ready-for-agent  →  coder picks up
                                                              │
                                           ┌──────────────────┼──────────────┐
                                           ▼                  ▼              ▼
                                        complete           partial         blocked
                                           │                  │              │
                                      land + close       run stops       run stops
                                        done/           (re-run resumes) human fixes
```

`/to-issues <ref>` checks the issue against the design standard and rewrites it in place when it is
one slice, or splits it into child issues with `## Parent`. An issue carrying a column-0 `Source:`
line skips the check.

The mechanics — how `next` resolves blockers, what `mark-done` swaps, how to reopen an issue — are in
the tracker doc every install ships beside the tracker CLI: `<skill-dir>/scripts/tracker/docs/<kind>.md`
in any coding-crew skill that uses the tracker (e.g. `solve-issue`).

---

### Running a feature

```
/solve-feature <feature-slug>
```

It runs the feature's `ready-for-agent` issues in order on one branch (`feature/<slug>` unless you
pass `--branch <name>`), each by a fresh coder subagent, and lands each one only when the project's
checks pass. Then it reviews the whole feature and fixes the findings, at most twice: it reviews again
only after fixing a CRITICAL, HIGH or MEDIUM finding. It writes the PR body and marks the draft PR ready
when nothing needs a person. The body opens with a line saying solve-feature (naming the feature slug) wrote
the PR with agents, so nobody reads it as a person's words. Run it where an unattended agent may change the
checkout — a worktree or a container, not the one you work in. A stop names the step and how to
recover; a re-run skips the issues already done and reuses the branch and the PR, merging the default
branch into it first (a conflict stops the run for you to merge by hand).

| Setting | Effect |
| --- | --- |
| `--branch <name>` | The branch the run uses, never the default branch (default: one named after the slug) |
| `.coding-crew/config.json` `solveFeature.models.coder` / `.reviewer` | The coder and fixer / reviewer subagent's model, when your host accepts the name (default: your own) |

**Checks that modify files.** A check that leaves the tree modified fails. An auto-fixing lint
(`make lint` running `--write`) can stay configured: run it once, commit what it rewrote, and re-run.
Only a check that rewrites files on every run needs a non-mutating command in the dev commands file
(below).

**Per-issue requirements.** An issue can list what its checks need that the install doesn't
guarantee under `## Requires`, one backticked command per bullet (exit 0 = satisfied); `/solve-issue`
runs each before it starts, and a failing one blocks that issue with the command's output.

**Unattended, in its own worktree.** `/crew-afk <feature>` starts that `/solve-feature` run for you
and returns at once. It resolves the feature from a likely name, then prepares (or reuses) one
worktree per feature beside your checkout, at `<repo>/../<repo-name>-worktrees/<slug>`, linking each
`.worktreeinclude` entry and copying `.env` into it. The agent you ran `/crew-afk` in writes the
command that starts a session of its own CLI there, and crew-afk runs it as given.

| `--to` | Where the run goes |
| --- | --- |
| `local` (default) | A detached headless session, capped at 1 hour; it logs to `<worktree>/.solve-feature/run.log` (needs `timeout`, on macOS `brew install coreutils`) |
| `orca` | An orca-managed worktree and an interactive agent in an orca terminal, uncapped: you watch and steer it |
| `herdr` | An interactive agent in a new herdr pane on the worktree, uncapped |

`/crew-afk status [<feature>]` prints each run's outcome line (`ready pr=<n>`, `needs-attention pr=<n>`
or `stopped: …`), `running (pid <n>)`, or why there is none — for a local run that ended without one,
`re-run /crew-afk <slug> to continue` (a re-run skips the issues already done). For a local run whose
command printed a JSON result with a cost as its last line, the outcome line ends with what the run cost
and how long it took: `ready pr=7 cost=$1.73 (23 min)` (`cost=$<n> (<m> min)`); a run whose CLI prints
no such line, or that the 1h cap killed, has none. `/crew-afk wait <feature>` on a local run
returns once its process is gone, not at the outcome, so its line carries the cost too. A second `/crew-afk` on a feature whose local run is still going is refused; one to orca or herdr
while its agent still works starts a second agent beside it.
Nothing removes a worktree: `git worktree remove <path>` once you are done with it.

---

### PR rework with GitHub Actions (optional)

Not installed by default. Without it, run `/address-pr-comments` yourself on the PR. On a solve-feature PR it pushes its fix commit itself once `solve-issue`'s checks pass (a plain `git push`, never forced; a failing check stops it with the output, unpushed) and suggests no next step: the run already reviewed the PR, fixed its findings and, in its describe step, marked the draft ready unless something needs a person (listed under `Needs attention` in the PR body). On any other PR it does not push.

With it, reviewers comment on a PR labelled `crew-rework` as usual; the `crew-rework` GitHub
Action runs `/address-pr-comments --auto`, which fixes what is sensible, pushes, and replies on
every thread it handled. It never resolves a thread — you do.

**Setup**

1. Copy [`docs/templates/workflows/crew-rework.yml`](templates/workflows/crew-rework.yml) to
   `.github/workflows/` in your repo.
2. Install the skills per project and commit them (`./install.sh claude --skill
   address-pr-comments --project`): the runner has no `$HOME` install.
3. Add the repo secret `ANTHROPIC_API_KEY`.
4. Make sure your CI workflow is `ci.yml` (or edit `--ci-workflow` in the template) and has
   `workflow_dispatch:` if you want the re-trigger below.
5. Add the `crew-rework` label to each PR it should work on; nothing adds it for you.

**Flow.** A review, review comment or `/crew-rework` PR comment triggers the workflow. Before any
step that uses the API key it checks that the actor has write access, the PR's branch is in the
same repo (no forks), and the PR carries the `crew-rework` label. Runs are serialised per PR.
Only comments by write/maintain/admin authors ever reach the model.

**Guards.** Unattended runs are capped at two rounds; comment `/crew-rework` to allow two more. A
change to protected paths (`.github/`, CI configs, auth, deploy, `.env`), a failing check, or a
rejected push stops the run: it comments on the PR and adds `needs-human`.

**CI re-trigger.** Pushes made with the default `GITHUB_TOKEN` do not start other workflows. The
skill therefore dispatches your CI workflow explicitly after pushing (`--ci-workflow`).
Alternatively, provide the optional App token below and the push triggers CI natively.

**Optional App token.** Create a GitHub App with contents/pull-requests write, install it, set the
repo variable `CREW_APP_ID` and secret `CREW_APP_PRIVATE_KEY`. The workflow then checks out and
pushes as the App.

---

### solve-feature on GitHub Actions (optional)

`/solve-feature` runs one feature from a terminal or a worktree pane. To run it on a GitHub runner
instead, run `/setup-coding-crew` with the github tracker and answer yes to its Actions step: it copies
[`hosts/github-actions.yml`](../skills/setup-coding-crew/hosts/github-actions.yml) to
`.github/workflows/solve-feature.yml`, creates the `run-agent` label, sets the repo variable
`CREW_AGENT` to the agent you pick and prints the commit line for it. `copilot` (the default) is billed
to GitHub Copilot with no API key; `claude` runs Claude Code on an `ANTHROPIC_API_KEY` or
`CLAUDE_CODE_OAUTH_TOKEN` repo secret. Commit, then label a feature's root issue `run-agent` or run the
workflow by hand with the slug. The file's header explains billing.

The job launches the skill with `copilot -p "Use the solve-feature skill on $SLUG" --allow-all
--no-color` or `claude -p "/solve-feature $SLUG" --dangerously-skip-permissions --output-format stream-json
--verbose` (every tool and path: the skill's scripts are outside the checkout), adding `--model` when the repo
variable `CREW_MODEL` names one (else the CLI's default for the account); the agent runs each coder, the
reviewer, the fixer and the PR's writer as its own subagents, on that model unless `solveFeature.models` names
theirs. Claude's job log shows the run as it goes, one line per step (the model, each command and subagent, a
failed tool), and keeps the whole stream as `.solve-feature/session.jsonl`. Every run uploads `.solve-feature/` as an artifact, so the checks log a stop names
outlives the runner; a stop at an issue's checks has already pushed its work and made the issue ready again,
so a re-run picks it up there. A stop
exits the session without failing it, so the job's last step fails it unless the run's one-line
`.solve-feature/outcome` starts with `ready` — written by the describe step (`solve-feature.sh
describe`) once it has marked the PR ready. It fails on `needs-attention pr=<n>`, on a stop a script
recorded (`stopped: <what> failed: <reason>`), and when the file is absent because the session ended before the run
finished. The same step writes the run's summary page: the outcome, the PR, the model, and what to read next
(a stop's coder report and checks log tail, a needs-attention's list), so a failed run says why without the
artifact.

The job pushes and opens the PR with the workflow's own `GITHUB_TOKEN`, so the PR's `pull_request` runs wait for
someone with write access to approve them, after every push. After the session, the job approves the runs held on
the PR's head commit, so the PR's CI runs and shows on the PR. Where GitHub refuses the approval, the job dispatches
that workflow on the PR's branch instead, which needs a `workflow_dispatch:` trigger in it; that run's checks are on
the commit but not listed on the PR. A failure of both is a warning, and leaves the run waiting for approval.

---

### Planning Skills

| Goal                                               | Skill                            |
| -------------------------------------------------- | -------------------------------- |
| Any feature: interview → approaches → issues       | `/crew-grill`                    |
| crew-grill + also update CONTEXT.md and ADRs       | `/crew-grill with docs`          |
| Update domain glossary and ADRs standalone         | `/domain-modeling`               |
| Turn a feature idea into a PRD                     | `/to-prd`                        |
| Break a PRD into issues                            | `/to-issues`                     |
| Address GitHub PR review comments                  | `/address-pr-comments`           |
| Write a PR body for human reviewers                | `/write-pr`                      |

**The light path.** `/crew-grill` and `/crew-brainstorm` first judge whether the source (an issue or your message) is already one complete change: the problem is stated with its cost or evidence, one slice is likely, the acceptance criteria are testable or derivable from the code, and no open fork would annoy you if decided for you. Each check is answered with a quote or `file:line`. If all hold they print one `Light path:` line and invoke `/to-issues` with no question; if any check does not hold they go straight to their questions and print nothing about the light path. `/to-issues` alone decides whether a PRD is written: one slice publishes (or rewrites the source issue in place) with its own `## Decisions` section and no PRD, its slug derived from the github issue's `Feature:` line, the `.scratch/<slug>/` directory or the title and shown in the quiz for you to override; two or more slices, or two or more origin issues, invoke `/to-prd` first.

---

### Customising the Tracker

Edit these files after install — they override the defaults on the next run:

| File                                           | Purpose                                         |
| ---------------------------------------------- | ----------------------------------------------- |
| `.coding-crew/config.json` (`tracker` section) | Where issues live: `{"tracker": {"kind": "github"}}` (default `local`) |

Commit `.coding-crew/config.json`: it is team state — the tracker choice and solve-feature's models —
that everyone using the repo needs, so do not add it to `.gitignore`.

**The dev commands file** holds the project's checks (`test`, `lint`, `typecheck`, …), its install
command and its install mode (`install_mode`: `host` or `docker`, with `docker_service`). The first
`/solve-issue` or `/solve-feature` coder discovers the checks and, in a repo with a compose file, the
mode; `/dep-install` discovers the mode too, and shows you its answer to change first. They are
written to `.git/coding-crew/dev-commands.json`: outside every working tree, shared by all worktrees
of the clone, never committed. To share them with your team or CI, run `/setup-coding-crew`: it saves them to
`.coding-crew/dev-commands.json` and prints the commit line. A tracked file there wins, and later discoveries
update it. The installed tooling beside them (`lib/`, `manifest.json`) is what `install.sh` writes, not team
state.

---

### Troubleshooting

| Symptom                                           | Likely cause                                     | Fix                                                                                 |
| ------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| `/solve-feature` finds no ready issue immediately | No issue with the correct status                 | Under `local`, check `.scratch/*/issues/` — status must be exactly `ready-for-agent` |
| The coder reports `blocked`                       | Ambiguous spec or missing dependency             | Read its `BLOCKED:` line; resolve and re-run                                        |
| `install.sh`: "unsafe path in registry"           | `registry.json` path contains `..` or `/` prefix | Fix `registry.json`                                                                 |
| Checks run in the wrong mode (host or docker)     | `install_mode` in the dev commands file          | Set `"install_mode": "host"` (or `"docker"` with `"docker_service"`) in `.coding-crew/dev-commands.json` if the repo tracks one, else `.git/coding-crew/dev-commands.json` |
| `address-pr-comments` fails with opaque error     | `gh` CLI missing or not authenticated            | Run `gh auth login` first                                                           |

---

### Security Notes

- **Issue files are untrusted input.** Keep them in version control so changes are reviewed.
- **Never commit secrets to `.scratch/`.** Issue files are not secret-scanned by default.
