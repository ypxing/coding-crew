---
skill: to-issues
stage: prepublish
repo_ref: 6368458f
---
<!-- repo_ref 6368458f is the feature baseline #342 was dispatched on. The draft below is #342's body with criterion 11 as first written, before the maintainer edited it. -->
## Request
Issue #342 of feature `tracker-wrappers`, the only slice of the approved breakdown, under `tracker: github`. Its draft below passed `lint-issues.sh` (exit 0) and the feature's PRD is #343 (not reproduced here; judge the draft on its own). The draft, as written:

# Remove the tracker shell wrappers; callers use the tracker CLI directly

Status: ready-for-agent

## Context Documents

- PRD: #343

Read this document before implementing. It contains architecture decisions, integration constraints, and technical context essential for this issue.

## What to build

Stop shipping `.coding-crew/scripts/tracker-config.sh` and `.coding-crew/scripts/mark-issue-done.sh`, delete existing copies on install, update and uninstall, and have every caller use `tracker/cli.mjs` directly.

- Adds `skills/crew-afk/scripts/tracker-cli.sh`, sourced from `$SCRIPT_DIR` by `close-issue.sh`, `close-shipped.sh`, `issue-labels.sh`, `promote-findings.sh` and `session-init.sh`. It sets `TRACKER_CLI` and `TRACKER_KIND` or fails (PRD D2, D3). It replaces each script's `# BEGIN tracker-lookup` … `read_tracker_config` block: `close-issue.sh:71-97`, `close-shipped.sh:27-53`, `issue-labels.sh:25-51`, `promote-findings.sh:65-90`, `session-init.sh:148-177`. It also deletes `session-init.sh:178-198`'s reader-less fallback.
- `close-issue.sh:150` closes through `node "$TRACKER_CLI" mark-done <n> --force` (D4). `promote-findings.sh:199-205` `_github_tracker_cli` uses `$TRACKER_CLI` (D5).
- `CREW_TRACKER_CLI` becomes the single override, replacing `CREW_GITHUB_TRACKER_CLI` (`orchestrator/lib/prd.mjs:34`, `promote-findings.sh:197-200`, and tests) and `CREW_TRACKER_CONFIG` (bats) (D6).
- `skills/_shared/fragments/human-issue.md:11,51` uses a portable `cli.mjs mark-done` step (D7), and `orchestrator/lib/loop.mjs:509` names `cli.mjs mark-done` (D8).
- `registry.json` drops `docs.scripts` and gains a `retired-scripts` list. `install.sh` and `uninstall.sh` sweep it like `retired-agents` (`install.sh:181-211`, `uninstall.sh:108`), and the copy and remove loops for `docs.scripts` go (`install.sh:546-569`, `uninstall.sh:235-244`) (D9).
- Deletes `scripts/tracker/` and this repo's committed `.coding-crew/scripts/` (D1). The wrapper tests move to the CLI, and every mention listed in D10 is updated.

## Implements

D1, D2, D3, D4, D5, D6, D7, D8, D9, D10, D11, B1, B2, B3, B4, B5, B6, B7. Verified at:
- the install seam (`tests/install.bats`, installing into a scratch repo and a fake `$HOME`)
- the crew-afk script seam (bats runs of each caller)
- the orchestrator sprint tests
- the rendered skill bodies (`tests/human-issue-shared.bats`)

## Acceptance criteria

