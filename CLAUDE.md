# CLAUDE.md

Guidance for Claude Code (or any agent) working in this repo.

## What this repo is

A distributable collection of AI skills that other projects install via `install.sh`.
Nothing here runs on its own — this repo is the source; consuming projects are the target.
For the end-user pipeline (crew-grill/crew-brainstorm → solve-feature), see `README.md`.

## Working in this repo

```bash
# Install into a scratch repo to see what a platform actually receives
TARGET_REPO=/tmp/test-repo ./install.sh claude --skill solve-feature

# Render a skill body without a full install
bash scripts/render-skill.sh solve-issue codex | less

# Run tests: one bats process per file, CPU-count at a time, heaviest first (plain `bats tests/*.bats` runs files one by one, ~6x slower)
bash scripts/ci-run-bats.sh tests/*.bats

# After editing crew-grill/crew-brainstorm/to-issues: behavioural A/B (base ref vs worktree), judged blind; costs API money
node scripts/eval-design-skills.mjs --skill crew-grill --runs 2 --dry-run   # drop --dry-run to run

# After editing skills/crew-review/SKILL.md: replay the bugs earlier reviews missed against base and head, judged blind; costs API money
node scripts/eval-reviewer-misses.mjs --runs 2 --dry-run   # writes each ref's prompts, calls no model; drop --dry-run to run

# Bring a PR branch up to date with origin/main (local only, never pushes): merge it, resolve registry version / CHANGELOG append conflicts, bump versions to sit above main's
scripts/sync-pr-with-main.sh <branch>

# Cut a milestone release (not per merge) once CHANGELOG.md's top version entry and any registry.json version bumps are committed;
# needs a passing demo smoke log (`SMOKE: PASS (<platform>, demo)` and the `crew-afk-commit:` it ran at), run on a clean checkout with nothing but CHANGELOG.md and RESULTS.md committed since, or an explicit opt-out; the tree must be clean, RESULTS.md row included
scripts/cut-release.sh --dry-run --demo-smoke /tmp/smoke.log   # or --no-demo-smoke "<reason>"; verify, then re-run without --dry-run to tag and push
```

- Version bump (D4): a change to any file a `skills.*` entry in `registry.json` ships (its `source-dir` tree, `assets.source` tree, `scripts[]`) or to that entry's own registry fields needs that entry's `version` in `registry.json` strictly above `origin/main`'s version for it — `install.sh --update` skips an entry whose version is unchanged, and two branches bumping to the same number would collide. An entry the branch did not change (measured from the merge-base) is exempt even if main bumped it. `tests/registry-version-bump.bats` enforces it against `origin/main` (skips when it is not found) and fails the verify gate otherwise.
- Code comments follow solve-issue's comment rule (`skills/solve-issue/SKILL.md`, Step 4).
- One writer per issue file: don't add code paths where an agent edits an issue's `Status:`/checkboxes directly — that's the tracker CLI's job (`tick`, `mark-done`).
- `CHANGELOG.md`: add one entry at the top of `[Unreleased]` (component prefix, what changed for a user, issue/PR number). Read only its first ~20 lines to do it, not the whole file.
- Issues (this repo's own dev use) live in `.scratch/<feature-slug>/issues/{open,done}/`; the tracker is set in `.coding-crew/config.json` (`{"tracker": {"kind": …}}`); see `tracker/docs/<kind>.md`.

## Axes of variation

The design standard (`skills/_shared/fragments/design-standard.md`, criterion 3) counts these as real axes, so a decision that varies along one belongs behind one abstraction even with a single implementation today:

- platforms — `platforms.json` (claude, copilot, pi, codex)
- trackers — local, github (`tracker/`, `tracker/docs/`, `.coding-crew/config.json`'s `tracker` section)
- dependency-install ecosystems — `dep-install`'s detection and install scripts

## Layer ownership

The call direction is `solve-feature` → `solve-issue` (skill) → `tdd` / `dep-install`. A human running
`/solve-issue` gets the same procedure, so anything the direct path needs belongs in `solve-issue` or below
it. Content that fits no row is in the wrong file; `tests/layer-ownership.bats` checks the table.

| Layer                 | Owns                                             | Must not contain                 |
| --------------------- | ------------------------------------------------ | -------------------------------- |
| `solve-issue`         | the ordered procedure and the outcome vocabulary | who its caller is                |
| `tdd` / `dep-install` | one technique each                               | issue, report or status handling |

## solve-feature and crew-review stay boring

Two levels, for `skills/solve-feature/` and `skills/crew-review/`:

- **Between skills:** one skill does one job and is named for it; a skill uses another only by name ("Use the X
  skill"), never through a path into its files; where and how it runs (CI, hosts, config) belongs to setup, not
  to the skill.
- **Inside a skill:** a line earns its place as a step, or as a guard without which a person is **misled** (a PR
  marked ready or an issue counted landed when it isn't) or **stuck** (a stop that doesn't say what failed and how
  to recover). Cut: code that parses prose an LLM wrote, a second copy of status git/GitHub already shows, two
  writers for one artifact, a guard for a case no run has hit. A cut guard takes its test with it.
