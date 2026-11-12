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
    │     ├── install_single_skill() — copy skills/<name>/ as committed (coding-crew-lib through its
    │     │                              scripts/<lib> links into lib/) → <skills dir>/<name>/, real directories only
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
      "deps": ["tdd", "dep-install", "coding-crew-lib"], // other skills, installed recursively; coding-crew-lib for any skill that runs a library
    },
  },
}
```

**Rules:**

- No versions: only the release (CHANGELOG / tag) has one, and `--update` reinstalls everything.
- A skill reaches shared code only through the `coding-crew-lib` skill, installed beside it, run as
  `<skill-dir>/../coding-crew-lib/scripts/<lib>/<file>` (a script: `$SELF/../../coding-crew-lib/scripts/<lib>/`), with
  `coding-crew-lib` in its `deps`; no other skill has a `scripts/<lib>`. Adding a library is
  `ln -s ../../../lib/<lib> skills/coding-crew-lib/scripts/<lib>`; `tests/rendered-tree.bats` checks the links.
- Skill and library names must match `[a-zA-Z0-9_.-]+` — used as filesystem path components.
- Skills listed under another skill's `deps` are installed with it. A skill no installed skill depends on is only installed by name or by a full install (`./install.sh [platform]`).
- `deps` match what the skill's text invokes: every skill its rendered SKILL.md or `references/` names is reachable through its `deps`, and every direct dep is named in its SKILL.md, `references/` or `scripts/`. `tests/skill-deps.bats` checks both; a mention that only points a person at another skill goes on its allowlist with a reason.

---

### The feature review

`/solve-feature` reviews its PR at most twice, after every ready issue has landed: a fresh subagent, which
may run the tests and its own experiments but leaves the repo as it found it, uses `crew-review` on the branch against `.coding-crew/solve-feature/spec.md` (the tracker's `spec` op: the PRD, then
each issue of the feature, whole) and writes one JSON report; `solve-feature.sh reviewed` discards whatever it changed in the tree
anyway and lists it under `Needs attention`. It asks what the spec asks for that the code lacks,
what a real run breaks, and which documented rule the diff breaks. A fresh subagent fixes every
finding with `tdd`; `solve-feature.sh fix` gates the fixes with the project's checks. When the first
review had a CRITICAL, HIGH or MEDIUM finding and the fixer changed something, `fix` prints
`review-again=yes` and the run reviews and fixes once more; the second fix is not reviewed again. What
the last round did not fix is listed under `Needs attention` in the PR body, which keeps the PR a draft.
Anything else a coder or the fixer says a person must do or decide is kept in the run's notes file,
`.coding-crew/solve-feature/notes-<slug>.json`, as soon as its work lands (so a stop's `result.json` has it, and the
stop names the file); `describe` renders it into the PR body's `Notes for a person` section, and `Needs attention`
names the section. A note holds the draft for the run that wrote it: the run ends `needs-attention`, and a person handles
it, then marks the PR ready themselves or re-runs, which counts it as an earlier note. The reviewer judges each coder's note on the code at HEAD: one it finds settled
moves to a `Settled by the review` section with its reason, where it no longer holds the draft. When a fixer note
stands (an earlier round's, or one a stopped run left), the fixer is handed it to keep, edit or drop, so the run keeps one fixer note. A
re-run turns the previous body's notes, settled notes and earlier notes into one `Earlier runs' notes` section,
copied verbatim (a note you deleted stays deleted, and your own text there is kept) as a record that holds no draft.

---

### Adding a New Skill

1. Create `skills/<name>/SKILL.md` (required). Add supporting files in the same directory as needed (`references/mocking.md`, `references/publish.md`, etc.).

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
- **Never edit between fragment markers** — edit `skills/_shared/fragments/<key>.md`, then run `bash scripts/render-skill.sh` and commit what it rewrites; a hand edit there drifts from the source, and `tests/rendered-tree.bats` fails on it. Edit a library under `lib/<lib>/` and the links follow: `coding-crew-lib`'s `scripts/<lib>` is a committed link to it.

