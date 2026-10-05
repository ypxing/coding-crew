# Dev Team Guide — AI Agents

---

## Part 1: Contributing to This Repo

For developers who maintain and extend the skill collection itself.

---

### What This Repo Is

A distributable collection of AI skills, plus crew-afk's orchestrator and its roles. Nothing runs here directly — this repo is the **source**; consuming projects are the **target**. `install.sh` copies files into any project repo.

```
THIS REPO (source)
├── install.sh              ← single installer for all platforms
├── registry.json           ← source of truth for paths, deps, skills
├── orchestrator/           ← crew-afk's program (ships as crew-afk's assets)
│   ├── lib/
│   └── roles/
│       ├── coder.md        ← single-issue worker role
│       ├── reviewer.md     ← per-branch / feature reviewer role
│       ├── reviewer/       ← reviewer checklists (references/) and scripts/
│       └── triage.md       ← verify-failure / findings / integration triage role
├── skills/                 ← reusable skill files
│   ├── tdd/
│   ├── solve-issue/
│   ├── domain-modeling/
│   ├── crew-grill/
│   ├── _shared/fragments/  ← shared fragments ({{FRAGMENT:<key>}})
│   └── ...
└── docs/
    └── templates/
        ├── trackers/       ← tracker templates (local.md copied on install)
        └── workflows/      ← optional GitHub Actions workflows
```

---

### How Install Works

