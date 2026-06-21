# Project Requirements

These agents work best when the consuming project provides the following. Nothing is strictly
required — agents degrade gracefully — but the more you provide, the better results you get.

## Required for basic operation

| What                        | Why                                                                  | Degrades to                                                             |
| --------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `CLAUDE.md` at repo root    | Agents read this to discover commands, architecture, and conventions | Agent guesses from `Makefile` / `package.json` — may run wrong commands |
| A test command              | Issue-worker needs to run tests in its TDD loop                      | Worker skips red/green verification, commits untested code              |
| A way to run lint/typecheck | Verification step needs these                                        | Worker reports `NOT RUN: no lint/typecheck command found`               |

## Recommended

| What                              | Why                                         | Degrades to                                             |
| --------------------------------- | ------------------------------------------- | ------------------------------------------------------- |
| `docs/agents/issue-tracker.md`    | Tells agents how to list/fetch/close issues | Install copies a default; edit it to match your tracker |
| `docs/agents/triage-labels.md`    | Maps label strings to canonical roles       | Install copies a default; edit it to match your labels  |
| `.scratch/` directory with issues | afk-run needs issues to work on             | Agent finds nothing and exits immediately               |

## CLAUDE.md — what agents look for

Agents parse `CLAUDE.md` looking for these sections (by heading or content):

1. **Commands / Build** — how to run tests, lint, typecheck, build. Agents look for:
   - A test command (e.g., `make test`, `npm test`, `yarn test`)
   - A lint command (e.g., `make lint`, `npm run lint`)
   - A typecheck command (e.g., `make tsc`, `npx tsc --noEmit`)
   - Whether commands run inside Docker, natively, or both

2. **Architecture** — what the major directories are and what they contain. Helps agents navigate
   without guessing.

3. **Environment** — any env vars, Docker requirements, or setup steps needed before commands work.

### Minimal example

```markdown
# CLAUDE.md

## Commands

- `npm test` — run all tests
- `npm run lint` — eslint
- `npx tsc --noEmit` — typecheck

## Architecture

- `src/` — application source
- `src/__tests__/` — test files mirror src structure

## Environment

- Node 20+
- No Docker required
```

### Full example (Docker-based)

```markdown
# CLAUDE.md

## Commands

From the host:

- `make test` — all tests (runs inside Docker)
- `make lint` — eslint
- `make tsc` — TypeScript check

Inside the container (`make shell`):

- `make _test` — tests directly
- `make _lint` — lint directly

## Architecture

- `/app/` — main application
- `/app/src/` — source code
- `/app/test/` — test suites (unit/, integration/)

## Environment

- Docker + docker-compose required
- `.env.dev` for local development
- Run `make deps` after cloning
```

## For Copilot (`.github/agents/`)

Copilot agents read the same `CLAUDE.md` — no separate config needed. The `.github/agents/*.agent.md`
shims just provide Copilot-specific tool mappings; the protocol references `CLAUDE.md` for commands.
