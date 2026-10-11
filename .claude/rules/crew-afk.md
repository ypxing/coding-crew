---
paths:
  - "orchestrator/**"
  - "skills/crew-afk/**"
  - "tests/orchestrator/**"
  - "tests/orchestrator*.bats"
  - "tests/crew-afk*.bats"
---

# crew-afk internals

Invariants of the orchestrator and its scripts that the code does not show on its own. Loaded when
working on crew-afk; the repo-wide rules are in `CLAUDE.md`. Each script's header says what it does.

## Contracts between files

- **Scripts** (`skills/crew-afk/scripts/`) are effects `orchestrator/lib/effects.mjs` invokes, each runnable by hand. They
  take their sprint from `--feature-slug` or the env the orchestrator exports (`FEATURE_SLUG`, `STATE_FILE`, `TRACE_LOG`,
  `SPRINT_DIR`); several sprints run in one repo, so there is no repo-wide pointer.
- **One writer each:** `close-issue.sh` is the only writer of an issue's `Status:`; `issue-labels.sh` the only writer of
  crew-afk's status labels under `tracker: github`.
- **`session-init.sh` never checks the feature branch out.** `merge-branches.sh`, `sync-feature-branch.sh` and
  `squash-commits.sh` run in the `crew/<slug>/_feature` worktree (`Effects.featureRoot`), refuse to run anywhere but on
  the feature branch, and never switch a checkout.
- **Tracker access from scripts** goes through `tracker-cli.sh` (sourced); a missing CLI or `node` fails the caller, never a
  silent `local`. MAIN_ROOT outside the orchestrator comes from `main-root.sh`, the same rule as `main.mjs`'s `gitRoot()`.
- **`ensure-deps.sh` is mechanism, not a skill read,** because `verify-worktree.sh` is a gate and cannot invoke a skill;
  both delegate every install decision to `dep-install`'s scripts.
- **Draft marker:** a not-green PR's crew-afk block carries `<!-- crew-afk:draft <kinds> -->` (`draftMarker` in
  `loop.mjs`), `<kinds>` a subset of `findings,review,blocked,stalled,capped,wall-cap,integration`. `open-pr.sh` writes it
  and `<!-- crew-afk:slug <slug> -->`; `/address-pr-comments` reads both, so a change to either side changes the other.
- **`prdPath(ctx)`** (`orchestrator/lib/prd.mjs`) is the one owner of where the feature's intent lives; the per-branch
  review, the feature review and the PR writer all take the path from it, never from the branch name.

## Ordering

- **Per issue:** worktree → `.worktreeinclude` → deps → worker dispatch → verify → review → AC receipt → merge → close.
  Deps sit where they precede both consumers, the worker and the verify gate. A retry skips any gate whose receipt
  already matches the branch tip (`gatesAtTip`); the AC receipt names the reviewed sha, so a branch that moved during
  review is stale.
- **Concurrency:** minutes-long effects (verify, deps) go through `Effects.bashAsync`, so workers verify concurrently;
  merge and close stay on the blocking `effects.bash`, which is what serializes merges into the feature branch.
- **Once per run, before any dispatch** (`preflight.mjs`): sync `origin/<default>` into the feature branch, drop stale
  retained records, check the install assets, lint the open issues, probe `## Requires`. The baseline check runs
  alongside the first dispatches, but no verify starts before its verdict, and a red one stops the run.
- **At every drain** the integration check runs on the merged feature branch; a red one blocks `openPr`. The feature
  review runs once per drain loop, after the integration check, at the first green drain where something merged; the
  closing review after the loop is report-only and never creates a second fix issue.
- **A check that modifies the tree fails**, in the baseline and every verify.

## Gates and reviews

- The per-branch review is a criteria gate: it writes `findings: []`, and `pipeline/review.mjs` drops any findings a
  branch report still carries. Findings come only from the feature review. A per-branch reviewer's out-of-criteria
  concerns travel as `notes` to the next feature review. Known limit: `featureNotes` keeps notes whose `reviewed_sha` the
  range reaches, and `afk.squashCommits` rewrites a run's merges into one commit, so a later run's whole review loses the
  notes of an earlier squashed run whose own feature review did not list them (failed or skipped). Documented, not fixed.