---

## Part 2: Using This Repo in Your Project

For developers who have installed the skills into their project and want to use them day-to-day.

---

### Install

#### `npx skills add`

From inside the repo:

```bash
npx skills add ypxing/coding-crew --all      # this project (writes skills-lock.json: commit it)
npx skills add ypxing/coding-crew --all -g   # user level
```

The project install also writes `.agents/skills/`, `.claude/skills/` and `agent/skills/` (link dirs for agents
that create their own project dir). The tool sends telemetry to
skills.sh unless `DISABLE_TELEMETRY` is set. To update, re-run the same command; `npx skills update` misses
changes inside the skills' library directories. An install of only some skills (`-s <name>`) needs
`-s coding-crew-lib` too: every skill runs its scripts from it.

#### `bootstrap.sh`

A curl-pipe install without a clone: it downloads `main`'s archive and runs its `install.sh`, which adds the
per-platform config-dir relocation in the table below and a warning when user-level copies shadow a project
install. For a pinned or offline install, run `./install.sh` from a clone instead:

```bash
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash                             # every platform, into $HOME
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude             # one platform
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- claude --project   # this project only
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/bootstrap.sh | bash -s -- --update           # update an install
curl -fsSL https://raw.githubusercontent.com/ypxing/coding-crew/main/unbootstrap.sh | bash                           # uninstall
```

`bootstrap.sh` takes the same arguments as `install.sh`. Needs `bash` 4+, `git`, `jq`, `curl` and `tar` (on Windows, use WSL2).
A checkout of this repo needs symlink support: on Windows, use WSL2.

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

#### Which agents

