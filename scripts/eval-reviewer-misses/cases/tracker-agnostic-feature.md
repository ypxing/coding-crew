---
mode: feature
base_sha: cae21d841230
head_sha: cd7114a56771
slug: tracker-agnostic
via: origin/feature/tracker-agnostic
---
Replay of the first feature review of #332 (tracker-agnostic, `dispatch/feature-d1`): the whole feature diff
`cae21d841230..cd7114a56771`, one reviewer reading the whole PRD. The SHAs are reachable through
`origin/feature/tracker-agnostic`; fetch it before running if they do not resolve.
Escaped (`.scratch/tracker-agnostic/reviews/escaped.md`, fixed in `0621433`):
`tracker/local.mjs:311` (D4 × D6), `skills/_shared/fragments/tracker-configuration.md:14` (D3).
The review raised two other real defects (known-file blockers under github, `$TRACKER` across shells), fixed in #333.

## Expected misses

- replace-deletes-known-blocker: Under `tracker: local`, `publish-issues --replace` deletes every open issue (`tracker/local.mjs:311`) without checking whether a draft's `## Blocked by` names one of them; `to-issues` lets drafts name existing issues by their `known` filename and lint accepts it, so after the re-run that draft's blocker never reaches `done/` and the issue is never dispatched.
- worktree-cli-lookup: The `tracker-configuration` fragment looks for the CLI only at `$(git rev-parse --show-toplevel)/.coding-crew/tracker/cli.mjs` and `$HOME`; in a linked worktree (crew-afk's coders, `solve-issue` on the sprint path) `show-toplevel` is the worktree, which has no `.coding-crew/tracker/` unless the consumer committed it, so a project install's CLI is not found.

## Reference judgement

replace-deletes-known-blocker: D4 lets a draft's `## Blocked by` name an existing issue by the filename `known` gives it, and `to-issues` step 6 runs `known` and lints against it before publishing. D6 says `--replace` overwrites. `local.mjs` `publishGuard` (`:279`) refuses only on done issues or on open issues without `--replace`, and `beginPublish` then removes every open file (`:311`). A draft blocked by `01-old.md` is written with that blocker, and `selectDispatchable` reports it blocked by a file that no longer exists, for good. Caught only if a finding says `--replace` can delete an issue a draft's `## Blocked by` (or `known` ref) still names, leaving that draft blocked or the edge dangling; a finding about the numbering after `--replace` or about `issues-deps.json` omitting edges is not it.

worktree-cli-lookup: the fragment (`:14`) is rendered into `solve-issue`, which runs in crew-afk's worktrees (`orchestrator/roles/coder.md` says `.coding-crew/` lives in the main checkout, `MAIN_ROOT`). `git rev-parse --show-toplevel` there is the worktree. The fix tries the main checkout (`dirname` of `--git-common-dir`) before `$HOME`. D3 prescribes the two-candidate lookup, so a reviewer must judge it against how the skill is called, not only against D3. Caught only if a finding says the lookup fails, or finds no CLI, from a linked worktree; a finding about `$TRACKER` not surviving between shells is not it.

## PRD

### Problem Statement

Actor: a maintainer of coding-crew adding or fixing an issue tracker
Origin: #327

Trackers are a named axis of variation (`CLAUDE.md`, "Axes of variation"), and the orchestrator already treats them that way: callers go through `orchestrator/lib/tracker.mjs`'s `getTracker()` and never name a backend. The skills do not. Their prose branches on the tracker 23 times — `to-issues` 12 (+3 in `references/github-publish.md`), `to-prd` 3, `crew-address-findings` 3, `upgrade-deps` 2 — and `to-issues` runs `gh` itself (`skills/to-issues/SKILL.md:18,136,138`). Operations reach agents as prose in `.coding-crew/docs/issue-tracker.md`, which install copies once and never overwrites (`install.sh:506-509`).

Cost measured: `to-issues`' github prose changed in 5 commits in 15 days (a1156a5, a0f77c0, 496d8ec, 59721d6, fe7022a); PR #326's milestone fix lands three times (`github.mjs`, `github.md`'s `publish`, `to-issues`); and the copies already drift — on main `github.mjs:216` lists milestones unpaged while `to-issues:138` pages. A third tracker today means editing every skill.

### Solution

One `tracker` CLI, installed for every user, is the only way a skill touches a tracker. Each op dispatches through `getTracker()` to the backend module (`local.mjs`, `github.mjs`), so a new tracker is one module. Skills name CLI ops only; no skill text contains a `gh` command or an "under `github`/`local`" branch. `to-issues` lints and publishes one tracker-neutral set of drafts; the CLI orders them, creates them and rewrites their refs. `mark-done`'s two guards live once, in code. GitHub-only capabilities (shipping on PR merge, the `in-progress` label, the github preflight) stay where they are, as optional capabilities.

### Behaviours

- **B1** — given drafts `01-a.md`, `02-b.md` (blocked by `01-a.md`) and `deps.json` under `tracker: github`, `tracker publish-issues` creates `01-a` first, then `02-b` whose `## Blocked by` reads `Issue #<number of 01-a>`, each with its status label in the open `<feature-slug>` milestone, and links blockers, at `tracker/cli.mjs` (node test, `gh` stubbed)
- **B2** — given the same drafts under `tracker: local`, `tracker publish-issues` writes `.scratch/<slug>/issues/open/NN-<slug>.md` numbered after any existing issue, with `## Blocked by` and `issues-deps.json` naming the final filenames, at `tracker/cli.mjs`
- **B3** — given a local feature whose `issues/done/` has files, `publish-issues` exits 4 and writes nothing; given open issues and no `--replace`, it exits 5 and writes nothing; `to-issues` turns these into today's stop / confirm-overwrite questions, at `tracker/cli.mjs`
- **B4** — given a single-slice source issue under `tracker: github` labelled `needs-triage` in a closed milestone, `tracker rewrite` replaces its body (its `Source:` line kept as written), swaps `needs-triage` for the given status and puts it in the reopened milestone, at `tracker/cli.mjs`
- **B5** — `bash .coding-crew/scripts/mark-issue-done.sh <ref>` keeps its contract on both trackers (exit 3 when an orchestrator owns the close, 4 while a criterion is unchecked, 0 on success), now through `tracker mark-done`, at the existing bats suites `tests/tracker-mark-done-github.bats` and the local mark-done tests
- **B6** — the rendered `to-issues`, `to-prd`, `crew-address-findings`, `upgrade-deps` and `solve-issue` contain no `` `gh `` command and no "under `github`" / "under `local`" branch, for every platform, at `tests/helpers/render.bash`
- **B7** — given `install.sh claude --skill to-issues` into a scratch repo (no crew-afk), `.coding-crew/tracker/cli.mjs` exists and `node .coding-crew/tracker/cli.mjs prd --feature-slug x` exits 3 (no PRD), at `tests/install.bats`
- **B8** — given a `gh` call that fails, the op exits 1 and stderr carries `gh`'s stderr verbatim, at `tracker/cli.mjs`

### Decisions

- **D1** — Skills reach a tracker only through the CLI. Prose operations are interpreted per run, which is how `to-issues` came to run `gh` itself; the CLI's backends are tested code.
- **D2** — Shared code location. `orchestrator/lib/trackers/{local,github,body-format}.mjs`, `orchestrator/lib/tracker-config.mjs` and `getTracker()` move to a repo-root `tracker/` directory, installed on every install (any skill) to `.coding-crew/tracker/` and always overwritten, like `docs.scripts` (`install.sh:520-541`); extend `docs.scripts` (or add a sibling registry key) to install a directory tree, and teach `uninstall.sh:243` to remove it. The orchestrator imports it relatively (`orchestrator/lib/x.mjs` → `../../tracker/…`), which resolves the same in source and installed trees (`.coding-crew/crew-afk/lib/x.mjs` → `.coding-crew/tracker/…`). One installed copy, never two. Importers to repoint: `orchestrator/main.mjs:112,119`, `lib/preflight.mjs:16,18`, `lib/loop.mjs:57`, `lib/pipeline.mjs:22,23`, `lib/prd.mjs:13`, `lib/pipeline/finish.mjs:7`, `lib/pipeline/shared.mjs:9`, `lib/tracker.mjs:31-34`, and 13 test files under `tests/` that import `orchestrator/lib/tracker*`. Needed because `to-issues`, `to-prd` and `solve-issue` do not depend on crew-afk (`registry.json`), yet today's `github.mjs` installs only as a crew-afk asset.
- **D3** — CLI entry `tracker/cli.mjs`, called as `node "$(git rev-parse --show-toplevel)/.coding-crew/tracker/cli.mjs" <op> …`, falling back to `$HOME/.coding-crew/tracker/cli.mjs` (the `mark-issue-done.sh` lookup precedent, `docs/templates/trackers/github.md:81-82`). Ops, each dispatched through `getTracker(mainRoot)`:

  ```
  fetch <ref> [--comments]                 → stdout: "# <title>\n\n<body>" (+ comments); exit 3 not found
  prd --feature-slug S                     → stdout: PRD text; exit 3 none   (local: .scratch/S/PRD.md)
  publish-prd --feature-slug S --title T --body-file F   → create or update; stdout: ref; github pins best-effort
  known --feature-slug S --out DIR         → one file per existing feature issue, named by its lint ref
                                              (local: NN-slug.md; github: <n>-<slug>.md)
  publish-issues --feature-slug S --drafts DIR [--replace]   → stdout: one "<draft> <ref>" line per issue
  rewrite <ref> --body-file F --status ST --feature-slug S
  mark-done <ref> [--force]
  ```

  Exit codes for every op: 0 ok, 1 the op failed (stderr carries the tool's own error), 2 usage, 3 not found, 4 re-run blocked by done issues, 5 open issues exist (pass `--replace`).
- **D4** — Draft format, tracker-neutral: each draft is `NN-<slug>.md` opening with `# <title>` and `Status: <status>`, then the issue template body; `## Blocked by` names other drafts by filename or an existing issue by the ref `known` gave it; `deps.json` maps draft filename → blocker filenames. Local writes the draft as-is (refs rewritten); github strips the title and `Status:` lines, using them as `--title` and the status label. `lint-issues.sh` already resolves `## Blocked by` by basename and accepts `--known` (`skills/to-issues/scripts/lint-issues.sh:7-38`), so lint runs on drafts identically for every tracker and the provisional-number step (`gh issue list --limit 1`) is gone.
- **D5** — `publish-issues` creates issues in dependency order from `deps.json` (a cycle exits 1, though lint rejects cycles first) and rewrites each draft ref to the real one before creating its dependents; under github it creates via `createIssue` (milestone ensured, blockers linked: `github.mjs:237-272`). Drafts are deleted after a full publish; on a mid-batch failure it prints the refs already created and exits 1, leaving drafts in place.
- **D6** — Re-runs: under local, `publish-issues` exits 4 when `issues/done/` has files and 5 when `issues/open/` has files without `--replace` (today's `references/rerun.md`); `--replace` overwrites. Github always adds, never exits 4/5. `references/rerun.md` and `references/github-publish.md` are deleted; `to-issues` maps exit 4/5 to the questions `rerun.md` asks today.
- **D7** — `rewrite` serves a single-slice source issue (`to-issues:138`): local overwrites the file at its path; github replaces the body, removes `needs-triage`, adds the status, and sets the milestone after `ensureMilestone` (create, or reopen when closed — #326's version). The `Source:` line stays as written in the new body: `isSourceGuarded` (`orchestrator/lib/trackers/body-format.mjs:113`) accepts a column-0 `Source:` outside a fence anywhere, so no per-tracker position rule exists. (#326 merges first; build on its `ensureMilestone`.)
- **D8** — `mark-done` is one op with both guards once — orchestrator owns the close (`CREW_ORCHESTRATED`, `.scratch/<slug>/.orchestrated`) → exit 3; an unchecked `- [ ]` under `## Acceptance criteria` / `## Cross-cutting Requirements` against a fresh read → exit 4 — then the backend's done write (local: `Status: done` + move to `done/`; github: `awaiting-merge` label, remove `in-progress`, leave open). `--force` skips both guards, as today. Replaces the duplicated guards at `scripts/tracker/mark-issue-done.sh:113,141` (github) and `:224,241` (local). `mark-issue-done.sh` stays, with its argv and exit codes unchanged, as a thin wrapper — callers: `skills/crew-afk/scripts/close-issue.sh:153`, `skills/_shared/fragments/human-issue.md:51`, `orchestrator/lib/loop.mjs:509` (message), and old installs' `issue-tracker.md`.
- **D9** — The `tracker-configuration` fragment (`skills/_shared/fragments/tracker-configuration.md`) is the one place that says how to call the CLI: check `node --version` first and stop with "the tracker CLI needs Node" when absent; name the CLI path; on a CLI failure, report its stderr and fix the cause — never perform the operation with the tracker's own tool. `solve-issue` includes the fragment instead of its own lookup (`skills/solve-issue/SKILL.md:48-49`) and calls `fetch` (`:83`) and `mark-done` (`:325`) through it.
- **D10** — Skill rewrites, naming CLI ops only: `to-issues` (steps 1, 2, 6, 7 and the Security paragraph: `fetch --comments` for an issue ref; `prd` for the PRD; drafts → lint → `publish-issues`; `rewrite`; `deps.json` is the drafts' map, written for every tracker), `to-prd` (`publish-prd`, `:27,29`), `crew-address-findings` (`prd`, `:65-66`; `:89-90` names "the ref `promote-findings.sh` prints"), `upgrade-deps` (`:319-329` points at `to-issues`' step without tracker branches). `skills/crew-afk/SKILL.md:34`'s comment drops its `gh` line.
- **D11** — Templates shrink to front matter, labels, workspace, the list of CLI commands for a person, and (github) the lease/blocked/in-progress notes; the `Operation:` sections go. Old installs keep their stale copies, now unread by skills — harmless.
- **D12** — Label strings are fixed. Drop `docs/templates/trackers/local.md:106` ("Edit the right-hand column…"): no code reads the table (orchestrator and scripts hardcode the strings), so a custom label already broke crew-afk.
- **D13** — `promote-findings.sh`'s github CLI lookup (`skills/crew-afk/scripts/promote-findings.sh:200-206`) points at `.coding-crew/tracker/cli.mjs`; its `create-issue` subcommand stays (`github.mjs:378`), reached through the new CLI. Its `CREW_GITHUB_TRACKER_CLI` override keeps working.
- **D14** — README lists Node as a requirement for tracker-touching skills (today only crew-afk needs it; the github template's `link-blockers` already needed it).

### Trust Boundaries & Risks

- **Issue refs from user arguments** (`fetch`, `rewrite`, `mark-done`): a local ref must resolve (realpath) under `.scratch/` of the main root; a github ref must be all digits. Anything else exits 2 before any read or `gh` call — this replaces the prose rule at `to-issues:16` and its Security paragraph.
- **Exec**: every `gh` call is an argv array through `github.mjs`'s `shellOut` (`github.mjs:65`), never a shell string built from body text; bodies go through `--body-file`. The repo comes only from `readTrackerConfig`.
- **`gh` failure** (unauthenticated, network, missing label): exit 1 with `gh`'s stderr verbatim; nothing retried silently. `link-blockers` and the PRD pin stay best-effort (warn, exit 0).
- **Missing Node**: the fragment's check stops the skill with a message, before any tracker op.

### Compatibility & Migration

- **Install path**: `github.mjs` moves from `.coding-crew/crew-afk/lib/trackers/` to `.coding-crew/tracker/`. Inside this repo only `promote-findings.sh:202-203` and `github.md:65` reference the old path; both move (D13, D11). Old installs' `issue-tracker.md` still names the old path in prose; skills no longer read it.
- **Unchanged contracts**: `mark-issue-done.sh` argv and exit codes (D8); `issues-deps.json` format and location; the issue body format (`## Blocked by` as filenames locally, `Issue #<n>` on github); the `tracker:` front matter.
- **Existing data the new code must accept**: local issue files and `issues-deps.json` under `.scratch/*/issues/` in consuming repos (format: `docs/templates/trackers/local.md:108-124`); github issues in a milestone, including auto-promoted ones whose body opens with `Source: review (<branch>)` (`promote-findings.sh:352`). `known` and `mark-done` read both.
- No expand–contract: crew-afk and the shared `tracker/` install in the same run, always overwritten.

### Testing Decisions

- Test each CLI op on both backends at `tracker/cli.mjs` (exit code, stdout, files written / `gh` argv recorded), with `gh` stubbed through the injected `exec`, following `tests/orchestrator/tracker-github.test.mjs`. Local ops run in a temp `.scratch/`.
- Keep the existing bats suites green as the regression net for moved code: `tests/tracker-mark-done-github.bats` (17), `tests/promote-findings-github.bats` (29), `tests/crew-afk-close-shipped.bats` (15), the orchestrator node tests.
- Rewrite the prose tests that pin `gh` lines in rendered skills — `tests/design-standard-shared.bats` (3), `tests/skill-prose-github-support.bats` (9), `tests/to-issues-enhancement.bats` (6) — to pin the CLI op names instead, and add B6's negative test over every platform's rendered output.
- B7 extends `tests/install.bats`.
- A demo smoke sprint (`scripts/smoke-sprint.sh claude --demo`) before release: `mark-done` and `solve-issue` are on the sprint path.

### Out of Scope

- The crew-afk scripts' github-only branches — `close-shipped.sh`, `issue-labels.sh`, the `session-init.sh` preflight — stay; they are optional capabilities (like `closingRefs`, `orchestrator/lib/tracker.mjs:25-28`), not operations both trackers have.
- A `status-update` op: nothing calls it (no caller in skills, roles or orchestrator).
- A `list` op: the orchestrator calls the backend module directly; skills need only `prd`.
- Switching `promote-findings.sh` to `publish-issues`: its github path already calls code (`create-issue`), and batch re-run semantics do not fit appending one finding; only its lookup path changes (D13).
- A `Source:`-position section or helper: the guard is position-independent (D7).
- Custom label vocabularies (D12).
- Templates as an extension point: after this, `issue-tracker.md` is documentation; a new tracker needs a backend module in this repo.
- `address-pr-comments`' `gh` calls: PR comments belong to the code host, not the tracker.

### Further Notes

- Builds on #326 (`feature/planning-verification`) after it merges: it edits `ensureMilestone`, `github.md`'s `publish` and `to-issues:138`, all of which this replaces.
- Accepted trade-offs: Node becomes required for local-tracker users of the five skills; a `gh` quirk now needs a CLI fix rather than an agent workaround (the agent still sees the error and can fix inputs, auth, or retry).
