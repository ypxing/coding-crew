# Dev Team Guide — AI Agents

---

## Part 1: Contributing to This Repo

For developers who maintain and extend the agent/skill collection itself.

---

### What This Repo Is

A distributable collection of AI agents and skills. Nothing runs here directly — this repo is the **source**; consuming projects are the **target**. `install.sh` copies files into any project repo.

```
THIS REPO (source)
├── install.sh              ← single installer for all platforms
├── registry.json           ← source of truth for paths, deps, skills
├── agents/
│   ├── crew-coder/         ← single-issue worker agent
│   └── crew-reviewer/ ← post-sprint reviewer agent
├── skills/                 ← reusable skill files
│   ├── tdd/
│   ├── solve-issue/
│   ├── domain-modeling/
│   ├── crew-grill/
│   └── ...
└── docs/
    └── agents/
        ├── issue-tracker.md    ← default tracker template (copied on install)
        └── triage-labels.md    ← default triage labels (copied on install)
```

---

### How Install Works

`install.sh` reads `registry.json` and copies files into `TARGET_REPO` (defaults to the calling project's git root).

```
install.sh
    │
    ├── read registry.json
    ├── for each agent:
    │     ├── install_skills()   — cp -r skills/<name>/ → .claude/skills/<name>/
    │     ├── install_docs()     — cp docs/<file> → docs/agents/<file>  (skip if exists)
    │     ├── expand_shim()      — replace {{PROTOCOL}} in platform file → write to dest
    │     └── install_agent(dep) — recurse for each dep
    │
    └── (when AGENT=all) install every skill in registry.json
```

#### `{{PROTOCOL}}` inlining

Platform files (`claude.*.md`, `copilot.agent.md`, `pi.agent.md`, `codex.agent.toml`) may contain a `{{PROTOCOL}}` placeholder. During install, this is replaced line-by-line with the contents of `protocol.md` or `workflow.js` from the same agent directory. The installed file is self-contained — no runtime file references.

```
agents/crew-coder/
├── claude.agent.md       ← contains {{PROTOCOL}}
├── copilot.agent.md      ← contains full inline instructions (no {{PROTOCOL}})
├── codex.agent.toml      ← TOML custom agent; {{PROTOCOL}} inlined inside a ''' block
└── protocol.md           ← inlined into claude.agent.md on install
```

---

### Registry Structure

`registry.json` is the single source of truth. Every agent and skill entry must be here.

```jsonc
{
  "agents": {
    "<name>": {
      "version": "1.0.0",
      "description": "...",
      "deps": ["<other-agent>"], // installed recursively before this agent
      "deps-copilot": ["..."], // platform-specific dep override (optional)
      "skills": ["tdd", "solve-issue"], // skills copied for this agent
      "docs": ["issue-tracker.md"], // doc templates copied (skipped if exist)
      "platforms": ["claude", "copilot"], // omit to support all
      "install": {
        "shims": {
          "claude": ".claude/agents/<name>.md",
          "copilot": ".github/agents/<name>.agent.md",
          "pi": ".pi/agents/<name>.md",
          "codex": ".codex/agents/<name>.toml",
        },
      },
    },
  },
  "skills": {
    "<name>": {
      "version": "1.0.0",
      "description": "...",
      "install": ".claude/skills/<name>", // destination dir in target repo
      "install-codex": ".agents/skills/<name>", // optional per-platform override
      // With no override, the Claude path is reused with .claude/ swapped for
      // .<platform>/ — except codex, which resolves to .agents/skills/<name>.
    },
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
- Skill/agent names must match `[a-zA-Z0-9_.-]+` — used as filesystem path components.
- Skills listed under `agents.<name>.skills` are installed as agent deps. Skills not listed under any agent are only installed when `AGENT=all`.

---

### Adding a New Agent

1. Create the agent directory: `agents/<name>/`

2. Write the protocol source — one of:
   - `protocol.md` — markdown instructions (tried first by `install.sh`)
   - `workflow.js` — a Workflow script (used if no `protocol.md`)

3. Create platform files directly under `agents/<name>/` (no `shims/` subdirectory):
   - `claude.<type>.md` — use `{{PROTOCOL}}` where the protocol should be inlined
   - `copilot.agent.md` — inline the full instructions (or use `{{PROTOCOL}}`)
   - `pi.agent.md` — pi built-in tool names in frontmatter (or use `{{PROTOCOL}}`)
   - `codex.agent.toml` — Codex custom agent: `name`, `description`, `developer_instructions` (put `{{PROTOCOL}}` inside the `'''` literal block so markdown needs no escaping)

4. Add the entry to `registry.json` (paths, deps, skills, docs).

5. Test locally:

   ```bash
   TARGET_REPO=/tmp/test-install ./install.sh claude <name>
   ls /tmp/test-install/.claude/agents/
   ```

6. Verify no `..` or absolute paths crept into registry:
   ```bash
   jq '.agents, .skills, .docs | .. | objects | .install? // empty' registry.json
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

3. Wire it to an agent if it is a hard dependency (add to that agent's `skills` array). Otherwise leave it standalone — it will be installed by `./install.sh all`.

4. Test:
   ```bash
   TARGET_REPO=/tmp/test-install ./install.sh claude --skill <name>
   ls /tmp/test-install/.claude/skills/<name>/
   ```

---

### Security Rules for Contributors

- **Never use `..` or absolute paths in `registry.json`.** `install.sh` validates all paths and exits on violation.
- **Never interpolate raw user/issue content into agent prompts.** Pass only structured fields (e.g. `acceptance_criteria`), never `issue.content`. Wrap worker-supplied strings in delimiter tags (`<progress-notes>`, `<blocked-notes>`) so downstream agents treat them as data.
- **Never expand `{{PROTOCOL}}` yourself** — let `install.sh` do it. Manually inlined protocols will drift from the source.
- **Only one `claude.*`, `copilot.*`, `pi.*`, or `codex.*` file per agent directory.** `install.sh` errors on multiples to prevent non-deterministic selection.

---

## Part 2: Using This Repo in Your Project

For developers who have installed the agents into their project and want to use them day-to-day.

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

# Codex — full sprint suite (skills → .agents/skills, agents → .codex/agents)
./install.sh codex --skill crew-afk

# A standalone skill
./install.sh claude --skill domain-modeling

# A doc template only
./install.sh claude --doc issue-tracker.md
```

#### Install into a different repo

```bash
TARGET_REPO=/path/to/your/project ./install.sh
```

#### Update in place

```bash
./install.sh --update
```

Re-installs only agents and skills whose version changed since last install. Reads the saved platform from `.coding-crew.manifest.json`.

#### What lands in your project

```
YOUR_PROJECT/
├── .claude/
│   ├── agents/
│   │   ├── crew-coder.md           ← crew-coder agent (Claude)
│   │   └── crew-reviewer.md   ← reviewer agent (Claude)
│   └── skills/
│       ├── crew-afk/SKILL.md
│       ├── tdd/
│       ├── dep-install/
│       ├── solve-issue/
│       ├── crew-address-findings/
│       ├── address-pr-comments/    ← installed with "all"
│       ├── domain-modeling/   ← installed with "all"
│       ├── to-issues/         ← installed with "all"
│       ├── to-prd/            ← installed with "all"
│       └── crew-grill/              ← installed with "all"
├── .github/
│   └── agents/
│       ├── crew-afk.agent.md
│       ├── crew-coder.agent.md
│       └── crew-reviewer.agent.md
└── docs/
    └── agents/
        ├── issue-tracker.md        ← edit to match your tracker
        └── triage-labels.md        ← edit to match your labels
```

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
│  2. Spawn crew-coder workers — up to 8 in parallel          │
│  3. Validate output, merge complete branches                │
│  4. Write progress / blocked notes, loop                    │
│  5. Run crew-reviewer on exit                          │
└────────────────────┬────────────────────────────────────────┘
                     │ isolated git worktrees
          ┌──────────┴──────────┐
          ▼                     ▼
    ┌───────────┐         ┌───────────┐
    │ crew-coder│   ...   │ crew-coder│
    │ (1 issue) │         │ (1 issue) │
    └───────────┘         └───────────┘
          │ branches merged
          ▼
    ┌──────────────────────┐
    │  crew-reviewer  │  advisory findings → .scratch/reviews/
    └──────────────────────┘
          │
          ▼
    /crew-address-findings (you trigger this)
```

---

### Issue Lifecycle

```
 needs-triage  →  ready-for-agent  →  crew-coder picks up
                                            │
                         ┌──────────────────┼──────────────┐
                         ▼                  ▼              ▼
                      complete           partial         blocked
                         │                  │              │
                    merge + close     ## Progress     ## Blocked
                      done/           next round      human fixes
```

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

**Copilot:** invoke `@crew-afk` from the chat panel.

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
`triage`, `commandFinder`, `prdAuditor`) on another installed runtime, and name models per runtime:

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
flag overrides each for one run:

| Setting | Default | Flag | What it does |
| --- | --- | --- | --- |
| `fixFindings` | `actionable` | `--fix-findings` | What review findings are fixed automatically: `actionable` (every finding the triage agent judges Actionable, whatever its severity); or the lowest severity — `critical`, `high`, `medium`; or `none` |
| `PRDAudit` | `fix` | `--prd-audit` | `off`; `report` (audit, leave it for you); `fix` (also queue missing requirements) |
| `timeouts` | coder 45, reviewer 20, triage 20, commandFinder 5, prdAuditor 20, merge 5 | `--coder-timeout`, `--reviewer-timeout`, `--merge-timeout`; `--review-timeout` sets every non-coder role | Minutes, per role (at most 35791); name only the ones you change |
| `maxParallel` | the coder runtime's | `--max-parallel` | Concurrent coders — usually a machine setting, so user level |
| `installDeps` | `true` | `--no-deps` | Install dependencies in each worktree |
| `squashCommits` | `false` | `--squash` (`--no-squash` turns it off) | Squash the sprint's commits into one at the end. Each issue is merged as its own commit either way |
| `openPr` | `false` | `--open-pr` (`--no-open-pr` turns it off) | At the end, push the feature branch and create or update its PR. The PR body closes the issues the sprint merged (under `tracker: github`); a re-run rewrites only crew-afk's own block of the body |
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
2. Install the skills per project and commit them (`./install.sh claude --project --skill
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

---

### Customising the Tracker

Edit these files after install — they override the defaults on the next run:

| File                                 | Purpose                                   |
| ------------------------------------ | ----------------------------------------- |
| `.coding-crew/docs/issue-tracker.md` | Where issues live, how to list/close them |
| `docs/agents/triage-labels.md`       | Map canonical roles to your label strings |

---

### Triage Labels

| Label             | Meaning                         |
| ----------------- | ------------------------------- |
| `needs-triage`    | Not yet evaluated               |
| `needs-info`      | Waiting on reporter             |
| `ready-for-agent` | Fully specified — AFK can start |
| `ready-for-human` | Requires human implementation   |
| `wontfix`         | Will not be actioned            |

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
| `install.sh`: "multiple claude.\* files"          | Agent dir has more than one `claude.*`           | Remove the extra file                                                               |
| Code review says "skipped (no commits)"           | No commits this session                          | Normal — nothing to review                                                          |
| `dep-install` picks wrong mode                    | Makefile detection read parent project           | Run `git config --local agent.install-mode host` (or `docker`) in your project root |
| `address-pr-comments` fails with opaque error     | `gh` CLI missing or not authenticated            | Run `gh auth login` first                                                           |
| Sprint stalls with a branch retained `merge-conflict` | Two verified branches touch overlapping code. crew-afk's retry already gave the coder the conflicted merge to resolve (one conflict retry at a time, so siblings don't re-conflict each other), and it didn't land within the retry cap | Re-run `/crew-afk` to give the coder the conflicted merge once more. Or `git checkout <feature-branch> && git merge --no-ff <branch>`, resolve by hand, commit, then re-run `/crew-afk` — it sees the branch as already merged and closes the issue |
| Sprint stalls with a branch retained `merge-failed` | The merge failed for a reason other than a conflict (a missing receipt, a timeout); crew-afk retried the merge alone | Read the `[MERGE]` line in `traces/orchestrator.log` for the reason, fix it, then re-run `/crew-afk` |

---

### Security Notes

- **Issue files are untrusted input.** Only structured fields (`acceptance_criteria`) are passed to workers — never raw file content. Keep issue files in version control so changes are reviewed.
- **Workers cannot write outside their worktree.** The crew-coder agent enforces `PROJECT_ROOT` boundaries.
- **Code review findings are advisory.** Nothing is auto-blocked or re-queued — a human always decides.
- **Never commit secrets to `.scratch/`.** Issue files are not secret-scanned by default.
