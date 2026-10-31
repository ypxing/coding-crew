---
name: upgrade-deps
description: >
  Plans npm/yarn/pnpm dependency upgrades: audits outdated dependencies across a monorepo (security-advisory
  exploitability, transitive conflicts, real call-site usage, and targeted changelog review for major bumps),
  then publishes issues through to-issues (batched for trivial in-range bumps, one per package or coupled group otherwise; every major-version bump
  defaults to ready-for-human, minor/patch range-edits stay ready-for-agent unless a conflict or advisory
  can't be resolved cleanly) with required test additions and a safety checklist. Use when the user wants to
  upgrade dependencies, audit outdated packages, or plan a safe dependency bump. Does not perform the upgrade
  itself.
disable-model-invocation: true
---

# Upgrade Deps

Plan safe dependency upgrades and hand them off as issues. This skill never edits the checkout's
`package.json` or lockfiles and never performs an upgrade: it gathers evidence, then files issues whose
bodies say what was checked and how sure each finding is, so whoever picks one up does not redo the
analysis or mistake "not checked" for "clean".

Ecosystem support: npm, yarn, pnpm (Node.js). If the repo uses another package manager,
stop and ask the user before proceeding.

<!-- fragment:missing-library -->
**Shared scripts.** The scripts this skill runs live in the `coding-crew-lib` skill, installed beside it at
`<skill-dir>/../coding-crew-lib` (`<skill-dir>` being the directory you read this file from). Before the first
command that runs one, check that directory exists. If it does not, stop and tell the user to install it from the
source and at the scope they installed this skill from (`npx skills add <that source> -s coding-crew-lib`, adding
`-g` when this skill is installed at user level), or to re-run coding-crew's `install.sh`.
<!-- /fragment:missing-library -->

<!-- fragment:tracker-configuration -->
## Tracker Configuration

Every tracker op runs through the tracker CLI, `TRACKER=<skill-dir>/../coding-crew-lib/scripts/tracker/cli.mjs` (`<skill-dir>` being the
directory you read this file from), as `node "$TRACKER" <op> …`; nothing else reads or writes the tracker. Before the
first op run `node "$TRACKER" config` (prints `tracker=<kind>` and `configured=yes|no`). On `configured=no` on an
interactive run, invoke the `configure-tracker` skill, then continue; on a non-interactive run (a headless/`-p`
invocation or a subagent) never ask: proceed as `local`. The tracker's refs, statuses and labels are in
`<skill-dir>/../coding-crew-lib/scripts/tracker/docs/<kind>.md`.

Exit codes, every op: 0 ok; 3 not found; on 1 (the op failed) or 2 (a usage error or an invalid ref), report the
stderr verbatim, fix its cause (an input, auth, the network) and re-run the op, never performing it with the tracker's
own tool. `publish-issues` adds 4 and 5, which the skill that publishes handles.
<!-- /fragment:tracker-configuration -->


## Running commands

`PROJECT_ROOT` is the repo root, `git rev-parse --show-toplevel`; carry it as a literal, since each
bash call is a fresh shell. Every project command — the package manager's and the checks — runs
through the checks library, which runs it where the dev commands file's install mode says (in docker
mode the host may have no `node_modules` at all):

```bash
bash "<skill-dir>/../coding-crew-lib/scripts/checks/run.sh" --project-root "$PROJECT_ROOT" -- "<command>"
```

Do not install up front. Only when a command fails for a missing dependency invoke the `dep-install`
skill, with `PROJECT_ROOT` set, then retry that command once.

The checks come from the dev commands file (`bash "<skill-dir>/../coding-crew-lib/scripts/checks/commands-file.sh"
--project-root "$PROJECT_ROOT"` prints its path): run `(cd "$PROJECT_ROOT" && bash
"<skill-dir>/../coding-crew-lib/scripts/checks/discover-commands.sh")` first and follow its prompt, if it prints one.
With `typecheck` null, major bumps lose their mechanical breaking-change signal: say so in each issue
it affects.

When the project has its own outdated or audit wrapper (a Makefile target, a dev commands entry), use
it: it carries the project's severity threshold and workspace scoping, which you neither loosen nor
tighten.

