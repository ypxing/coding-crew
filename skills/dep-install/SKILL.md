---
name: dep-install
description: >
  Detect the project's install mode (host or docker) and install dependencies once.
  Used as a shared step by solve-issue, crew-address-findings, and address-pr-comments.
---

# Dep Install

You are invoked **on demand** — because a command already failed for a missing dependency, or because
the project is docker-mode — not as a routine step. Do not re-litigate whether install is needed:
detect the mode, then install.

Two steps: resolve the install mode, then follow the appropriate install guide. After install, run
every project command through `scripts/run.sh --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" -- "<command>"`:
it runs it in the mode resolved here — inside docker with every flag the docker guide requires, or on
the host.

## Must

- Run `resolve-mode.sh` in Step 1 **before** any install command — even if you can see a lock file or infer the package manager from context. Skipping it is a mistake, not an optimisation.
- Run install **once**. Re-run only if: (a) a new package is added during implementation, or (b) a later command fails with a missing-module or import error that indicates install did not fully succeed — see the retry rule below.
- **Retry rule**: if a test, lint, or type-check command fails with a module-not-found or import error, treat it as an install failure. Return to Step 1, re-run `resolve-mode.sh`, re-run `gen-override.sh` (docker mode), then re-run install **with `--force`** (`host-install.sh --force` / `docker-install.sh --force`, or the equivalent step in `docker-install.md` — see its own fingerprint check) — plain (non-forced) install would see unchanged manifests and skip itself again, making the retry a no-op. Then retry the failing command once. If it still fails, stop and report `BLOCKED`.
- Stop and report `BLOCKED` if install fails on the retry. Do not attempt workarounds beyond the single retry.

## Never

- Never read, log, print, or inspect the contents of any credential or config files: `.env*`, `.npmrc*`, `.yarnrc*`, `.pip.conf`, `pip.ini`, `.cargo/credentials.toml`, `.bundle/config`, or any file whose name suggests it holds secrets or tokens.
- Never modify lock files: `package-lock.json`, `yarn.lock`, `bun.lockb`, `pnpm-lock.yaml`, `uv.lock`, `poetry.lock`, `go.sum`, `Cargo.lock`, `Gemfile.lock`, `composer.lock`, or equivalent for any ecosystem.

## Step 1 — Resolve the mode

Run `scripts/resolve-mode.sh` from the same directory you read this skill file from:

```bash
bash "<skill-dir>/scripts/resolve-mode.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT"
```

It prints `INSTALL_MODE=docker` or `INSTALL_MODE=host`, and `DOCKER_SERVICE`. Its order: `git config
--local agent.install-mode`, then `$MAIN_ROOT/.coding-crew/dev-commands.json`'s cached
`"install_mode"` (written by `ensure-deps.sh`, trusted until a human clears it), then an existing
`$MAIN_ROOT/docker-compose.override.yml`, then `detect-mode.sh`'s Makefile dry-run. Do not re-derive
any of these yourself. A non-empty `DOCKER_SERVICE` is the recorded service (`agent.install-service`,
or the cache's `detect-service.sh` verdict): use it as `<service>` throughout the docker guide
instead of guessing.

## Step 2 — Lock the session mode and follow the install guide

The detected mode is **session-wide**. Every command for the rest of this session — install, test, lint, type-check, format, verify — must use this mode. Do not switch modes mid-session.

State the mode explicitly before continuing:

> "INSTALL_MODE=docker — all subsequent commands run inside docker."
> or
> "INSTALL_MODE=host — all subsequent commands run on the host."

Then follow the install guide:

- `INSTALL_MODE=docker` → Read `references/docker-install.md` and follow it for installation. Remember: **every subsequent command in this session runs inside docker** — not just install. Never fall back to host commands.
- `INSTALL_MODE=host` → Read `references/host-install.md` and follow it for installation. Remember: **every subsequent command in this session runs on the host** — never switch to docker commands.