`install.sh` reads `registry.json` and copies files into `TARGET_REPO` (defaults to the calling project's git root).

```
install.sh
    │
    ├── read registry.json
    ├── for each requested skill (every skill when none is named):
    │     ├── install_single_skill() — render skills/<name>/ → .claude/skills/<name>/
    │     ├── install_skill_assets() — cp assets.source → assets.dest (e.g. orchestrator/ → .coding-crew/crew-afk/)
    │     └── install_single_skill(dep) — recurse for each dep
    │
    └── install_docs()  — docs.templates (skip if exists), docs.scripts (always overwritten)
```

#### Roles, not agent files

There are no agents. crew-afk's three roles — coder, reviewer, triage — are protocols under `orchestrator/roles/` (`coder.md`, `reviewer.md` with `reviewer/{references,scripts}`, `triage.md`). They ship with the orchestrator as crew-afk's `assets`, so they install to `.coding-crew/crew-afk/roles/`; a crew-afk install also copies `skills/_shared/fragments/` to `.coding-crew/skills/_shared/fragments/`. The orchestrator renders a role's protocol per dispatch (`orchestrator/lib/adapters/render.mjs`, expanding `{{FRAGMENT:<key>}}` lines and `{{PLATFORM}}`) and hands it to the platform CLI through that platform's adapter (`orchestrator/lib/adapters/<platform>.mjs`). No per-platform agent file is written under `.claude/agents`, `.github/agents`, `.pi/agents` or `.codex/agents`: a crew-afk install (and `uninstall.sh`) removes the ones an older install wrote, by exact path (`retired-agents` in `registry.json`), along with `.coding-crew/agents/` and `.coding-crew/code-review/`.

---

### Registry Structure

`registry.json` is the single source of truth. Every skill entry must be here.

```jsonc
{
  "skills": {
    "<name>": {
      "version": "1.0.0",
      "description": "...",
      "install": ".claude/skills/<name>", // destination dir in target repo
      "install-codex": ".agents/skills/<name>", // optional per-platform override
      // With no override, the Claude path is reused with .claude/ swapped for
      // .<platform>/ — except codex, which resolves to .agents/skills/<name>.
      "deps": ["tdd", "dep-install"], // other skills, installed recursively
      "assets": { "source": "orchestrator", "dest": ".coding-crew/crew-afk" }, // optional runtime files
    },
  },
  "retired-agents": {
    // agent files older installs wrote; a crew-afk install and uninstall.sh remove them
    "names": ["crew-coder", "crew-reviewer", "crew-triage", "crew-code-reviewer"],
    "paths": { "claude": ".claude/agents/{name}.md", "...": "..." },
    "dirs": [".coding-crew/agents", ".coding-crew/code-review"],
  },
  "docs": {
    "templates": {
      "<key>": {
        "source": "docs/templates/trackers/local.md",
        "dest": ".coding-crew/docs/issue-tracker.md", // skipped if it already exists
      },
    },
    "scripts": {
      "<key>": {
        "source": "scripts/tracker/mark-issue-done.sh",
        "dest": ".coding-crew/scripts/mark-issue-done.sh", // always overwritten, chmod +x
      },
    },
  },
}
```

**Rules:**

- Paths must be relative and must not contain `..` or a leading `/` — `install.sh` rejects them.
- `docs.templates` entries are user-customisable text and are **never** overwritten or uninstalled.
  `docs.scripts` entries are mechanism (a tracker operation's implementation), so they are always
  overwritten on install and removed on uninstall — a stale copy would be a gate that no longer
  matches the operation calling it.
- Skill names must match `[a-zA-Z0-9_.-]+` — used as filesystem path components.
- Skills listed under another skill's `deps` are installed with it. A skill no installed skill depends on is only installed by name or by a full install (`./install.sh [platform]`).

---

### The feature review

At every drain of the queue where something merged, the feature is reviewed across its issues. The first review's range is the whole feature, from the merge-base with origin's default branch (else the local one), whichever run made each commit. It is skipped when the integration check is red, or when the wall-clock cap stopped claims with a claimable issue left. The tip it reviewed is recorded as `feature_review.reviewed_tip` in `sprint-state.json`; on a later run an unchanged tip dispatches no reviewer ("nothing new since <sha>"), and a tip that descends from it is reviewed only for the commits added since, leaving out what merged in from origin's default branch. A rewritten history (`reviewed_tip` not an ancestor) gets the whole-feature review again. Findings are promoted into Phase 2 (by `fixFindings`) into one fix issue per feature, holding the 8 most severe (CRITICAL→LOW; the rest stay open, report-only) — counted per feature in `sprint-state.json` (`feature_review.promotions`, advanced only when a review created the fix issue), so a later run promotes nothing; later reviews are report-only (the promotion cap): no fix issue, the findings reach the review report and the summary, and each one the rule would have promoted keeps an `--open-pr` PR a draft. To keep LOW findings out of fix issues altogether, set `fixFindings: medium`. Findings an earlier drain raised and later ones do not repeat stay in the `feature` block, marked as earlier.

A whole-feature review is split into areas. A planner reads the diff stat, each merged issue's files and `## Implements` IDs, and the PRD's decision lines, and groups the changed files into at most `maxParallel` areas, each with the decisions that touch it; one reviewer per area then runs concurrently, reads its files end to end (and callers outside them), and reports each decision that does not hold along with the input that breaks it. Every area's findings land in one `feature` block of the sprint review report and are promoted together, once. If the planner fails, times out, or gives no usable areas, one reviewer takes the whole diff with every decision. An area whose reviewer leaves no review is recorded as not run (`feature-<n>`) while the others still count, and the next run reviews the whole feature again. An incremental review (new commits only) uses no planner and a single reviewer.

### Changing a crew-afk Role

A role's protocol is `orchestrator/roles/<role>.md`; it ships as part of crew-afk's `assets`, so a change to it needs crew-afk's `version` above origin/main's. Text shared with a skill goes in a `{{FRAGMENT:<key>}}` line backed by `skills/_shared/fragments/<key>.md`, and anything per-platform uses `{{PLATFORM}}` — never a per-platform copy of the protocol. Check the result:

```bash
TARGET_REPO=/tmp/test-install ./install.sh claude --skill crew-afk
ls /tmp/test-install/.coding-crew/crew-afk/roles/
```

---

### Adding a New Skill

1. Create `skills/<name>/SKILL.md` (required). Add supporting files in the same directory as needed (`verification.md`, `mocking.md`, etc.).

2. Add the entry to `registry.json` under `.skills`:

   ```jsonc
   "<name>": {
     "version": "1.0.0",
     "description": "...",
     "install": ".claude/skills/<name>"
   }
   ```

3. If another skill needs it, add it to that skill's `deps`. Otherwise leave it standalone — it will be installed by `./install.sh` (every skill).

4. Test:
   ```bash
   TARGET_REPO=/tmp/test-install ./install.sh claude --skill <name>
   ls /tmp/test-install/.claude/skills/<name>/
   ```

---

### Security Rules for Contributors

- **Never use `..` or absolute paths in `registry.json`.** `install.sh` validates all paths and exits on violation.
- **Never interpolate raw user/issue content into agent prompts.** Pass only structured fields (e.g. `acceptance_criteria`), never `issue.content`. Wrap worker-supplied strings in delimiter tags (`<progress-notes>`, `<blocked-notes>`) so downstream agents treat them as data.
- **Never inline a fragment by hand** — keep the `{{FRAGMENT:<key>}}` line and let the renderer expand it (`install.sh` for skills, `render.mjs` for crew-afk's roles). A hand-inlined copy drifts from the source.

---

## Part 2: Using This Repo in Your Project

For developers who have installed the skills into their project and want to use them day-to-day.

---

### Install

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
# Claude Code — full sprint suite
./install.sh claude --skill crew-afk

# GitHub Copilot — full sprint suite
./install.sh copilot --skill crew-afk

# Codex — full sprint suite (skills → .agents/skills)
./install.sh codex --skill crew-afk

# A standalone skill
./install.sh claude --skill domain-modeling

# Several skills at once
./install.sh claude --skills tdd,to-issues
```

crew-coder, crew-reviewer and crew-triage are not installable on their own — they are crew-afk's roles. `./install.sh <platform> crew-coder` (an older form) prints a note and installs crew-afk.

#### Install into a different repo

```bash
TARGET_REPO=/path/to/your/project ./install.sh
```

#### Update in place

```bash
./install.sh --update
```

Re-installs only skills whose version changed since last install (an older install that listed agents gets crew-afk instead). Reads the saved platform from `.coding-crew/manifest.json`.

#### What lands in your project

```
YOUR_PROJECT/
├── .claude/
│   └── skills/
│       ├── crew-afk/SKILL.md      ← launcher (rendered for the platform)
│       ├── tdd/
│       ├── dep-install/
│       ├── solve-issue/
│       ├── crew-address-findings/
│       ├── address-pr-comments/    ← installed with "all"
│       ├── domain-modeling/   ← installed with "all"
│       ├── to-issues/         ← installed with "all"
│       ├── to-prd/            ← installed with "all"
│       └── crew-grill/              ← installed with "all"
└── .coding-crew/
    ├── crew-afk/                   ← the orchestrator crew-afk runs
    │   └── roles/                  ← coder, reviewer, triage protocols
    ├── skills/_shared/fragments/   ← fragments the roles render with
    ├── docs/issue-tracker.md       ← edit to match your tracker
    ├── scripts/                    ← tracker helper scripts
    └── manifest.json
```

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
 │  /crew-grill             (interview → approaches → PRD → issues)  │
 │  /crew-grill with docs   (crew-grill + CONTEXT.md + ADRs)         │
 └──────────────────────────┬────────────────────────────────────────┘
                            │ .scratch/.../issues/*.md
                            ▼
 /crew-afk (you trigger this)
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│  crew-afk orchestrator                                      │
│  1. List "ready-for-agent" issues from .scratch/            │
│  2. Dispatch coder-role workers — up to 8 in parallel       │
│  3. Validate output, merge complete branches                │
│  4. Write progress / blocked notes, loop                    │
│  5. Run the reviewer role on exit                           │
└────────────────────┬────────────────────────────────────────┘
                     │ isolated git worktrees
          ┌──────────┴──────────┐
          ▼                     ▼
    ┌───────────┐         ┌───────────┐
    │   coder   │   ...   │   coder   │
    │ (1 issue) │         │ (1 issue) │
    └───────────┘         └───────────┘
          │ branches merged
          ▼
    ┌──────────────────────┐
    │  reviewer role       │  advisory findings → .scratch/reviews/
    └──────────────────────┘
          │
          ▼
    /crew-address-findings (you trigger this)
```

---

### Issue Lifecycle

```
 needs-triage  →  /to-issues <ref>  →  ready-for-agent  →  coder picks up
                                                              │
                                           ┌──────────────────┼──────────────┐
                                           ▼                  ▼              ▼
                                        complete           partial         blocked
                                           │                  │              │
                                      merge + close     ## Progress     ## Blocked
                                        done/           next round      human fixes
```

`/to-issues <ref>` checks the issue against the design standard and rewrites it in place when it is
one slice, or splits it into child issues with `## Parent`. Auto-promoted fix issues skip the check:
they carry a column-0 `Source:` line — `Source: review (<branch>)` first under `github`,
`Source: <report> (<branch>)` after the title and `Status:` lines under `local`.

---

### Writing Issues

Create files under `.scratch/<feature>/issues/NN-slug.md`:

```markdown
Status: ready-for-agent

## What to build

One paragraph — describe the end-to-end behavior, not layer-by-layer steps.

## Acceptance criteria

- [ ] Criterion one
- [ ] Criterion two

## Blocked by

- 01-prior-issue.md ← or: None - can start immediately
```

Use `/to-prd` → `/to-issues` to generate these from a feature description automatically.

---

### Running the Sprint

**Claude Code:**

```
/crew-afk
```

**Copilot:** run `/crew-afk` (the skill).

**pi / Codex:** run `crew-afk` (workers are dispatched as separate `pi -p` / `codex exec` processes).
Both require the respective **local CLI** on `PATH` — a sprint spawns background child processes
against a local git clone. The hosted Codex surfaces (Codex in ChatGPT, Codex cloud/web) cannot run
this sprint: no parent process to `wait` on, and no persistent working root for per-issue worktrees
or dispatch report files.

Sprint runs until all issues are complete, or every remaining issue is blocked — either it has spent its two retry attempts, or it depends on one that has (stall). On exit it saves a code review report to `.scratch/reviews/sprint-review-<timestamp>.md`.

---

### Configuring crew-afk

**Model tier** — `/crew-afk --model opus|sonnet|haiku|inherit` (default `sonnet`). The reviewer and
triage judge run on the same model as the coder unless you name another, so the review standard
doesn't silently drop. Applies on every platform, including Copilot — each worker is its own
`copilot -p` process, so the flag reaches the CLI.

**Per-role runtime and model** — `.coding-crew/config.json` can put any role (`coder`, `reviewer`,
`triage`, `commandFinder`, `prWriter`) on another installed runtime, and name models per runtime:

```json
{ "afk": { "runtime": { "reviewer": "codex" },
           "models":  { "claude": { "triage": "opus" }, "codex": { "reviewer": "gpt-5.1-codex" } } } }
```

A model is only ever passed to its own runtime's CLI. A role moved to another runtime doesn't
inherit the coder's model; with none named under that runtime, it takes `--model` if one was given
and it's on the `--platform` runtime, else `sonnet` on claude, else the CLI's own default. Each
runtime a role uses must be installed (`./install.sh codex --skill crew-afk`); `crew-afk doctor`
checks. `config.json` holds only settings you write; an older `.coding-crew/afk-models.json` is
moved into it on the next run.

It's read at two levels: `~/.coding-crew/config.json` for this machine, under the repo's
`.coding-crew/config.json` for the team. They merge per setting, the repo's winning, and
`crew-afk plan` tags each value with the file it came from. Keep the repo's file to aliases, since
it's committed. Provider-specific IDs belong at user level, or in env such as
`ANTHROPIC_DEFAULT_SONNET_MODEL`, which every dispatch inherits.

**Sprint settings** — the same `afk` section holds the rest of what stays the same run to run. A
flag overrides each for one run. The PRD audit is gone — the feature review checks PRD coverage —
and a config or flag still setting it loads with a notice:

| Setting | Default | Flag | What it does |
| --- | --- | --- | --- |
| `fixFindings` | `actionable` | `--fix-findings` | What review findings are fixed automatically: `actionable` (every finding the triage role judges Actionable, whatever its severity); or the lowest severity — `critical`, `high`, `medium`; or `none` |
| `timeouts` | coder 45, reviewer 20, triage 20, commandFinder 5, prWriter 10, merge 5 | `--coder-timeout`, `--reviewer-timeout` | Minutes, per role (at most 35791); name only the ones you change. A coder that times out after committing is retried without spending an attempt, up to 3 dispatches per issue |
| `maxParallel` | the coder runtime's | `--max-parallel` | Concurrent coders — usually a machine setting, so user level |
| `maxWallMinutes` | `120` | `--max-wall` | Soft wall-clock cap in minutes, `0` = off. Once elapsed no issue is claimed, running workers finish and merge, Phase 2 fix issues stay parked, the integration check still runs; exit 2, PR (with `--open-pr`) is a draft |
| `installDeps` | `true` | `--no-deps` | Install dependencies in each worktree |
| `squashCommits` | `false` | `--squash` (`--no-squash` turns it off) | Squash the sprint's commits into one at the end. Each issue is merged as its own commit either way |
| `openPr` | `false` | `--open-pr` (`--no-open-pr` turns it off) | At the end, push the feature branch and create or update its PR. The `prWriter` role writes the title (else the PRD's; an open PR keeps a title you set) and the body by following `write-pr` (Summary, Evidence, Merge Danger), under which go the checks result on the merged branch and the lines closing the issues the sprint merged (under `tracker: github`). If the writer leaves no `## Summary`, the PR opens anyway and the run summary says why. A re-run rewrites only crew-afk's own block of the body |
| `baselineCheck` | `true` | `--no-baseline` | Run the checks once on the feature branch before any dispatch; stop if they fail, since every issue's verify would too |
| `integrationCheck` | `true` | `--no-integration-check` | Each time the queue drains (after the first pass and after the fix pass), run the checks once on the merged feature branch — two branches that pass alone can fail together. A red result gets an `## Integration check` section in the summary and keeps `openPr` from opening the PR; a pass is cached by commit. `--no-baseline` does not turn it off |
| `resumeCoderSession` | `false` | `--resume-coder-session` | On a fix round, continue the claude coder session that wrote the branch, if that session is under 100k tokens and the branch hasn't moved |
| `limits` | off | — | `{ "coder": { "usd": 5 } }`: a dollar cap on one dispatch of that role (claude's `--max-budget-usd`; other runtimes ignore it, with one notice per run). A dispatch that hits it blocks its issue as `limit-exceeded`, never retried |

**Checks that modify files.** A check that leaves the tree modified fails, in the baseline and every
verify alike, and in the integration check. An auto-fixing lint (`make lint` running `--write`) can stay configured: run it once
on the feature branch, commit what it rewrote, and re-run. Only a check that rewrites files on every
run needs a non-mutating command in `.coding-crew/dev-commands.json`.

**Per-issue requirements.** An issue can list what its checks need that the install doesn't
guarantee under `## Requires`, one backticked command per bullet (exit 0 = satisfied); each runs
once before that issue's first dispatch, and a failing one blocks that issue with the command's
output instead of paying for its coder.

**Uncommitted changes.** A run stops before any dispatch if tracked files in the main checkout have
uncommitted changes, because git refuses a merge that would overwrite them. `--allow-dirty` skips
that check for one run. A merge it then refuses blocks that issue as `main-tree-dirty`, and a
re-run after you commit or stash resumes at the merge.

**Gitignored files in worktrees.** Each coder runs in an isolated worktree, so `.env` and similar
files aren't there by default. List them in a `.worktreeinclude` file at your repo root to carry
them over. `.env` and `docker-compose.override.yml` are always carried over when they exist,
without being listed; crew-afk never writes `.worktreeinclude` itself.

**Worktree location.** Worktrees live under `.scratch/worktrees/` by default. Set
`afk.worktreeRoot` in either `config.json` (absolute, or relative to the repo root) to put them
elsewhere, or `CREW_WORKTREE_ROOT`, which wins over both. A path outside the repo, such as
`../<repo>-worktrees`, keeps tools that search parent directories (Node's `node_modules`
resolution, CLAUDE.md loading) from falling back to the main checkout. A path inside the repo isn't
covered by the default `.scratch/` gitignore entry; `crew-afk` warns until you add it.

---

### PR rework with GitHub Actions (optional)

Not installed by default. Without it, run `/address-pr-comments` yourself on the PR.

With it, reviewers comment on a PR labelled `crew-rework` as usual; the `crew-rework` GitHub
Action runs `/address-pr-comments --auto`, which fixes what is sensible, pushes, and replies on
every thread it handled. It never resolves a thread — you do.

**Setup**

1. Copy [`docs/templates/workflows/crew-rework.yml`](templates/workflows/crew-rework.yml) to
   `.github/workflows/` in your repo.
2. Install the skills per project and commit them (`./install.sh claude --skill
   address-pr-comments`): the runner has no `$HOME` install.
3. Add the repo secret `ANTHROPIC_API_KEY`.
4. Make sure your CI workflow is `ci.yml` (or edit `--ci-workflow` in the template) and has
   `workflow_dispatch:` if you want the re-trigger below.
5. Add the `crew-rework` label to each PR it should work on; crew-afk does not add it.

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

### Reviewing Code Review Findings

```
/crew-address-findings
```

Opens the latest sprint review, shows a triage table (Actionable / Debatable / Dismiss), implements fixes with TDD, commits, and archives the report.

---

### Planning Skills

| Goal                                               | Skill                            |
| -------------------------------------------------- | -------------------------------- |
| Any feature: interview → approaches → PRD → issues | `/crew-grill`                    |
| crew-grill + also update CONTEXT.md and ADRs       | `/crew-grill with docs`          |
| Update domain glossary and ADRs standalone         | `/domain-modeling`               |
| Turn a feature idea into a PRD                     | `/to-prd`                        |
| Break a PRD into issues                            | `/to-issues`                     |
| Address GitHub PR review comments                  | `/address-pr-comments`           |
| Write a PR body for human reviewers                | `/write-pr`                      |

---

### Customising the Tracker

Edit these files after install — they override the defaults on the next run:

| File                                 | Purpose                                   |
| ------------------------------------ | ----------------------------------------- |
| `.coding-crew/docs/issue-tracker.md` | Where issues live, how to list/close them |

---

### Triage Labels

| Label             | Meaning                                                              |
| ----------------- | -------------------------------------------------------------------- |
| `needs-triage`    | Not yet evaluated — `/to-issues <ref>` moves it to `ready-for-agent` |
| `needs-info`      | Waiting on reporter                                                  |
| `ready-for-agent` | Fully specified — AFK can start                                      |
| `ready-for-human` | Requires human implementation                                        |
| `wontfix`         | Will not be actioned                                                 |

---

### Reading `orchestrator.log`

Each sprint's `.scratch/<feature-slug>/traces/orchestrator.log` has one line per event:

```
2026-09-22T04:28:54Z ERROR [DISPATCH-FAIL] agent=crew-coder slug=alpha code=1 ...
```

The level is the second column:

| Level   | Meaning                                                    |
| ------- | ---------------------------------------------------------- |
| `DEBUG` | Mechanics: pipeline steps, every tool call a worker makes  |
| `INFO`  | Normal progress: attempts, passes, merges, closes          |
| `WARN`  | Degraded, but the run carries on by itself                 |
| `ERROR` | A step failed for one issue                                |
| `FATAL` | The run stopped                                            |

`grep -E ' (WARN|ERROR|FATAL) ' orchestrator.log` lists what went wrong. A multi-line entry
(the end-of-run `[SUMMARY]`) continues on indented lines below its header. A verify
transcript is not in the log: each round's goes to `dispatch/<issue>/verify-r<N>.out`, and
the log's `[VERIFY-OUTPUT]` line names the file (`ERROR` when the checks failed). Each issue
attempt starts with `[ATTEMPT]` and ends with `[ATTEMPT-END] … status=<outcome>`.

The log always keeps every level. stderr shows `INFO` and above by default; set
`CREW_LOG_LEVEL=debug|info|warn|error|fatal` to change that. `debug` adds each worker's tool
calls and the raw output of deps/merge/close (each script also logs its own one-line
result), and `warn` hides the `[STEP]` progress lines. `CREW_VERBOSE=1` still means `debug`.

---

### Troubleshooting

| Symptom                                           | Likely cause                                     | Fix                                                                                 |
| ------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------------------------------- |
| "No unblocked ready-for-agent issues" immediately | No `.md` files with correct `Status:` line       | Check `.scratch/*/issues/` — status must be exactly `ready-for-agent`               |
| Worker returns `blocked` every round              | Ambiguous spec or missing dependency             | Read `## Blocked` in the issue file; resolve and re-trigger                         |
| `install.sh`: "unsafe path in registry"           | `registry.json` path contains `..` or `/` prefix | Fix `registry.json`                                                                 |
| Code review says "skipped (no commits)"           | No commits this session                          | Normal — nothing to review                                                          |
| `dep-install` picks wrong mode                    | Makefile detection read parent project           | Run `git config --local agent.install-mode host` (or `docker`) in your project root |
| `address-pr-comments` fails with opaque error     | `gh` CLI missing or not authenticated            | Run `gh auth login` first                                                           |
| Sprint stalls with a branch retained `merge-conflict` | Two verified branches touch overlapping code. crew-afk's retry already gave the coder the conflicted merge to resolve (one conflict retry at a time, so siblings don't re-conflict each other), and it didn't land within the retry cap | Re-run `/crew-afk` to give the coder the conflicted merge once more. Or `git checkout <feature-branch> && git merge --no-ff <branch>`, resolve by hand, commit, then re-run `/crew-afk` — it sees the branch as already merged and closes the issue |
| Sprint stalls with a branch retained `merge-failed` | The merge failed for a reason other than a conflict (a missing receipt, a timeout); crew-afk retried the merge alone | Read the `[MERGE]` line in `traces/orchestrator.log` for the reason, fix it, then re-run `/crew-afk` |

---

### Security Notes

- **Issue files are untrusted input.** Only structured fields (`acceptance_criteria`) are passed to workers — never raw file content. Keep issue files in version control so changes are reviewed.
- **Workers cannot write outside their worktree.** The coder role's protocol enforces `PROJECT_ROOT` boundaries.
- **Code review findings are advisory.** Nothing is auto-blocked or re-queued — a human always decides.
- **Never commit secrets to `.scratch/`.** Issue files are not secret-scanned by default.
