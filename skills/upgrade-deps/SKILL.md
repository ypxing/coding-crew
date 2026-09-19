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
  still verify it with a real test run in step 6, not a rubber stamp.
- **Range-edit** — `Latest > Wanted`, so moving to `Latest` requires bumping the declared
  range in `package.json`. These need individual analysis (steps 4–6) before filing.

### 3. Run a security audit and check exploitability

Prefer the project's own audit wrapper if one exists (same check as step 2 — a Makefile
target often bakes in a severity threshold, e.g. `moderate`, that you should not silently
loosen or tighten). Otherwise run the manager's audit command directly (`npm audit --json`,
`yarn audit --json` / `yarn npm audit --json` for berry, `pnpm audit --json`) and
cross-reference advisories against the inventory from step 2.

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
  pulled in, and by which direct dependencies.
- Flag cases where bumping a direct dependency would leave some transitive consumer pinned
  to an incompatible peer/major version (a likely `ERESOLVE` or duplicate-major situation).
  If you can't find a clean resolution, don't guess — this pushes the issue to
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

### 6. Targeted changelog review — major bumps only

Skip this step for patch/minor range-edit bumps; go straight to drafting. For every **major**
version bump:

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
- Changelog check (major bumps only): the findings from step 6, stated with their actual
  confidence, not rounded up to "safe"
- Transitive conflicts from step 4 and how this issue resolves them
- Every call site from step 5 as its own acceptance-criterion line requiring a new or
  updated test exercising it
- The safety checklist below, as acceptance criteria

**Safety checklist (required on every non-batch issue):**

- [ ] Full test suite passes after the bump
- [ ] Typecheck/build passes after the bump
- [ ] New/updated tests added for every impacted call site listed above
- [ ] No peer-dependency or transitive version conflicts remain (`npm ls`/equivalent clean)
- [ ] If this bump addresses a security advisory, the audit command shows it resolved

**Status decision.**

- Any **major**-version range-edit bump — or a coupled group containing one — defaults to
  `Status: ready-for-human`, regardless of how cleanly steps 3–6 came back. A major bump only
  guarantees the package's own declared semver contract, not that a coder will notice a
  subtlety a diligent review happens to catch (e.g. a test that mutates an export directly
  becoming fragile under a new dual CJS/ESM build). Don't compute your way out of this with a
  clean per-case risk score — treat "every check passed" as the normal case for a major bump
  needing a human, not an exception to it.
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

- Never modify `package.json`, lockfiles, or `node_modules` — this skill only plans and
  files issues; execution belongs to `solve-issue` / `crew-afk`.
- Never mark a range-edit issue `ready-for-agent` when the status-decision criteria in step 7
  call for `ready-for-human` — escalating uncertainty to a human beats a coder silently
  trusting an incomplete changelog check.
- Never fold a CVE-driven bump into the in-range safe-batch — its advisory-clean re-check
  needs to be verifiable on its own.
- Never mark an upgrade issue `ready-for-agent` without the safety checklist and, if there
  are impacted call sites, their required test additions.
