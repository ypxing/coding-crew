---
name: add-tests
description: Discover the project's coverage command, rank under-covered files by risk, resolve a mocking convention per ecosystem, and hand the findings to to-issues as ready-for-agent issues. Use when the user wants to close testing-coverage gaps or asks to find where test coverage is weakest.
---

# Add Tests

Turn a coverage gap into `ready-for-agent` issues that `crew-afk` or `/solve-issue` can pick up
directly — no special-casing needed on either downstream path.

## Process

### 1. Resolve the coverage and integration commands

Use the same discovery/cache mechanism `crew-afk`/`solve-issue` already use:

```bash
bash scripts/discover-commands.sh
```

This prints either a skip message (the cache already has both fields) or a discovery prompt —
hand that prompt to a model, then persist its response:

```bash
bash scripts/write-commands-cache.sh --response-file <path>
```

Then read the two fields this skill needs from `.coding-crew/dev-commands.json`, the same way
`ensure-deps.sh` already reads `install`:

```bash
grep -o '"coverage"[[:space:]]*:[[:space:]]*"[^"]*"' .coding-crew/dev-commands.json
grep -o '"integration"[[:space:]]*:[[:space:]]*"[^"]*"' .coding-crew/dev-commands.json
```

**If `coverage` resolves to `null`** (a model already looked and confirmed no coverage command
exists), tell the user plainly and stop:

> "This project has no coverage command configured, so I can't find coverage gaps. Add one to
> `CLAUDE.md`/`AGENTS.md`/a Makefile target and re-run `/add-tests`."

Do not fall back to a file-existence heuristic and do not attempt to bootstrap coverage tooling
yourself — a low-fidelity guess standing in for real coverage data is worse than stopping.

`integration` may be `null`; that only affects the tier-routing decision in step 6, it never
blocks this skill on its own.

### 2. Run coverage and read the report directly

Run the discovered `coverage` command and read whatever report format it produces (lcov,
Cobertura XML, a JS test runner's JSON summary, `go tool cover`'s profile, …) yourself, as a
model — extract per-file statement/branch coverage from the raw report. Do not write or invoke a
parser per format; the report formats vary too much for that to stay maintainable, and reading
the raw text directly is the same reasoning `discover-commands.sh` already uses for reading
CLAUDE.md/Makefile instead of regexing them.

### 3. Score and cap under-covered files

Score each under-covered file by, in priority order:

1. **External-dependency import** (highest weight) — the file imports a DB driver, HTTP client,
   cloud SDK, message queue client, or similar.
2. **Touched in the current/recent diff** against the repo's default branch (medium weight).
3. **Inverse coverage** (tiebreak) — lower statement/branch coverage sorts first.

Skip trivial files: default threshold is fewer than 10 statements, or a type/interface-only file
with no executable logic. This default is tunable per project, not a hardcoded requirement —
note it as configurable in whatever findings document you write in step 7.

Cap total findings per run: default is the smaller of (a) the top 20 files by score, or (b)
however many files close the top 50% of the total uncovered-statement gap. Also tunable, not
hardcoded.

### 4. Group by module

Group the surviving files by their existing directory/module boundary — the same units the
coverage tool itself already reports by — into one findings entry per module, not one per file.
A module with many small gaps is one issue; a module with one large gap is still one issue.

### 5. Resolve the mocking convention per ecosystem

For each ecosystem present in the repo (detected the same way `discover-commands.sh` already
scans manifests: `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Gemfile`,
`composer.json`), resolve one mocking convention, in this order:

1. **Existing repo precedent** — if the repo already depends on or uses a mocking/test-double
   library for that kind of external dependency, use it.
2. **Built-in default table** — a small, documented set of common defaults, e.g.:
   - `@aws-sdk/*` → `aws-sdk-client-mock`
   - `boto3` → `moto`
   - outbound HTTP (Node) → `nock` or `msw`, whichever the repo already has a dependency for
   - Go `net/http` → `net/http/httptest`
3. **Ask the user once** — if neither of the above resolves it.

Cache the resolved choice per ecosystem to `.coding-crew/docs/test-conventions.md`, a lookup
table (not an operations doc like `.coding-crew/docs/issue-tracker.md`):

```markdown
# Test Conventions

| Ecosystem | Dependency kind      | Mock convention        | Resolved via  |
| --------- | --------------------- | ----------------------- | -------------- |
| node      | `@aws-sdk/*`          | `aws-sdk-client-mock`   | default table  |
| node      | outbound HTTP         | `nock`                  | repo precedent |
```

If this file already exists, read it first — a prior run (or a human) may have already resolved
an ecosystem's convention; don't re-ask for one already cached.

### 6. Route each finding to a real or mocked tier

For every module-level finding whose files touch an external dependency:

- **If `integration` resolved to a real command in step 1**, route the finding to that real,
  dependency-backed tier.
- **Otherwise**, route it to a fallback tier explicitly labeled **"component test (mocked)"** —
  never call a wholly mocked SDK boundary an "integration test". A mocked boundary validates this
  project's own wiring and branch coverage, not the third party's actual wire behavior, and
  presenting it as the stronger guarantee would mislead whoever reads the resulting issue or PR.

If a single module has some files covered by the real tier and others only reachable through a
mocked boundary, produce **two** findings entries for that module, one per tier — do not pick one
tier for the whole module.

### 7. Write findings and hand off to `to-issues`

Write the findings — per-module gaps, priority rationale, the resolved mock convention (cite it
by name from `test-conventions.md`), and tier routing — as a lightweight PRD-style document at
`.scratch/<feature-slug>/PRD.md` (choose a fresh feature slug the same way `to-issues` would
prompt for one, e.g. `add-tests-<short-topic>`).

Every gap-fix finding's acceptance criteria must cite the resolved mock convention by name, so
`crew-coder`/`solve-issue` don't each invent a different mocking style for the same issue.

Then invoke the `to-issues` skill against that document to slice, quiz, and publish
`ready-for-agent` issues. Do not slice, size, or publish issues yourself — that responsibility
belongs entirely to `to-issues`, exactly as this skill's own upstream pipeline (`crew-grill`)
already hands its PRD to `to-issues` rather than re-implementing slicing.

**Security**: Only read from and write to paths under `.scratch/` and `.coding-crew/docs/` within
the current repo. Never fetch from external URLs, remote APIs, or paths outside the repository
root.
