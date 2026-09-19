---
name: upgrade-deps
description: >
  Audit outdated npm/yarn/pnpm dependencies across a monorepo — security-advisory
  exploitability, transitive conflicts, real call-site usage, and targeted changelog review
  for major bumps — then publish issues (batched for trivial in-range bumps, one per package
  or coupled group otherwise; every major-version bump defaults to ready-for-human, minor/patch
  range-edits stay ready-for-agent unless a conflict or advisory can't be resolved cleanly)
  with required test additions and a safety checklist, for crew-afk or
  solve-issue to execute. Use when the user wants to upgrade dependencies, audit outdated
  packages, or plan a safe dependency bump. Does not perform the upgrade itself.
---

# Upgrade Deps

Plan safe dependency upgrades and hand them off as issues. This skill never edits
`package.json`/lockfiles or runs the upgrade itself — it analyzes, then files work for
`solve-issue` / `crew-afk` to execute.

Ecosystem support: npm, yarn, pnpm (Node.js). If the repo uses another package manager,
stop and ask the user before proceeding.

## Tracker Configuration

Before any tracker operation, locate `issue-tracker.md` using this lookup chain:

1. `$(git rev-parse --show-toplevel)/.coding-crew/docs/issue-tracker.md` (project-level)

If it does not exist, invoke the `configure-tracker` skill now, then continue. All tracker
operations here use the operation definitions in that file, same as `to-issues`.

Before running any package-manager command (`outdated`, `audit`, `ls`/`why`, or a later
reinstall), use the `dep-install` skill first to detect and lock the session's install mode.
Every command in this skill — not just install — must then run in that mode: if the project
is docker-mode, `outdated`/`audit`/`ls`/`why` run inside the container via the same
mechanism as `test`/`lint`/`typecheck` in `dev-commands.json`, never against the host's
`node_modules`, which may not even exist there.

Also resolve the `typecheck` field from `.coding-crew/dev-commands.json` now, using the same
discovery/cache mechanism `add-tests` uses for its own fields (`bash
scripts/discover-commands.sh`, then `write-commands-cache.sh` if it prompts). Step 6 needs
this to get a mechanical breaking-change signal on major bumps; if it resolves to `null`, that
step falls back to changelog review alone for every major bump — say so when it happens rather
than silently skipping the signal.

## Process

### 1. Determine feature slug

Default to `.scratch/deps-upgrade/`. If it already has issues, ask the user whether to
reuse it (adding more packages to the same batch) or start a fresh dated slug
(`deps-upgrade-YYYY-MM-DD`). Never guess silently.

### 2. Inventory outdated dependencies, per workspace

First check whether the project already has its own wrapper for this — a Makefile target
(`make outdated`, `make audit`) or a script cached in `dev-commands.json` alongside
`test`/`lint`/`typecheck`. If one exists, use it: it already encodes the project's chosen
flags (severity level, workspace scoping, docker routing) — don't invent a raw
package-manager invocation that bypasses it.

Otherwise, find every `package.json` in the repo (including workspaces/monorepo packages)
and run the manager-appropriate outdated command:

- npm: `npm outdated --json`
- yarn classic: `yarn outdated --json` — in practice this often doesn't emit clean JSON;
  if it errors or the JSON doesn't parse, fall back to the plain-table output and parse that
  instead of forcing `--json`.
- yarn berry: `yarn outdated`
- pnpm: `pnpm outdated --format json`

For every package, record **Current**, **Wanted** (highest version satisfying the existing
declared range), **Latest**, and every workspace that declares it. A package declared with
different ranges in different workspaces is one row with multiple workspace entries, not
several separate findings.

Classify each package as:

- **In-range** — `Latest` (or the version you intend to move to) already satisfies the
  declared range, so `Wanted == Latest` and no `package.json` edit is needed, only a
  reinstall. This holds regardless of how large the absolute version jump looks (e.g. an
  SDK that reved hundreds of releases without a major bump) — trust the semver contract, but
  still verify it with the batch issue's real test run in step 7, not a rubber stamp.
- **Range-edit** — `Latest > Wanted`, so moving to `Latest` requires bumping the declared
  range in `package.json`. These need individual analysis (steps 4–6) before filing.

### 3. Run a security audit and check exploitability

Prefer the project's own audit wrapper if one exists (same check as step 2 — a Makefile
target often bakes in a severity threshold, e.g. `moderate`, that you should not silently
loosen or tighten). Otherwise run the manager's audit command directly (`npm audit --json`,
`yarn audit --json` / `yarn npm audit --json` for berry, `pnpm audit --json`) and
cross-reference advisories against the inventory from step 2.