The skills are plain [Agent Skills](https://agentskills.io): any agent that loads `SKILL.md` runs them. The
`codex` target is the shared `.agents/skills` / `~/.agents/skills` location, not Codex alone: Codex, Copilot,
pi, Cursor, Gemini CLI, OpenCode, Amp, Devin, Cline, Goose, Factory, Junie, Zed, Augment, Warp, Qwen Code, Kimi,
Mistral Vibe, Crush, Kilo, Hermes, Codebuff, Rovo Dev and Zencoder read it. Claude Code, Kiro and Continue read
only their own directories, which `npx skills` targets. The release smoke runs on Claude Code; Copilot CLI,
Codex CLI and pi are supported too.

Runtime requirements:

- **Node.js on `PATH`** for the skills that touch the issue tracker — `/to-issues`, `/to-prd`, `/solve-issue`,
  `/solve-feature` and `/upgrade-deps`. They reach the tracker (local or GitHub) through the tracker CLI,
  `<skill-dir>/../coding-crew-lib/scripts/tracker/cli.mjs`, in the `coding-crew-lib` skill installed beside them (a link into `lib/` in this repo, a real directory once installed).

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
`rm -rf <root>/.coding-crew/{agents,code-review,crew-afk,dep-install,scripts,skills,solve-issue,to-issues,tracker,write-pr}`.

An install whose skills link into `.coding-crew/lib` updates with `--update` first: a partial run (`--skill`, one
platform of several, `uninstall.sh --skill`) removes that directory too, and the skills it left alone stop with
"re-install coding-crew" until `--update` reinstalls them.

#### What lands where

At project level (`--project`), with claude; a user-level install writes the same under `~`. The unmarked skills
come with `solve-feature`:

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
│       ├── setup-coding-crew/
│       ├── configure-tracker/
│       ├── crew-afk/               ← installed with "all"
│       ├── address-pr-comments/    ← installed with "all"
│       ├── add-tests/              ← installed with "all"
│       ├── upgrade-deps/           ← installed with "all"
│       ├── crew-brainstorm/        ← installed with "all"
│       ├── crew-grill/             ← installed with "all"
│       ├── crew-triage/            ← installed with "all"
│       ├── domain-modeling/        ← installed with "all", and with crew-grill
│       ├── to-issues/              ← installed with "all", and with crew-grill, crew-brainstorm or crew-triage
│       └── to-prd/                 ← installed with "all", and with to-issues
└── .coding-crew/
    ├── config.json                 ← your settings; `tracker` picks the issue tracker
    └── manifest.json
```

A user-level install never writes `~/.coding-crew/config.json`; you write it (or configure-tracker does, at user
level) to hold defaults for every project, which a project's own `.coding-crew/config.json` overrides value by value.

The `coding-crew-lib` skill's `scripts/<lib>/` is the one installed copy of each library (`tracker/` with its docs,
`checks/`, `git-workflow/`), copied through the committed link into `lib/`; every other skill runs it from there. A
reinstall removes the per-skill `scripts/<lib>` copies an older install wrote. A gitignored project install reaches a worktree only through `.worktreeinclude`.

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

A feature is a slug and the issues filed under it. Where they live depends on the tracker: the project's
`.coding-crew/config.json` `tracker` section, else the user-level `~/.coding-crew/config.json`'s, else `local`:

- **github** — one root issue whose body carries a column-0 `Feature: <slug>` line (the feature's
  `PRD:` issue, or for a single-slice feature the work issue itself), and every other issue a native
  sub-issue of that root.
- **local** — a directory, `.coding-crew/scratch/<slug>/`: an optional `PRD.md`, and the issues as
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

`/crew-triage <issue-ref>` on a `needs-triage` issue triages it unattended: it is built when complete enough, and gets an
`## Open questions` comment to settle with `/crew-grill #<n>` when not.

**What `next` and `land` read.** The feature is found by its slug — the `Feature:` line on github, the
directory on local. `next` picks an open `ready-for-agent` issue (not `blocked`) whose every blocker
is done; `land` asks `next` again after the coder, and an issue still first was not closed. On github
the blockers are the body's `## Blocked by`; on local they come only from `issues-deps.json`, which
`publish-issues` and `rewrite` write: an issue with no entry there has no blockers, so editing
`## Blocked by` by hand changes no dispatch order (solve-issue's preflight still refuses an issue whose
own `## Blocked by` names an open one). The status, the blockers and
the `Feature:` line are all they read, so an issue missing one of them is never found or never starts.

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
the tracker doc every install ships beside the tracker CLI: `coding-crew-lib/scripts/tracker/docs/<kind>.md`
in the directory the coding-crew skills are installed in.

---

### Running a feature

```
/solve-feature <feature-slug>
```

It runs the feature's `ready-for-agent` issues in order on one branch (one named after the slug unless you
pass `--branch <name>`), each by a fresh coder subagent, and lands each one only when the project's
checks pass. Then it reviews the whole feature and fixes the findings, at most twice: it reviews again
only after fixing a CRITICAL, HIGH or MEDIUM finding. It writes the PR body and marks the draft PR ready
when nothing needs a person. The body opens with a line saying solve-feature (naming the feature slug) wrote
the PR with agents, so nobody reads it as a person's words. Run it where an unattended agent may change the
checkout — a worktree or a container, not the one you work in. A stop names the step and how to
recover; a re-run skips the issues already done and reuses the branch and the PR, merging the default
branch into it first (a conflict there stops the run for you to merge by hand). Before the review it merges the
default branch in again, so the PR it marks ready does not conflict with it: a conflict there goes to a resolver
subagent, and the run stops on it only when the resolver leaves it unresolved; the merge is gated by the checks, so a check failing on the merged tree, or a refused push, stops the run too. Every run ends with one line in
`.coding-crew/solve-feature/outcome` for a host to read: `ready pr=<n>`, `needs-attention pr=<n>` (`ready branch=<b>`,
`needs-attention branch=<b>` when `solveFeature.publish` is `false`) or `stopped: <what> failed: <reason>`, `<what>` the subcommand that stopped (`start`, `next`, `sync`) or the issue ref or
`review` and its step (`2 checks`, `review fix`); no file means the run never finished. Beside it,
`.coding-crew/solve-feature/result.json` (schema: `skills/solve-feature/result.schema.json`) holds the same line with
its evidence, for a host that writes the PR itself: each issue's commits, checks and the lines its coder recorded for
each new test seen failing, each review round's findings, gaps, per-criterion tests, the findings its fixer left
unfixed (by index, with why) and whether a later round re-reviewed its fixes, and `needs_attention`: one typed item
per reason the run needs a person (an unmet spec, an unfixed finding, a note, open review threads), the same list
that holds the draft and renders the PR body's Needs attention, `[]` when the run ends ready.

