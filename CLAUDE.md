# CLAUDE.md

Guidance for Claude Code (or any agent) working in this repo.

## What this repo is

A distributable collection of AI skills (and crew-afk, the program that runs them unattended) that other projects install via `install.sh`.
Nothing here runs on its own — this repo is the source; consuming projects are the target.
For the end-user pipeline (crew-grill/crew-brainstorm → crew-afk → crew-address-findings), see `README.md`.

## Layout

- `skills/<skill>/SKILL.md` — one skill per directory, one body for every platform (`{{PLATFORM}}` is the one per-platform substitution). `crew-afk`'s skill is a thin launcher; its actual logic is the `orchestrator/` program.
- `orchestrator/` — the crew-afk state machine (rounds, worktrees, deps → dispatch → verify → review → merge → close, receipts). One implementation, run by all four platform launchers via `orchestrator/lib/dispatch.mjs`.
- `orchestrator/roles/` — the role protocols crew-afk dispatches (`coder.md`, `reviewer.md` + `reviewer/` checklists and scripts, `triage.md`). They ship with the orchestrator to `.coding-crew/crew-afk/roles/` (crew-afk also installs `skills/_shared/fragments/` to `.coding-crew/skills/_shared/fragments/` for their `{{FRAGMENT:…}}` lines) and are rendered per dispatch; no platform gets an agent file. `registry.json`'s `retired-agents` lists the agent files older installs wrote, which install and uninstall remove.
- `tracker/` — the issue-tracker backends (`local.mjs`, `github.mjs`, `body-format.mjs`), `tracker-config.mjs`, `getTracker()` (`index.mjs`) and `cli.mjs`, the tracker CLI skills call. `registry.json`'s `docs.trees` installs it to `.coding-crew/tracker/` on every install, always overwritten; the orchestrator imports it relatively (`../../tracker/…`), so source and installed trees resolve alike.
- `orchestrator/platforms.json` — the platform list and where each platform keeps skills (`projectSkills`, `userSkills`, `configDir`, `configDirEnv`); a skill installs to `<projectSkills|userSkills>/<skill>`.
- `registry.json` — source of truth for skills (`version`, `deps`, `assets`), `retired-agents`, and doc templates.
- `install.sh` / `uninstall.sh` — installer; both source `scripts/lib/platforms.sh`, which reads the platform list and skill destinations from `orchestrator/platforms.json`.
- `scripts/` — shared build-time scripts copied into skills (`skills/skill-utils/git-workflow/`) and maintainer-only scripts that ship to no consumer (`ci-test-shard.sh`, `ci-run-bats.sh`, `render-skill.sh`, `cut-release.sh`, `sync-pr-with-main.sh`, `smoke-sprint.sh` + `smoke-sprint/`, `eval-design-skills.mjs` + `eval-design-skills/`, `eval-reviewer-misses.mjs` + `eval-reviewer-misses/`). Skill-local runtime scripts live with their skill (e.g. `skills/crew-afk/scripts/`).
- `tests/` — bats tests, run against **rendered/installed** output via `tests/helpers/render.bash`, not source variants.
- `docs/` — the dev team guide (`guide.md`) and issue-tracker templates.
- `.claude/rules/` — detail loaded only when working on matching paths: `crew-afk.md` (orchestrator and crew-afk scripts behaviour, adding a role), `to-issues-linter.md`. Update them alongside the code they describe.

## Working in this repo

