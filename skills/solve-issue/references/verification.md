# Verification

Run all project checks and confirm every acceptance criterion from the issue is met.

## Discover check commands

For each check category (tests, type check, lint), determine the command independently:

1. If `CLAUDE.md` at `PROJECT_ROOT` specifies a command for that category, use it.
2. Otherwise, check the `Makefile` for a matching target.
3. Otherwise, use ecosystem conventions: `npm test`, `go test ./...`, `pytest`, `cargo test`, `bundle exec rspec`.

A `CLAUDE.md` that defines the test command does not prevent you from looking up the lint command in the Makefile or conventions.

**All three checks are mandatory — do not skip any.** You are discovering commands, not running
them: `run-checks.sh` runs whatever you persist, in this order.

1. **Type check** — for TypeScript: `tsc --noEmit` (or the Makefile/CLAUDE.md equivalent). For other typed languages: mypy, pyright, go vet, etc.
2. **Lint** — check Makefile for an `eslint`, `lint`, or `check` target; fall back to `npx eslint .` / `golangci-lint run` / etc.
3. **Tests** — unit tests covering changed code, plus integration tests if relevant.

If you cannot find a command for a check category, persist it as `null` — `run-checks.sh` then
reports it as `NOT RUN: no command found`, explicitly. Do not invent one to fill the slot.

## Docker projects

Persist the bare command (`pnpm test`, not a `docker compose run …` wrapper): `run.sh` adds the
compose flags, the service and this worktree's git env itself. Put any env a command needs inside
the command, where it reaches the process that reads it:

| Condition | Command |
|---|---|
| `pnpm-lock.yaml` exists | `CI=true pnpm test` |

## Interpreting failures

**Fixable** (test failures, type errors, lint violations) — fix the code and re-run. If the
same check command continues to fail after 2 distinct fix attempts — regardless of whether the
error message changed — stop and report blocked.

**Environment errors** (Docker not running, missing credentials, network timeouts, permission
denied on system paths) — stop immediately. Do not attempt to fix. Report blocked with
verbatim output.

## Acceptance criteria

Check each criterion from the issue against the implemented code. All must pass before committing.