| Setting | Effect |
| --- | --- |
| `--branch <name>` | The branch the run uses, never the default branch (default: one named after the slug) |
| `--review-since <sha>` | Scopes the review's findings to the commits since `<sha>` (a follow-up run's), while spec and gaps are judged on the whole code; used only when `<sha>` holds the default branch and is in the branch after `sync`'s merge, else the whole branch is reviewed. Not a commit: `start` stops |
| `.coding-crew/config.json` `solveFeature.models.coder` / `.reviewer` | The coder and fixer / reviewer subagent's model name, a family with an optional version (`opus`, `claude-opus-5-5`, `opus 5.5`): the host runs the subagent on the matching model in its own list, the closest of the same family when it lacks that version, its own model when it lacks the family. Read from `CREW_CODER_MODEL` / `CREW_REVIEWER_MODEL` when set and non-empty (a name for the one host where you set it: your shell, your agent CLI's settings `env`, or a CI host's environment), then the project's file, then `~/.coding-crew/config.json` for each key it lacks (a CI runner sees only the project's committed file), then the default (your own) |
| `~/.coding-crew/config.json` `solveFeature.publish` | `false` keeps the run on this machine: no `git push` and no PR; the branch is reviewed and fixed locally and the PR body, its title on the first line, is left in `.coding-crew/solve-feature/local-pr-<branch, / as _>.md` for you to push and open yourself. Read from the user-level file only, never the project's, so a run on a CI runner always pushes |

**Checks that modify files.** An auto-fixing lint (`make lint` running `--write`) can stay configured:
when a check rewrites tracked files, every check runs a second time, and if that pass changes nothing the
checks pass and the rewrites land as their own `Apply the checks' rewrites` commit. A check that rewrites
files on every run, or creates files git does not ignore, fails, and needs a non-mutating command in the
dev commands file (below).

**Unattended, in its own worktree.** `/crew-afk <feature>` starts that `/solve-feature` run for you
and returns at once. It resolves the feature from a likely name, then prepares (or reuses) one
worktree per feature outside your checkout, at `~/.coding-crew/worktrees/<repo-name>-<hash>/<slug>` (orca
picks its own path), linking each
`.worktreeinclude` entry and copying `.env` into it. The agent you ran `/crew-afk` in writes the
command that starts a session of its own CLI there, and crew-afk runs it as given.

| `--to` | Where the run goes |
| --- | --- |
| `local` (default) | A detached headless session, capped at 1 hour; it logs to `<worktree>/.coding-crew/solve-feature/run.log` (needs `timeout`, on macOS `brew install coreutils`) |
| `orca` | An orca-managed worktree and an interactive agent in an orca terminal, uncapped: you watch and steer it |
| `herdr` | An interactive agent in a new herdr pane on the worktree, uncapped |

`/crew-afk status [<feature>]` prints each run's outcome line (`ready pr=<n>`, `needs-attention pr=<n>`,
their `branch=<b>` forms or `stopped: …`), `running (pid <n>)`, or why there is none — for a local run that ended without one,
`re-run /crew-afk <slug> to continue` (a re-run skips the issues already done). For a local run whose
command printed a JSON result with a cost as its last line, the outcome line ends with what the run cost
and how long it took: `ready pr=7 cost=$1.73 (23 min)` (`cost=$<n> (<m> min)`); a run whose CLI prints
no such line, or that the 1h cap killed, has none. `/crew-afk wait <feature>` on a local run
returns once its process is gone, not at the outcome, so its line carries the cost too. A second `/crew-afk` on a feature whose run is still going is refused, on every destination: it
names the run's pid, herdr pane or orca terminal, to wait for or close. An orca or herdr run whose terminal closed with
no outcome reports as ended, with the re-run to continue.
Nothing removes a worktree: `git worktree remove <path>` once you are done with it.