## Process

### 1. Determine feature slug

`deps-upgrade`, unless `node "$TRACKER" features` (one `<slug>\t<open|closed>\t<ready-count>` line
per feature) already lists it: then ask the user whether to add to that feature or start a fresh
`deps-upgrade-YYYY-MM-DD`. Never pick silently.

### 2. Inventory

Every package outdated in any workspace, with **Current**, **Wanted** (the highest version its declared
range allows), **Latest** and every workspace that declares it — one row per package, however many
workspaces or ranges declare it. Classify each:

- **In-range** — Latest satisfies the declared range, so only a reinstall moves it, however large the
  jump looks: the semver contract is trusted here, and the batch issue's real test run verifies it.
- **Range-edit** — moving to Latest needs a new declared range. Steps 4–6 analyse these.

### 3. Advisories

Every advisory the audit reports is accounted for, including those on transitive-only packages with no
inventory row (a `follow-redirects` advisory pulled in by `axios`): name the direct dependencies that
pull it in, and when another bump in this batch already fixes it, say which instead of filing a
duplicate. For each advisory:

- **Fixed version**, and whether reaching it is in-range or a range-edit. A fix listed only on a higher
  major does not prove the current major has none: confirm against the advisory's affected ranges or
  the registry's published versions, since backports happen.
- **Exploitability**: whether the code reaches the function or option the advisory names, with the
  call site, or the search that found none. That function comes from the advisory's own text or its
  fix, never its title or a guess: with neither at hand, the finding is inconclusive. Reachable is
  high priority whatever its semver size; unreachable is lower priority, said explicitly.

An advisory-driven package gets its own issue (or joins its coupled group), never the in-range batch,
even when its fix is in range, so its audit re-check is not buried in unrelated bumps.

### 4. Conflicts and coupling (range-edit packages)

- **Conflicts** — whether the bump resolves, as the package manager's resolver answers on a dry run or
  lockfile-only update (on a scratch copy when that writes a lockfile, its commands run with
  `--project-root` set to that copy), never inferred from today's `ls`/`why` tree, which cannot see the
  post-bump state. A clean resolution is the issue's
  conflict-clean evidence; a failed or unobtainable one makes it `ready-for-human` (step 7).
- **Coupled groups** — packages that must move together (a plugin and its host, a family such as
  `@opentelemetry/*` that does not mix majors) are one issue.
