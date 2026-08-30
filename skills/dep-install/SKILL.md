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

Two steps: detect the install mode, then follow the appropriate install guide.

## Must

- Run the detection script in Step 1 **before** any install command — even if you can see a lock file or infer the package manager from context. Skipping it is a mistake, not an optimisation.
- Run install **once**. Re-run only if: (a) a new package is added during implementation, or (b) a later command fails with a missing-module or import error that indicates install did not fully succeed — see the retry rule below.
- **Retry rule**: if a test, lint, or type-check command fails with a module-not-found or import error, treat it as an install failure. Return to Step 1, re-run the detection script, re-run `gen-override.sh` (docker mode), re-run install, then retry the failing command once. If it still fails, stop and report `BLOCKED`.
- Stop and report `BLOCKED` if install fails on the retry. Do not attempt workarounds beyond the single retry.

## Never

- Never read, log, print, or inspect the contents of any credential or config files: `.env*`, `.npmrc*`, `.yarnrc*`, `.pip.conf`, `pip.ini`, `.cargo/credentials.toml`, `.bundle/config`, or any file whose name suggests it holds secrets or tokens.
- Never modify lock files: `package-lock.json`, `yarn.lock`, `bun.lockb`, `pnpm-lock.yaml`, `uv.lock`, `poetry.lock`, `go.sum`, `Cargo.lock`, `Gemfile.lock`, `composer.lock`, or equivalent for any ecosystem.

## Step 0 — Fast-path: honor a cached verdict

`$MAIN_ROOT/.scratch/install-mode` is this sprint's own cached verdict, written once by
`ensure-deps.sh`'s single MAIN_ROOT call. If it exists it is authoritative — do not re-run
detection against it, here or in any other worktree's own dep-install invocation.

```bash
cat "$MAIN_ROOT/.scratch/install-mode" 2>/dev/null || echo "RUN_DETECTION"
```

- Prints `docker`: set `INSTALL_MODE=docker`, skip Step 1 entirely. If `$MAIN_ROOT/docker-compose.override.yml` also already exists, skip the override-writing sub-steps in the docker guide too and go directly to install — the override and volume definitions are already in place from a prior run. If it does **not** exist yet, still skip Step 1, but run the docker guide's override-writing sub-step once before installing.
- Prints `host`: set `INSTALL_MODE=host`, skip Step 1 entirely, and go directly to `references/host-install.md`.
- Prints `RUN_DETECTION` (no cache file — this sprint's MAIN_ROOT call hasn't run yet, or this isn't a sprint at all): continue to Step 1.

## Step 1 — Run the detection script

Run this script now. It will print either `USE_DOCKER` or `USE_HOST`.

Run `scripts/detect-mode.sh` from the same directory you read this skill file from:

```bash
bash "<skill-dir>/scripts/detect-mode.sh" --project-root "$PROJECT_ROOT"
```

## Step 2 — Lock the session mode and follow the install guide

The detected mode is **session-wide**. Every command for the rest of this session — install, test, lint, type-check, format, verify — must use this mode. Do not switch modes mid-session.

After running the detection script, state the mode explicitly before continuing:

> "INSTALL_MODE=docker — all subsequent commands run inside docker."
> or
> "INSTALL_MODE=host — all subsequent commands run on the host."

Then follow the install guide:

- `USE_DOCKER` → Read `references/docker-install.md` and follow it for installation. Remember: **every subsequent command in this session runs inside docker** — not just install. Never fall back to host commands.
- `USE_HOST` → Read `references/host-install.md` and follow it for installation. Remember: **every subsequent command in this session runs on the host** — never switch to docker commands.