---

### Embedding solve-feature

A host that owns the spec, the branch, the push, the PR and the verdict (a CI job with read-only tokens, say) runs
solve-feature as its build-review-fix step on one spec file, with no tracker set up and no config file written:

```bash
CREW_PUBLISH=false CREW_TRACKER=local CREW_COMMANDS_FILE=/runner/dev-commands.json \
  claude -p "/solve-feature --spec /runner/spec.md --issue 13 --branch agent/13"
```

- `--spec <file> --issue <n>` builds the file as the one-issue local feature `issue-<n>` (commits `[01-issue-<n>]`),
  rebuilt from the file on every run. The file's first `# ` line is the issue's title; its `## Blocked by` section is
  dropped. Keep the file outside the checkout: an untracked file inside it stops the run as a dirty tree does.
  `--branch` and `--review-since` work as for any feature.
- `CREW_PUBLISH=false` — no `git push` and no `gh pr` call; the host pushes the branch and opens the PR itself.
- `CREW_TRACKER=local` — every process of the run uses the local tracker, whatever the repo's committed
  `.coding-crew/config.json` says. `--spec` stops without it on a repo whose tracker is `github`.
- `CREW_COMMANDS_FILE` — the dev commands file every check reads and writes, in place of the repo's; keep it outside
  the checkout, where a coder cannot commit it. One that is not writable is never rewritten: discovery stops instead.
  A keyed check may be slower than its raw command (a host's may go through a broker and run in containers): that is
  expected, and no reason to fall back to raw commands.
- `CREW_CODER_MODEL` / `CREW_REVIEWER_MODEL` — the coder and fixer / reviewer model, ahead of any config.

When the run ends, `.coding-crew/solve-feature/result.json` (schema: `skills/solve-feature/result.schema.json`) holds
what a host renders, with no prose to parse. The fields below are stable: a host may rely on them, and a release only
adds to them. `tests/fixtures/solve-feature/result.example.json` is the contract's example, every field filled in and
checked against the schema by the result tests; copy it as a host's own fixture.

| Field | What it is |
| --- | --- |
| `status` | `ready`, `needs-attention` or `stopped`: the outcome line's first word |
| `outcome` | The outcome line, verbatim |
| `pr` | The PR's number; absent with `CREW_PUBLISH=false` or before a PR exists |
| `pr_text` | The PR writer's `{title, why, changes, risk}`, `changes` a list of strings; absent when the writer left no valid JSON |
| `pr_title`, `pr_summary` | The PR writer's title and summary (Why, What changes, Risk) as the body carries it, rendered from `pr_text` when present, with no `**Tested:**` line, banner or Needs attention; present once the writer has run |
| `issues[].title`, `issues[].checks.results` | Each spec issue's title, and the checks its land ran (`null` checks when this run did not land it) |
| `rounds[].spec`, `rounds[].gaps` | That review's spec verdict (`met`, `unmet`, `none`) and its gaps |
| `rounds[].findings[]` | `severity`, `location`, `issue`, `fix`, and `fixed`: whether that round's fixer fixed it, absent when that cannot be told (the fix stopped, or the fixer's list named no finding) |
| `rounds[].criteria[]` | `text`, `met` and `tests[]` of `{test, red}`: each criterion the reviewer judged, its tests and the red line of each |
| `rounds[].checks` | Each check key of that round's gate and its result; the last round's are what the PR body's script-written `**Tested:**` line lists |
| `rounds[].re_reviewed` | Whether a later round reviewed that round's fixes |
| `needs_attention[]` | One typed item per reason the run needs a person: `type` is `note`, `unfixed`, `spec_unmet`, `reviewer_changed_tree` or `fixer_changed_nothing`, with `author`, `round`, `finding`, `why`, `gaps`, `paths`, `text` and `severity` as the type has them |