- **Sequencing** — tooling that is not version-coupled but must move in order (a formatter's
  flat-config support landing after the linter's migration) is a `Blocked by` edge between issues, not
  a merged group.

### 5. Call sites (range-edit packages)

Every use of the package across all workspaces, as `file:line` plus the export used ("`axios.get(...)`
at `apps/foo/client.ts:31`"; "imports the package" is not enough). Tests that mutate the package's
exports directly (`pkg.method = jest.fn()` rather than `jest.mock('pkg')`) are call sites too, and
often the most fragile across a major. A package with no call sites gets a lighter issue — the safety
checklist, no usage tests — labelled unused.

### 6. Breaking-change evidence (major bumps only)

Each major bump's issue reports all five of these, each with what it found or why it could not be
obtained ("no types shipped", "tags not in the repo"). A silent omission reads as "checked and clean".

- **a. Code diff** — whether the published tarballs of the two versions differ in anything but the
  `version` field and docs (`README*`, `CHANGELOG*`, `HISTORY*`, `LICENSE*`, `docs/`); `exports`,
  `main`, `engines` and every other manifest field count. No difference proves no impact; otherwise list
  the changed files.
- **b. API diff** — each export step 5 found in use that the declared types (shipped or `@types/<pkg>`)
  removed, renamed or re-signed: a confirmed break, cited with its call site.
- **c. Breaking commits** — commits between the two versions' tags in the package's declared
  repository marked `BREAKING CHANGE:` or `!:`, each mapped to a used export or listed as unmapped.
- **d. Checks under the bump** — `typecheck`, `test` and `lint`, as the dev commands file holds them,
  run with the bump applied and reinstalled in one disposable git worktree, every command with
  `--project-root` set to that worktree (never `$PROJECT_ROOT`, whose tree is unbumped), removed once
  the results are in: the only place this skill changes a manifest or lockfile. A failure names the
  test or rule and its location. A clean run is "typecheck/test/lint clean", never "no breaking changes": the suite is silent on what it
  does not exercise.
- **e. Changelog** — entries naming the used exports, in the package's shipped changelog or its
  declared repository's release notes. "No entry names `<API>`" is absence of evidence, said as such,
  and a changelog that cannot be found is said too.

Fetch only from a package's declared repository and the registry, never any other URL.

### 7. Decide status and draft issues

**The in-range batch** — one issue (`01-safe-batch` or similar) for every in-range package except the
advisory-driven ones. Table columns: Package, Current, Wanted, Workspace(s). Acceptance criteria:
reinstall via the package manager (never hand-edit the lockfile), full typecheck/lint/test/build green,
audit re-check clean. `Status: ready-for-agent`.

**One issue per range-edit package or coupled group**, ordered so clean-resolving, confined bumps come
first and anything sequenced behind another package's move is blocked by it. Each carries:

- the package table: Current → Latest, every workspace affected
- why: currency, or the advisory id, fixed-in version and exploitability finding
- the call sites from step 5
- step 6's five findings (major bumps), each at its actual confidence, never rounded up to "safe"
- the conflicts from step 4 and how this issue resolves them
- one acceptance criterion per call site, requiring a new or updated test that exercises it
- the safety checklist, as acceptance criteria:
  - [ ] Full test suite passes after the bump
  - [ ] Typecheck/build passes after the bump
  - [ ] New/updated tests added for every impacted call site listed above
  - [ ] No peer-dependency or transitive version conflicts remain (resolution from step 4 clean,
        re-verified after the real bump)
  - [ ] If this bump addresses a security advisory, the audit command shows it resolved

**Status decision.**

- **Major** — a major range-edit bump, or a coupled group containing one, is `ready-for-human`
  however cleanly steps 3–6 came back: each is a proxy that can miss a behaviour change, so "every
  check passed" is the normal case for a major, not an exception to it. "It's only a dev tool" changes
  nothing either: that is blast radius, not whether behaviour changed (a linter major invites a
  mass-suppressed ruleset). The one exception is **zero code impact**: 6a found no code difference, 6b
  no confirmed break, 6c no breaking commit touching a used export and none left unmapped, and 6d's
  checks ran clean. Then it is `ready-for-agent`, with that reasoning in the issue ("major version bump, zero code diff between
  vX and vY per tarball comparison") so a reviewer can verify it without redoing the diff.
- **Minor/patch** — `ready-for-agent`, unless step 4 found a conflict with no clean resolution or step
  3's exploitability check was inconclusive: then `ready-for-human`, saying which.

A `ready-for-human` draft is published as to-issues' Kind B: the bump stays agent work, the person's
steps are the review of the impacted call sites, and the last step relabels the issue
`ready-for-agent` so an agent makes the bump.

Every body states what was checked and what each check found, in the same issue body template as
`to-issues` (Context Documents / What to build / Acceptance criteria / Blocked by / Interfaces where
relevant).

### 8. Publish

Write the drafted issues from step 7 to one file, `.coding-crew/scratch/<feature-slug>/upgrade-drafts.md`
(the slug from step 1): one section per issue, each with its `Status:` line per step 7's decision
(`ready-for-agent` or `ready-for-human`) and its `## Blocked by` naming the blocking draft (the
`Blocked by` edges from step 4's coupling analysis).

Then invoke the `to-issues` skill with that file as its source and the slug from step 1. Say that the
slicing is done: each section is one issue, and its status and blocking edges are decided.
`to-issues` writes, checks and publishes them, its questions included. Do not run its steps or its
scripts yourself. Once it has published them, delete `upgrade-drafts.md`: nothing else does, and an
untracked file left in the checkout fails a later run that needs a clean tree. If it stopped before
publishing, keep the file for the re-run.

### 9. Summarize

Print a short table: package(s), current → target, risk (low/med/high), status
(ready-for-agent/ready-for-human), the issue ref `to-issues` published.