Cross-referencing against step 2 alone misses any advisory on a package that never appears
there — a transitive-only dependency (e.g. `follow-redirects` pulled in by `axios`) has no
row of its own in step 2 but can still carry its own CVE. After cross-referencing, scan the
raw audit output a second time for every advisory whose package has no matching step-2 row,
and file those too. For each: name the direct dependency (or dependencies) that pull it in,
and check whether another issue already in this batch resolves it as a side effect of its
own bump (e.g. bumping `axios` to a version that vendors a fixed `follow-redirects`) — if so,
say which issue and don't file a duplicate; if not, file it on its own per the CVE rule below.

For every advisory hit:

- Note the fixed version and whether reaching it is an in-range or range-edit move. If the
  advisory's fixed-in version happens to be a higher major than the package's current major,
  don't infer from the version number alone that no patched release exists on the current
  major — confirm it against the advisory's own affected-range statement or `npm view <pkg>
  versions`/the registry, since a patch can and sometimes does land as a backport on the
  older major too.
- Check real exploitability, don't just trust the severity label: grep the codebase for the
  vulnerable function/feature named in the advisory (e.g. a specific parser, propagator, or
  option). If it's never invoked, say so explicitly and treat the bump as lower priority
  despite the advisory; if it's reachable, treat it as high priority regardless of semver
  size.
- A CVE-driven package always gets its own issue (or joins a coupled group) — never folds
  into the in-range safe-batch from step 6, even if the fix happens to be in-range, so its
  advisory-clean re-check (step 7) isn't buried in an unrelated batch.

### 4. Map transitive impact (range-edit packages only)

For each range-edit candidate, check the wider tree before treating the bump as isolated:

- `npm ls <pkg>` / `pnpm why <pkg>` / `yarn why <pkg>` — every version of `<pkg>` currently
  pulled in, and by which direct dependencies. This is inventory only — it shows today's
  tree, not what happens after the bump.
- Then get a mechanical, resolver-verified answer instead of inferring conflicts from that
  tree by eye: simulate the bump and let the package manager's own resolution fail loudly if
  it can't be satisfied.
  - npm: `npm install <pkg>@<target> --package-lock-only --dry-run` — resolves the full tree
    without touching `node_modules`; nonzero exit with `ERESOLVE` output means a real
    peer/transitive conflict, not a guess.
  - pnpm: `pnpm add <pkg>@<target> --lockfile-only` (run against a scratch copy of the
    workspace, since this does write a new lockfile) — pnpm's stricter peer resolution fails
    the same way.
  - yarn berry: `yarn up <pkg>@<target> --mode=update-lockfile` — updates the lockfile only
    and reports resolution failures without installing.
  - Run this in whatever mode step 1's `dep-install` locked (host or docker), same as every
    other command in this skill.
- Treat a clean dry-run/lockfile-only resolution as the actual conflict-clean finding for
  step 7's safety checklist — not the `ls`/`why` inventory, which can't see the post-bump
  state. If you can't get a clean resolution, don't guess — this pushes the issue to
  `ready-for-human` in step 7.
- Identify packages that must move together (e.g. a plugin and its peer host, or a family
  like `@opentelemetry/core` + `sdk-metrics` that don't mix major versions) — these become
  **one** issue, not several, in step 6. Also identify build-tool coupling that isn't a
  version constraint but still needs sequencing (e.g. a formatter's flat-config support
  landing only after the linter's own flat-config migration) — express these as `Blocked by`
  edges between issues, not merged groups.

### 5. Scan the codebase for actual usage (range-edit packages only)

For each range-edit candidate, grep the repo (all workspaces) for real call sites:

- `import ... from '<pkg>'`, `require('<pkg>')`, dynamic imports, re-exports.
- Record each call site as `file:line` plus which exported API is used there (e.g.
  "`axios.get(...)` at `apps/foo/client.ts:31`") — vague "imports the package" isn't enough.
- Also check test files: a test that mocks or mutates the package's exports directly (e.g.
  reassigning `pkg.method = jest.fn()` instead of `jest.mock('pkg')`) is itself a call site
  and often the most fragile one across a major bump.
- A package with zero call sites (transitive-only, or unused) skips straight to a lighter
  issue: no usage-test requirement, just the safety checklist — call this out explicitly
  (e.g. "unused" grouping) rather than filing it like a normal bump.

### 6. Mechanical impact signals — major bumps only

Skip this step for patch/minor range-edit bumps; go straight to drafting. For every **major**
version bump, run these signals in order — each is cheaper/more decisive than the next, and a
decisive answer from an earlier one doesn't excuse skipping the later ones, since they catch
different failure classes. **6a is a required minimum for every major bump — it is nearly
free (no worktree, no install) and skipping straight to a changelog text search (6e) is not a
substitute for it.** 6b–6d are not optional-in-practice either: attempt each and state its
result in the issue, even when that result is just "skipped because X" (no types available,
repo unreachable, tags unresolvable) — a silent omission reads as "not checked," which is
indistinguishable from "checked and clean" to whoever picks up the issue next.

**6a. Tarball diff — is there even a code change?** The cheapest, most decisive check: many
"major" bumps only move for a `package.json` metadata reason (dropped Node engine support,
loosened a peer range) and ship no code diff at all.

- `npm pack <pkg>@<current>` and `npm pack <pkg>@<target>` (or the yarn/pnpm equivalent) into
  a scratch temp dir — this downloads tarballs only, touches no project file, needs no
  worktree.
- Extract both and diff recursively, excluding only the `version` field's value inside
  `package.json` and non-code files (`README*`, `CHANGELOG*`, `HISTORY*`, `LICENSE*`, `docs/`).
  Everything else — including other `package.json` fields like `exports`/`main`/`engines` —
  counts as a real difference.
- If the diff is empty: state plainly "no code changes between vX and vY, only
  metadata/docs differ" — this is a **provable absence of impact**, not an inferred one, and
  feeds the status exception below.
- If the diff is non-empty, list the changed files and move on to 6b; don't try to eyeball
  runtime significance from a raw diff here.

**6b. Structural API diff.** If 6a found real code changes and the package ships its own type
declarations (or has a matching `@types/<pkg>`):

- Extract each version's declared types (via `package.json`'s `types`/`typings` field, or the
  matching `@types` package) and diff exported members — functions, classes, interfaces,
  types — restricting attention to the exports actually used in step 5's call sites.
- Any call-site export that was removed, renamed, or had its signature changed is a
  **confirmed breaking change** — cite the exact export and call site.
- No types available: say so and skip to 6c; don't substitute a guess.

**6c. Breaking-change commit mining.** If the package's declared repository is reachable via
WebFetch (never an arbitrary URL — only that declared repo) and the current/target versions
resolve to git tags there:

- List commits between the two tags whose subject/body contains a `BREAKING CHANGE:` footer
  or a conventional-commit `!:` marker (`feat!:`, `fix!:`, etc.) — this is a structured signal
  a hand-maintained changelog file can omit even when the project otherwise follows
  conventional commits.
- For each hit, note whether it names an export/API found in step 5's usage; if you can't map
  a commit to a specific export, list it anyway and say the mapping is uncertain rather than
  dropping it.
- Tags unresolvable or repo unreachable: say so explicitly and skip.

**6d. Worktree-verified typecheck/test/lint.** Create **one** disposable git worktree off the
current branch, bump this package/group to `<target>` there, reinstall, and run whichever of
`typecheck`/`test`/`lint` resolved to real commands (Tracker Configuration for `typecheck`,
step 1 discovery for the others) in that worktree — same host/docker mode `dep-install`
locked. Delete the worktree immediately after collecting all results.

- This is the one exception to the "never modify package.json/lockfiles" rule in `## Never`:
  the edit exists only inside the disposable worktree and is never merged, committed to a
  real branch, or left behind.