coding-crew's own verdict holds the draft on any `needs_attention` item. A host with its own ready bar computes it
from the file, with the severities as arguments: the unfixed severities it counts as notes, and the fixed severities
that need a later review. Save this filter as `ready.jq`:

```jq
(.rounds[-1] // {}) as $last
| .status != "stopped"
  and all(.needs_attention[];
        .type == "note" or (.type == "unfixed" and (.severity as $s | any($note_severities[]; . == $s))))
  and ($last.re_reviewed != false
       or all(($last.findings // [])[];
              .fixed != true or (.severity as $s | any($review_severities[]; . == $s) | not)))
```

```bash
ready=$(jq -r -f ready.jq --argjson note_severities '["LOW"]' --argjson review_severities '["CRITICAL","HIGH"]' \
  .coding-crew/solve-feature/result.json)
body=$(jq -r '.pr_summary // ""' .coding-crew/solve-feature/result.json)
git push origin HEAD
gh pr create --draft --title "$(jq -r '.pr_title // "agent change"' .coding-crew/solve-feature/result.json)" --body "$body"
[ "$ready" = true ] && gh pr ready
```

---

### PR rework

Run `/address-pr-comments` yourself on the PR. On a solve-feature PR it files the accepted comments as one `ready-for-agent` issue of the PR's feature and runs `/solve-feature` on the PR's branch, which fixes, checks and reviews it like any other issue and, in its describe step, marks the PR ready unless something needs a person (listed under `Needs attention` in the PR body); it then replies `Fixed in <sha>` on each accepted thread, or re-opens the threads when the run stopped. It never edits or pushes code itself there. On any other PR it fixes the comments and commits, but does not push; run non-interactively by a host (`Use the address-pr-comments skill on PR #<n>; this run is non-interactive`), it first stops unless the checkout is at the PR's head, and it also pushes that commit to the PR's head branch, never forcing, then replies `Fixed in <sha>` and resolves each fixed thread. A refused push leaves those threads open and the commit local, and the summary quotes git's reason. A thread left for a person @mentions the PR's author. How such a run starts is the host's.

Which comments reach the agent: only those by Copilot's reviewer, by the identity the agent posts as (`github-actions` on a GitHub runner, only for a comment GitHub reports a Bot wrote), by a bot the
repo lists under `github.trustedBots` in `.coding-crew/config.json`, or by a user with write, maintain or admin
permission on the repo. GitHub reports no permission for a bot, so a GitHub App's comments (Wiz's, say) reach the
agent only when listed: `{"github": {"trustedBots": ["wiz-security-bot-0123456789"]}}`, its login with or without
`[bot]`, matched exactly, and only for a comment GitHub's GraphQL reports a Bot wrote (a user who takes the bot's name is checked like any user). The key is read from the project's file only, never `~/.coding-crew/config.json`, applies
to this repo's PRs only and only while the repo is private or internal (on a public one anyone could make a listed
bot quote their text to the agent). A round reads the PR's reviews, comments and threads through
coding-crew-lib's `pr-comments.mjs`, and `fetch --comments` reads an issue's, both dropping everyone else's comments
(a failed permission check counts as no access) and naming the omitted authors in one line; an outsider's reply
on a thread the agent answered does not reopen it, though its open thread still keeps the PR under Needs attention
until a person resolves it. Issue and PR bodies are not filtered: running a feature trusts its issues' bodies, so read
them first.

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

**The light path.** `/crew-grill` and `/crew-brainstorm` first judge whether the source (an issue or your message) is already one complete change: the problem is stated with its cost or evidence, one slice is likely, the acceptance criteria are testable or derivable from the code, and no open fork would annoy you if decided for you. Each check is answered with a quote or `file:line`. If all hold they print one `Light path:` line and invoke `/to-issues` with no question; if any check does not hold they go straight to their questions and print nothing about the light path. `/to-issues` alone decides whether a PRD is written: one slice publishes (or rewrites the source issue in place) with its own `## Decisions` section and no PRD, its slug derived from the github issue's `Feature:` line, the `.coding-crew/scratch/<slug>/` directory or the title and shown in the quiz for you to override; two or more slices, or two or more origin issues, invoke `/to-prd` first.