- Reviewer, triage and feature-review dispatches are read-only by snapshot (`pipeline/shared.mjs`'s `readOnlyDispatch`):
  any change to a `crew/<feature>/*` ref, the feature branch or `_feature` fails the dispatch closed. Changes the
  orchestrator's own concurrent effects made are excluded (`refActivityMark` / `refActivitySince`).
- A retained branch is synced with the feature branch before its retry; a conflict `resolve-merge-conflicts.sh` cannot
  settle (anything beyond registry versions and CHANGELOG appends) gets one conflict-only coder dispatch, judged from
  git, not its report.
- An issue a human edited since its branch was retained (fingerprint of `## What to build` and `## Acceptance criteria`)
  turns a `fix` or `verify` retry into `restart`.

## The feature agent (`orchestrator/lib/pane-host/`)

Under orca or herdr, one interactive agent per slug runs in `_feature` with the rendered `orchestrator/roles/followup.md`.
Its handle is `.scratch/<slug>/watch.json`, and every push targets `effects._paneWatch.handle` — nothing else reads
`ORCA_TERMINAL_HANDLE` / `HERDR_PANE_ID` for a push. Nothing closes the agent: while one is live, `_feature` and the
workspace are kept, and a failed create only warns and leaves the exit code unchanged. A pane-host adapter implements
`openWatch`, `watchAlive`, `notify(effects, handle, message)` and `launcherHandle`.

## Adding a new crew-afk role

1. `orchestrator/roles/<role>.md` — the protocol (whole-line `{{FRAGMENT:<key>}}` and `{{PLATFORM}}` expand at dispatch).
2. Map it in `ROLE_AGENTS` (`orchestrator/lib/adapters/render.mjs`) and give it a `ROLE_POLICY` entry next to it
   (`readOnly`, `subagents`, `effort`); each adapter's `policyArgs` turns that into its CLI's flags. A role that is not
   dispatched but started interactively (the `followup` feature agent) goes through the adapter's `interactive()` instead of `build()`.
3. `TARGET_REPO=/tmp/test-repo ./install.sh claude --skill crew-afk` and inspect `.coding-crew/crew-afk/roles/`.

## Adding a platform

A platform is one data entry and one adapter; everything else (the platform list, `--platform` validation and help,
skill lookup, capability checks, the squash trailer) is derived from those two.

1. **Data entry** — add `<platform>` to `orchestrator/platforms.json`: `projectSkills`, `userSkills`, `configDir`,
   `configDirEnv` (where the platform keeps skills; a user-scope dir under `configDir` moves to `$<configDirEnv>`).
2. **Adapter** — `orchestrator/lib/adapters/<platform>.mjs`, registered in `adapters/index.mjs`'s `ADAPTERS`, implementing
   the contract: `cmd`, `defaultParallel`, `defaultModel`, `coAuthor` (the squash commit's trailer line), `requiredFlags`,
   `helpArgs?` (doctor), `build(spec) -> { args, input? }` (spec: `cwd`, `mainRoot`, `model`, `policy`, `protocol` and
   `protocolFile` — the rendered protocol as text and as `<outFile>.protocol.md` — `prompt`, `outFile`, `label`),
   `policyArgs(policy)` (a `ROLE_POLICY` entry → flags), `interactive({cwd, mainRoot, model, protocol, policy})`
   (the CLI's interactive argv, `cmd` first, the protocol as its initial prompt: the feature agent), `finalText(lines)`, `normalize(evt)` (a raw event → the
   one shape trace, pane text and deviation detection read; an array when one raw event holds several tool calls); optional
   capabilities `liveText`, `resume(id)`, `budget(usd)`, `resultMeta(lines)`, `env`, `modelTiers`, `modelAliasEnv`. A capability the
   adapter lacks is off for that runtime (no resume, `afk.limits` reported ignored), never a name check elsewhere.
3. **Conformance test** — `node --test tests/orchestrator/platforms.test.mjs` fails, naming the platform, until both exist
   and the adapter has every required field; pin its `policyArgs` per role and its `interactive` argv there, and add its dispatch golden
   (`UPDATE_GOLDEN=1 node --test tests/orchestrator/platform-golden-dispatch.test.mjs`).
4. **Smoke run** — `scripts/smoke-sprint.sh <platform>`: one real sprint on the CLI.
