# Verification

Run all project checks and confirm every acceptance criterion from the issue is met.

## Discover check commands

For each check category (tests, type check, lint), determine the command independently:

1. If `CLAUDE.md` at `PROJECT_ROOT` specifies a command for that category, use it.
2. Otherwise, check the `Makefile` for a matching target.
3. Otherwise, use ecosystem conventions: `npm test`, `go test ./...`, `pytest`, `cargo test`, `bundle exec rspec`.

A `CLAUDE.md` that defines the test command does not prevent you from looking up the lint command in the Makefile or conventions.

**All three checks are mandatory. Run them in this order — do not skip any:**

1. **Type check** — run first, before tests. For TypeScript: `tsc --noEmit` (or the Makefile/CLAUDE.md equivalent). For other typed languages: mypy, pyright, go vet, etc.
2. **Lint** — run second. Check Makefile for an `eslint`, `lint`, or `check` target; fall back to `npx eslint .` / `golangci-lint run` / etc.
3. **Tests** — run last. Unit tests covering changed code, plus integration tests if relevant.

If you cannot find a command for a check category, note it as `NOT RUN: no command found` — but this must be explicit in your output. Silently skipping is not allowed.

## Docker projects

If using docker compose, pass both `-f` flags on every command. Set environment flags inline
on each call — shell exports do not persist between calls:

```
Wrong: export CI=true; docker compose run ...
Right: CI=true docker compose run ...
```

| Condition | Flag |
|---|---|
| `pnpm-lock.yaml` exists | `CI=true` |
| compose file uses `${MAIN_ROOT}` | `MAIN_ROOT="$MAIN_ROOT"` |

## Interpreting failures

**Fixable** (test failures, type errors, lint violations) — fix the code and re-run. If the
same check command continues to fail after 2 distinct fix attempts — regardless of whether the
error message changed — stop and report blocked.

**Environment errors** (Docker not running, missing credentials, network timeouts, permission
denied on system paths) — stop immediately. Do not attempt to fix. Report blocked with
verbatim output.

## Acceptance criteria

Check each criterion from the issue against the implemented code. All must pass before committing.