---

### Customising the Tracker

Edit these files after install — they override the defaults on the next run:

| File                                           | Purpose                                         |
| ---------------------------------------------- | ----------------------------------------------- |
| `.coding-crew/config.json` (`tracker` section) | Where issues live: `{"tracker": {"kind": "github"}}` (default `local`) |
| `~/.coding-crew/config.json` (`tracker`, `solveFeature.models`, `solveFeature.publish`) | Your defaults for every project, same format; `solveFeature.publish` is read from this file only |

Each value is looked up on its own: the project's `.coding-crew/config.json` (for the tracker, then a legacy
`.coding-crew/docs/issue-tracker.md`), then `~/.coding-crew/config.json`, then the default. A broken user file
stops every tracker op with its path, even where the project sets the tracker. The github tracker creates its
status labels itself, before it first applies one.

Commit `.coding-crew/config.json`: it is team state — the tracker choice and solve-feature's models —
that everyone using the repo needs, so do not add it to `.gitignore`. A CI runner and your teammates see only
the project's committed file, never your `~/.coding-crew/config.json`, so team settings belong in the project's.
Runs read the main checkout's copy before it is committed, from every worktree, so you can try a setting first and
commit it once satisfied.

**The dev commands file** holds the project's checks (`test`, `lint`, `typecheck`, …), its install
command and its install mode (`install_mode`: `host` or `docker`, with `docker_service`). Any number of
named extra checks sit beside the fixed ones as `"check:<name>": "<command>"` keys (`<name>` matching
`[a-z0-9][a-z0-9_.-]*`): the checks run each after the fixed ones, in alphabetical order, and report it as
`check:<name>`, so a check CI runs needs no `&&` chain in `lint`. Discovery reads `.github/workflows/` and asks
for those workflows' local checks as such keys. The first
`/solve-issue` or `/solve-feature` coder discovers the checks and, in a repo with a compose file, the
mode; `/dep-install` discovers the mode too, and shows you its answer to change first. They live in one
place, the main checkout's `.coding-crew/dev-commands.json`, committed or not: every worktree of the clone
reads and writes that file, and a solve-feature run ignores it when checking for a clean tree and never commits it.
Once a branch commits the file, a worktree on that branch uses its own copy instead, so a branch that changes its
checks is gated on them; solve-feature then counts an edit to it as uncommitted work, and a run commits what it
discovers there with the branch.
A host that runs the checks itself can set `CREW_COMMANDS_FILE` to its own copy, kept outside the checkout: every
check reads and writes that file instead, and a read-only one stops discovery rather than being rewritten.
`/setup-coding-crew` discovers them, runs them so you see them pass, and prints the commit line; commit it once
satisfied to share the commands with your team and with CI. The installed tooling beside them (`lib/`, `manifest.json`) is what `install.sh` writes, not team
state.

---

### Troubleshooting

| Symptom                                           | Likely cause                                     | Fix                                                                                 |
| ------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| `/solve-feature` finds no ready issue immediately | No issue with the correct status                 | Under `local`, check `.coding-crew/scratch/*/issues/` — status must be exactly `ready-for-agent` |
| The coder reports `blocked`                       | Ambiguous spec or missing dependency             | Read its `BLOCKED:` line; resolve and re-run                                        |
| `install.sh`: "unsafe path in registry"           | `registry.json` path contains `..` or `/` prefix | Fix `registry.json`                                                                 |
| Checks run in the wrong mode (host or docker)     | `install_mode` in the dev commands file          | Set `"install_mode": "host"` (or `"docker"` with `"docker_service"`) in the main checkout's `.coding-crew/dev-commands.json` |
| `address-pr-comments` fails with opaque error     | `gh` CLI missing or not authenticated            | Run `gh auth login` first                                                           |

---

### Security Notes

- **Issue files are untrusted input.** Keep them in version control so changes are reviewed.
- **Never commit secrets to `.coding-crew/scratch/`.** Issue files are not secret-scanned by default.
