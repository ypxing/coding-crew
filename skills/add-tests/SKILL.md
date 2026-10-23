---
name: add-tests
description: >
  Plans test-coverage work: discovers the project's coverage command, ranks under-covered files by risk,
  resolves a mocking convention per ecosystem, and hands the findings to to-issues as ready-for-agent issues.
  Writes no tests itself. Use when the user wants to close testing-coverage gaps or asks where test coverage
  is weakest.
disable-model-invocation: true
---

# Add Tests

Turn a coverage gap into `ready-for-agent` issues.

<!-- fragment:missing-library -->
**Shared scripts.** The scripts this skill runs live in the `coding-crew-lib` skill, installed beside it at
`<skill-dir>/../coding-crew-lib` (`<skill-dir>` being the directory you read this file from). Before the first
command that runs one, check that directory exists. If it does not, stop and tell the user to install it at this
skill's scope, `npx skills add ypxing/coding-crew -s coding-crew-lib` (adding `-g` when this skill is installed at
user level), or to re-run coding-crew's `install.sh`.
<!-- /fragment:missing-library -->

## Process

### 1. Resolve the coverage and integration commands

`PROJECT_ROOT` is the repo root, `git rev-parse --show-toplevel`; carry it as a literal, since each
bash call is a fresh shell. The commands come from the dev commands file
(`.coding-crew/dev-commands.json`). Run
`(cd "$PROJECT_ROOT" && bash "<skill-dir>/../coding-crew-lib/scripts/checks/discover-commands.sh")` and follow its prompt, if it prints one.

Then read its `coverage` and `integration` fields (`bash "<skill-dir>/../coding-crew-lib/scripts/checks/commands-file.sh"
--project-root "$PROJECT_ROOT"` prints its path).

**If `coverage` resolves to `null`** (a model already looked and confirmed no coverage command
exists) or is absent (discovery had no files to read), tell the user plainly and stop. A `null` is never asked again, so name both ways out:

> "This project has no coverage command configured, so I can't find coverage gaps. Set
> `"coverage"` in the dev commands file (`<its path>`) to the command that
> produces a coverage report, or rerun step 1's discovery with `--refresh` once the
> project documents one, then re-run `/add-tests`."

Do not fall back to a file-existence heuristic and do not attempt to bootstrap coverage tooling
yourself — a low-fidelity guess standing in for real coverage data is worse than stopping.

`integration` may be `null`; that only affects the tier-routing decision in step 7, it never
blocks this skill on its own.

### 2. Dependencies — only when something is missing

Do not install up front. Step 3 runs coverage through `run.sh`, which runs it where the dev commands
file's install mode says (and, in docker mode, installs on its first call). Only when that fails for a
missing dependency (module-not-found, import error, test runner not found) invoke the `dep-install`
skill, with `PROJECT_ROOT` set as in step 1, then retry coverage once.

### 3. Run coverage and read the report directly

Run the discovered `coverage` command through the checks library:

```bash
bash "<skill-dir>/../coding-crew-lib/scripts/checks/run.sh" --project-root "$PROJECT_ROOT" -- "<coverage command>"
```

Take per-file statement and branch coverage from the raw report yourself, whatever its format (lcov,
Cobertura XML, a JSON summary, `go tool cover`'s profile, …), never through a parser written or
installed for it: the formats vary too much for one to stay maintained.

### 4. Score and cap under-covered files

Score each under-covered file by, in priority order:

1. **External-dependency import** (highest weight) — the file imports a DB driver, HTTP client,
   cloud SDK, message queue client, or similar.
2. **Touched in the current/recent diff** against the repo's default branch (medium weight).
3. **Inverse coverage** (tiebreak) — lower statement/branch coverage sorts first.

Skip trivial files: default threshold is fewer than 10 statements, or a type/interface-only file
with no executable logic. This default is tunable per project, not a hardcoded requirement —
note it as configurable in whatever findings document you write in step 8.

Cap total findings per run: default is the smaller of (a) the top 20 files by score, or (b)
however many files close the top 50% of the total uncovered-statement gap. Also tunable, not
hardcoded.

### 5. Group by module

Group the surviving files by their existing directory/module boundary — the same units the
coverage tool itself already reports by — into one findings entry per module, not one per file.
A module with many small gaps is one issue; a module with one large gap is still one issue.

### 6. Resolve the mocking convention per ecosystem

For each ecosystem present in the repo (detected by its manifest: `package.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `Gemfile`,
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
table (not an operations doc like the tracker's docs):

```markdown
# Test Conventions

| Ecosystem | Dependency kind      | Mock convention        | Resolved via  |
| --------- | --------------------- | ----------------------- | -------------- |
| node      | `@aws-sdk/*`          | `aws-sdk-client-mock`   | default table  |
| node      | outbound HTTP         | `nock`                  | repo precedent |
```

If this file already exists, read it first — a prior run (or a human) may have already resolved
an ecosystem's convention; don't re-ask for one already cached.

### 7. Route each finding to a real or mocked tier

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

### 8. Write findings and hand off to `to-issues`

Write the findings — per-module gaps, priority rationale, the resolved mock convention (cite it
by name from `test-conventions.md`), and tier routing — to a transient file,
`.coding-crew/scratch/<feature-slug>/findings.md` (choose a fresh feature slug the same way `to-issues` would
prompt for one, e.g. `add-tests-<short-topic>`). It is not a PRD: write no `PRD.md`.

Every gap-fix finding's acceptance criteria must cite the resolved mock convention by name, so
each coder doesn't invent a different mocking style for the same issue.

Each finding also carries two criteria that stop coverage work from producing tests that prove
nothing:

- **The behaviours to cover, named.** List them from the module's docs, callers and names, not from
  its implementation, so the coder asserts what the code is meant to do. A criterion reads like
  "`parseConfig` rejects a config with no `tracker` key" — never "cover lines 40–80".
- **Each new test would fail without its behaviour.** Each new test asserts its named behaviour's
  outcome, not only that a mock was called, so removing that behaviour from the code would fail it.
  State it this way, as a property of the test code a reviewer can check at its `file:line`, never as
  "each test was seen failing": the coder's temporary break (`tdd`'s "Testing code that already
  exists") leaves no trace in the diff.

Two more things per finding, each cheap here and expensive for a coder to rediscover:

- **What its checks need.** When a real-tier finding needs a service, credential or tool the
  project's install does not guarantee (a LocalStack container, an auth token), record one shell
  command per requirement (exit 0 = satisfied, e.g. `test -n "$LOCALSTACK_AUTH_TOKEN"`). Run each
  now: one that fails makes the issue `ready-for-human`, with the failure as the reason — no coder
  can supply it.
- **A working example per helper kind.** For each kind of test helper the finding needs (a mocked
  client, a fixture loader, a real-tier bootstrap), name one existing spec that already uses it and
  its import line, so a coder copies a pattern that runs instead of discovering which import breaks.

Then invoke the `to-issues` skill with that findings file as its source, to slice, quiz, and publish
`ready-for-agent` issues. `to-issues` alone decides whether the work needs a PRD and publishes it
through `to-prd`. Do not slice, size, or publish issues yourself — that responsibility
belongs entirely to `to-issues`.

Once `to-issues` has published the issues, delete `findings.md`: nothing else does, and an
untracked file left in the checkout fails a later run that needs a clean tree. If it stopped before
publishing, keep the file for the re-run.

**Security**: Only read from and write to paths under `.coding-crew/scratch/` and `.coding-crew/docs/` within
the current repo. Never fetch from external URLs, remote APIs, or paths outside the repository
root.