- Report each command's pass/fail; on failure, cite the exact failing test/lint rule and
  location, not just "tests failed."
- A clean run is evidence the existing test suite's coverage holds up under the bump, not
  proof of full behavioral safety — a suite with gaps stays silent on exactly the behavior it
  doesn't exercise. State it as "typecheck/test/lint clean," never round it up to "no breaking
  changes."

**6e. Changelog review (text search — last resort for anything 6a–6d didn't already prove).**

- Don't diff the whole changelog. Search it (shipped `CHANGELOG.md`/`HISTORY.md` inside the
  package, or its declared repository's release notes via WebFetch — never an arbitrary URL)
  specifically for entries naming the exports/APIs found in use in step 5.
- Report findings honestly and specifically: "no entry found naming `<API>`" is evidence of
  absence for that name, not proof of safety — say so, especially when the version span
  crosses more than one major stabilization or the diff is too large to review
  entry-by-entry. Don't launder that uncertainty into a clean "no breaking changes" claim.
- If the changelog can't be located at all for a major bump with real usage, say so
  explicitly rather than silently treating it as safe.

### 7. Decide status and draft issues

**Batch all in-range packages from step 2 into one issue** (`01-safe-batch` or similar),
minus any CVE-driven package pulled out in step 3. Table columns: Package, Current, Wanted,
Workspace(s). Acceptance criteria: reinstall via the package manager (never hand-edit the
lockfile), full typecheck/lint/test/build green, audit re-check clean. `Status:
ready-for-agent`.

**Draft one issue per range-edit package or coupled group** (per step 4's grouping). Order
so bumps with clean transitive resolution and confined, changelog-covered usage are
dispatched first; sequence anything blocked by another package's move behind it.

Each range-edit issue must include:

- Table of package(s), Current → Latest, and every workspace affected
- Why it's being bumped: version-currency, or (if from step 3) the CVE id, fixed-in version,
  and the exploitability finding
- Usage found: the exact call sites from step 5
- Mechanical impact signals (major bumps only): the findings from step 6a–6e in order —
  tarball diff, API diff, breaking-change commits, worktree typecheck/test/lint, changelog —
  each stated with its actual confidence, not rounded up to "safe"
- Transitive conflicts from step 4 and how this issue resolves them
- Every call site from step 5 as its own acceptance-criterion line requiring a new or
  updated test exercising it
- The safety checklist below, as acceptance criteria

**Safety checklist (required on every non-batch issue):**

- [ ] Full test suite passes after the bump
- [ ] Typecheck/build passes after the bump
- [ ] New/updated tests added for every impacted call site listed above
- [ ] No peer-dependency or transitive version conflicts remain (dry-run/lockfile-only
      resolution from step 4 clean, re-verified after the real bump)
- [ ] If this bump addresses a security advisory, the audit command shows it resolved

**Status decision.**

- Any **major**-version range-edit bump — or a coupled group containing one — defaults to
  `Status: ready-for-human`, regardless of how cleanly steps 3–6 came back. A major bump only
  guarantees the package's own declared semver contract, not that a coder will notice a
  subtlety a diligent review happens to catch (e.g. a test that mutates an export directly
  becoming fragile under a new dual CJS/ESM build). Don't compute your way out of this with a
  clean per-case risk score — treat "every check passed" as the normal case for a major bump
  needing a human, not an exception to it. This is about behavior that *did* change and every
  proxy check happened to miss it — a false negative your checks can't rule out, so it stays
  human-gated no matter how many checks came back clean.
  - **Exception — zero-code-impact major.** If 6a's tarball diff found **no code changes at
    all** between current and target (only metadata/docs differ), and 6b found no confirmed
    export break, and 6c found no unmapped `BREAKING CHANGE` commit touching a used export,
    and 6d's available checks (typecheck/test/lint) all ran clean — downgrade to `Status:
    ready-for-agent`. This is not the same exception the paragraph above forbids: there, the
    checks are proxies for behavior that could still have changed underneath them; here, 6a
    has already proven the shipped artifact itself didn't change, so there is no behavior left
    to have changed. State this reasoning explicitly in the issue ("major version bump, zero
    code diff between vX and vY per tarball comparison") so a reviewer can verify the claim
    without redoing the diff.
  - **"It's just a dev-tool/config dependency, no runtime impact" is not grounds for
    downgrading a major bump's status on its own** — that reasoning is about *blast radius*,
    not about whether behavior changed, and it isn't one of the checks above. A lint/build
    tool major can still hide a judgment-call regression a mechanical check won't catch (e.g.
    a coder mass-suppressing lint rules just to get `make lint` green again after a ruleset
    bump). Only the zero-code-impact exception above downgrades a major; "it's just eslint"
    by itself doesn't.
- **Minor/patch** range-edit bumps default to `Status: ready-for-agent`, unless any of these
  hold, in which case escalate to `ready-for-human` and say which:
  - Step 4 found a transitive/peer conflict with no clean resolution
  - Step 3 found a CVE fix whose exploitability check was inconclusive

Either way, state the reasoning in the issue body — what was checked and what the finding
was — so whoever picks it up (human or coder) knows what's already been verified. Use the
same issue body template as `to-issues` (Context Documents / What to build / Acceptance
criteria / Blocked by / Interfaces where relevant).

### 8. Publish

Execute the `publish` operation from `issue-tracker.md` for each issue, same as `to-issues`.
Write `.scratch/<slug>/issues/issues-deps.json` with the same blocker map so the crew-afk
orchestrator can resolve dispatch order without re-parsing prose.

### 9. Summarize

Print a short table: package(s), current → target, risk (low/med/high), status
(ready-for-agent/ready-for-human), issue filename.

## Never

- Never modify `package.json`, lockfiles, or `node_modules` in the working tree or on any
  real branch — this skill only plans and files issues; execution belongs to `solve-issue` /
  `crew-afk`. The one exception is the disposable git worktree from step 6d: created, bumped,
  and deleted entirely within that sub-step, never merged and never left behind. Step 6a/6b's
  tarball diffing downloads to a scratch temp dir and never touches a worktree at all.
- Never mark a range-edit issue `ready-for-agent` when the status-decision criteria in step 7
  call for `ready-for-human` — escalating uncertainty to a human beats a coder silently
  trusting an incomplete changelog check.
- Never fold a CVE-driven bump into the in-range safe-batch — its advisory-clean re-check
  needs to be verifiable on its own.
- Never mark an upgrade issue `ready-for-agent` without the safety checklist and, if there
  are impacted call sites, their required test additions.