```bash
# Install into a scratch repo to see what a platform actually receives
TARGET_REPO=/tmp/test-repo ./install.sh claude --skill crew-afk

# Render a skill body without a full install
bash scripts/render-skill.sh crew-afk codex | less

# Run tests: one bats process per file, CPU-count at a time (plain `bats tests/*.bats` runs files one by one, ~6x slower)
bash scripts/ci-run-bats.sh tests/*.bats

# After editing crew-grill/crew-brainstorm/to-issues: behavioural A/B (base ref vs worktree), judged blind; costs API money
node scripts/eval-design-skills.mjs --skill crew-grill --runs 2 --dry-run   # drop --dry-run to run

# One real crew-afk sprint on one platform, in a repo rebuilt fresh from scripts/smoke-sprint/ each run; costs API money
scripts/smoke-sprint.sh copilot              # --setup-only builds the repo without calling the CLI
scripts/smoke-sprint.sh claude --demo > /tmp/smoke.log   # the same on the pinned demo repo (scripts/smoke-sprint/demo/); appends a row to scripts/smoke-sprint/RESULTS.md — commit it before cutting the release

# After editing orchestrator/roles/reviewer.md: replay the two bugs PR #208 shipped with against base and head, judged blind; costs API money
node scripts/eval-reviewer-misses.mjs --runs 2 --dry-run   # writes each ref's prompts, calls no model; drop --dry-run to run

# Bring a PR branch up to date with origin/main (local only, never pushes): merge it, resolve registry version / CHANGELOG append conflicts, bump versions to sit above main's
scripts/sync-pr-with-main.sh <branch>

# Cut a milestone release (not per merge) once CHANGELOG.md's top version entry and any registry.json version bumps are committed;
# needs a passing demo smoke log (`SMOKE: PASS (<platform>, demo)`) for HEAD's crew-afk version, run on a clean checkout with nothing but CHANGELOG.md and RESULTS.md committed since, or an explicit opt-out; the tree must be clean, RESULTS.md row included
scripts/cut-release.sh --dry-run --demo-smoke /tmp/smoke.log   # or --no-demo-smoke "<reason>"; verify, then re-run without --dry-run to tag and push
```

- Version bump (D4): a change to any file a `skills.*` entry in `registry.json` ships (its `source-dir` tree, `assets.source` tree, `scripts[]`) or to that entry's own registry fields needs that entry's `version` in `registry.json` strictly above `origin/main`'s version for it — `install.sh --update` skips an entry whose version is unchanged, and two branches bumping to the same number would collide. An entry the branch did not change (measured from the merge-base) is exempt even if main bumped it. `tests/registry-version-bump.bats` enforces it against `origin/main` (skips when it is not found) and fails the verify gate otherwise.
  In an issue's acceptance criteria, state it as the invariant ("`<entry>`'s version is above origin/main's"), never as "version bumped": issues in one sprint run in parallel, and once a sibling has bumped the entry, the bump drops out of a later branch's diff after it syncs with the feature branch, so the reviewer finds it unmet.
- A crew-afk mechanism change cites how many times its incident happened (from the logs or the tracker): a gate, retry or promotion rule added for one incident costs every sprint, so the count is what justifies it.
- One writer per issue file: don't add code paths where a worker/agent edits an issue's `Status:`/checkboxes directly — that's `close-issue.sh`'s job, gated by receipts.
- `CHANGELOG.md`: add one entry at the top of `[Unreleased]` (component prefix, what changed for a user, issue/PR number). Read only its first ~20 lines to do it, not the whole file.
- Issues (this repo's own dev use) live in `.scratch/<feature-slug>/issues/{open,done}/`; see `.coding-crew/docs/issue-tracker.md`.

## Axes of variation

The design standard (`skills/_shared/fragments/design-standard.md`, criterion 3) counts these as real axes, so a decision that varies along one belongs behind one abstraction even with a single implementation today:

- platforms — `orchestrator/platforms.json` (claude, copilot, pi, codex)
- trackers — local, github (`tracker/`, `.coding-crew/docs/issue-tracker.md`)
- crew-afk roles — `orchestrator/roles/` (`ROLE_AGENTS` in `orchestrator/lib/adapters/render.mjs`)
- dependency-install ecosystems — `dep-install`'s detection and install scripts
- pane hosts — `orchestrator/lib/pane-host/` (herdr, orca)

## Layer ownership

The call direction is crew-afk (program) → `crew-coder` (role, `orchestrator/roles/coder.md`) → `solve-issue` (skill) → `tdd` /
`dep-install`. `crew-coder` is on the **sprint path only** — a human running `/solve-issue` never
touches it, so anything the direct path also needs belongs below it. Content that fits no row is in
the wrong file; `tests/layer-ownership.bats` checks the `solve-issue`, `tdd` / `dep-install` and `crew-coder` (report wire) rows — the `orchestrator/` and `skills/crew-afk/scripts/` rows are not checked there.

| Layer                      | Owns                                                 | Must not contain                          |
| -------------------------- | ---------------------------------------------------- | ----------------------------------------- |
| `orchestrator/` (code)     | control flow: rounds, gate order, what runs and when | judgement, and prose asking to be obeyed  |
| `skills/crew-afk/scripts/` | one effect each, runnable by hand                    | any decision the orchestrator should make |
| `crew-coder`               | protocol + report wire                               | the implementation loop                   |
| `solve-issue`              | the ordered procedure and the outcome vocabulary     | who its caller is                         |
| `tdd` / `dep-install`      | one technique each                                   | issue, report or status handling          |
