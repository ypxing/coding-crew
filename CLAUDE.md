# CLAUDE.md

Guidance for Claude Code (or any agent) working in this repo.

## What this repo is

A distributable collection of AI skills that other projects install via `install.sh`.
Nothing here runs on its own — this repo is the source; consuming projects are the target.
For the end-user pipeline (crew-grill/crew-brainstorm → crew-afk → solve-feature), see `README.md`.

## Working in this repo

```bash
# Install into a scratch repo to see what a platform actually receives (no --project: $HOME, the default)
./install.sh claude --skill solve-feature --project /tmp/test-repo

# After editing a fragment (skills/_shared/fragments/) or a marker pair: re-render the SKILL.md text between
# <!-- fragment:<key> --> markers and commit the result. skills/<skill>/scripts/<lib> is a committed link into lib/,
# copied through at install: edit lib/<lib>/ and the links follow
bash scripts/render-skill.sh

# Run tests: one bats process per file, CPU-count at a time, heaviest first (plain `bats tests/*.bats` runs files one by one, ~6x slower)
bash scripts/ci-run-bats.sh tests/*.bats

# After editing crew-grill/crew-brainstorm/to-issues: behavioural A/B (base ref vs worktree), judged blind; costs API money
node scripts/eval-design-skills.mjs --skill crew-grill --runs 2 --dry-run   # drop --dry-run to run

# After editing skills/crew-review/SKILL.md: replay the bugs earlier reviews missed against base and head, judged blind; costs API money
node scripts/eval-reviewer-misses.mjs --runs 2 --dry-run   # writes each ref's prompts, calls no model; drop --dry-run to run

# Try two crew-review versions on another project's range, blind; costs API money (two reviewer runs). Writes
# ~/crew-review-field/<project>/<date>-<head8>/: fill in its verdicts.md, then misses.md when a missed bug turns up
node scripts/field-review.mjs /path/to/project --range <base>..<head> [--spec <file>] --skill-head <ref> --dry-run

# One real crew-afk run on the pinned demo repo (scripts/smoke-crew-afk/demo/), in a clone rebuilt fresh each run; costs API money and opens (then closes) one demo PR
scripts/smoke-crew-afk.sh claude > /tmp/smoke.log   # appends a row to scripts/smoke-crew-afk/RESULTS.md — commit it before cutting the release

# Bring a PR branch up to date with origin/main (local only, never pushes): merge it, resolving CHANGELOG append conflicts
scripts/sync-pr-with-main.sh <branch>

# Cut a milestone release (not per merge) once CHANGELOG.md's top version entry is committed;
# needs a passing demo smoke log (`SMOKE: PASS (<platform>, demo)` and the `crew-afk-commit:` it ran at), run on a clean checkout with nothing but CHANGELOG.md and RESULTS.md committed since, or an explicit opt-out; the tree must be clean, RESULTS.md row included
scripts/cut-release.sh --dry-run --demo-smoke /tmp/smoke.log   # or --no-demo-smoke "<reason>"; verify, then re-run without --dry-run to tag and push
```

- Code comments follow solve-issue's comment rule (`skills/solve-issue/SKILL.md`, Step 4).
- One writer per issue file: don't add code paths where an agent edits an issue's `Status:`/checkboxes directly — that's the tracker CLI's job (`tick`, `mark-done`).
- `CHANGELOG.md`: add one entry at the top of `[Unreleased]` (component prefix, what changed for a user, issue/PR number). Read only its first ~20 lines to do it, not the whole file.
- Issues (this repo's own dev use) live in `.scratch/<feature-slug>/issues/{open,done}/`; the tracker is set in `.coding-crew/config.json` (`{"tracker": {"kind": …}}`); see `lib/tracker/docs/<kind>.md`.

## Axes of variation

The design standard (`skills/_shared/fragments/design-standard.md`, criterion 3) counts these as real axes, so a decision that varies along one belongs behind one abstraction even with a single implementation today:

- platforms — `platforms.json` (claude, copilot, pi, codex)
- trackers — local, github (`lib/tracker/`, `lib/tracker/docs/`, `.coding-crew/config.json`'s `tracker` section)
- dependency-install ecosystems — the checks library's detection and install scripts (`lib/checks/`)
- dispatch destinations (local, orca, herdr) — `skills/crew-afk/scripts/destinations/`

## Layer ownership

The call direction is `solve-feature` → `solve-issue` (skill) → `tdd` / `dep-install`. A human running
`/solve-issue` gets the same procedure, so anything the direct path needs belongs in `solve-issue` or below
it. Content that fits no row is in the wrong file; `tests/layer-ownership.bats` checks the table.

| Layer                 | Owns                                             | Must not contain                 |
| --------------------- | ------------------------------------------------ | -------------------------------- |
| `solve-issue`         | the ordered procedure and the outcome vocabulary | who its caller is                |
| `tdd` / `dep-install` | one technique each                               | issue, report or status handling |

## solve-feature and crew-review stay boring

Two levels: the first holds for every skill under `skills/` (`tests/native-skills.bats` checks its paths), the
second for `skills/solve-feature/` and `skills/crew-review/`:

- **Between skills:** one skill does one job and is named for it. A skill uses another skill by name. Code shared
  between skills is a library linked into the skill's own `scripts/` directory, called like a tool, never a path
  into another skill's directory; where and how it runs (CI, hosts, config) belongs to setup.
- **Inside a skill:** a line earns its place as a step, or as a guard without which a person is **misled** (a PR
  marked ready or an issue counted landed when it isn't) or **stuck** (a stop that doesn't say what failed and how
  to recover). Cut: code that parses prose an LLM wrote, a second copy of status git/GitHub already shows, two
  writers for one artifact, a guard for a case no run has hit. A cut guard takes its test with it.