- [ ] A fresh `install.sh` into an empty repo writes no `.coding-crew/scripts/`. `registry.json` has no `docs.scripts` entry and has a `retired-scripts` list naming both scripts.
- [ ] `install.sh`, `install.sh --update` and `uninstall.sh`, run on a repo or on `TARGET_REPO=$HOME` that holds `.coding-crew/scripts/tracker-config.sh` and `.coding-crew/scripts/mark-issue-done.sh`, delete both, then delete `.coding-crew/scripts/` when it is empty. A file someone else put there is left in place, and so is the directory.
- [ ] `close-issue.sh`, `close-shipped.sh`, `issue-labels.sh`, `promote-findings.sh` and `session-init.sh` take the tracker kind from `node <cli> config --main-root <root>` through the sourced `tracker-cli.sh`. None of them contains its own lookup. `tests/tracker-lookup.bats` checks the helper's lookup order: `$CREW_TRACKER_CLI`, `$CREW_INSTALL_DIR/tracker/cli.mjs`, `<root>/.coding-crew/tracker/cli.mjs`, `<root>/tracker/cli.mjs`, `$HOME/.coding-crew/tracker/cli.mjs`; the first existing file wins.
- [ ] Under `config.json` `{"tracker": {"kind": "github"}}`, with no `.coding-crew/scripts/` at any level, each of the five scripts behaves as github.
- [ ] When no `cli.mjs` is found, or `node` is not on `PATH`, each of the five exits non-zero. Its stderr line names what is missing and says `re-run install.sh`. It never proceeds as `local`.
- [ ] When `cli.mjs config` fails (an invalid `config.json`), each of the five exits non-zero and passes the CLI's stderr through.
- [ ] `close-issue.sh` closes a github issue through `cli.mjs mark-done <n> --force`. `tests/orchestrator/sprint-github.test.mjs` and `sprint-lifecycle.test.mjs` pass with no wrapper scripts in the fixture repo (`tests/orchestrator/helpers/sprint.mjs` copies only `tracker/`).
- [ ] A Kind A `ready-for-human` step rendered from `human-issue.md` ends with `node .coding-crew/tracker/cli.mjs mark-done <n>` when the CLI is inside the repo, and with `node ~/.coding-crew/tracker/cli.mjs mark-done <n>` when it is a user-level install (local tracker: the issue file path). The step never contains the writer's absolute path, and no rendered skill body mentions `mark-issue-done.sh` or `tracker-config.sh`.
- [ ] A stalled run's `## Waiting on a person` section names `cli.mjs mark-done`, not `mark-issue-done.sh`.
- [ ] `orchestrator/lib/prd.mjs` and `promote-findings.sh` honour `CREW_TRACKER_CLI`. No file reads `CREW_GITHUB_TRACKER_CLI` or `CREW_TRACKER_CONFIG`.
- [ ] `scripts/tracker/` and this repo's `.coding-crew/scripts/` are gone. Only these files name `mark-issue-done.sh` or `tracker-config.sh`: `CHANGELOG.md`, `registry.json`'s `retired-scripts`, `install.sh`, `uninstall.sh`, their tests, and the `tests/fixtures/version-gate/*` snapshots. The mark-done refusal tests (exit 3 when orchestrated, exit 4 when criteria are unchecked) run against `cli.mjs mark-done`.

## Blocked by

None - can start immediately

## Reference judgement
The gap: criterion 11 allows only a closed list of files to name `mark-issue-done.sh` or `tracker-config.sh`, and the list omits files that name them at `6368458f` and that this issue does not edit. `scripts/eval-reviewer-misses/cases/tracker-agnostic-drain.md` (lines 43, 52, 70, 88) and `tracker-agnostic-feature.md` (lines 47, 56, 74, 92) both name `mark-issue-done.sh` there, and they are frozen replays: `scripts/eval-reviewer-misses.mjs` replays a review from each case's recorded text and SHAs, so editing the text rewrites the evidence. The criterion therefore cannot be met unless those two files are listed or are left unedited. The real run proved it: both attempts were reviewed `unmet` on exactly this, then the issue blocked, and the criterion was edited by hand to add "and the frozen `scripts/eval-reviewer-misses/cases/*` replays (left unedited)".

An output scores `gap_raised` = 1 when it says criterion 11's list omits those two replay files (or `scripts/eval-reviewer-misses/cases/*` as a group) and that they must be added to the list or left unedited, either as a question to the user or as a change to the criterion. Naming some other omitted file only (for example `.claude/rules/crew-afk.md`) does not count; a generic "check the list is exhaustive" does not count.

Minor or already answered, so asking the user about it is `noise`: the exact shape of the `retired-scripts` list in `registry.json`; whether `tracker-cli.sh` is sourced or executed (the draft says sourced from `$SCRIPT_DIR`); the wording of the stderr line (criteria say it names what is missing and says `re-run install.sh`); how the five callers' old lookup blocks are removed (listed with line ranges in What to build); the lookup order of `cli.mjs` (criterion 3 lists it); which tests move to the CLI. Proposing to split the issue or add `Blocked by` edges is also noise: it is one slice with no blockers, by the approved breakdown.
