---
name: dep-install
description: >
  Detect the project's install mode (host or docker) and install dependencies once.
  Used as a shared step by solve-issue, address-code-review, and address-pr-comments.
---

# Dep Install

Two steps: detect the install mode, then follow the appropriate install guide.

## Must

- Run the detection script in Step 1 **before** any install command — even if you can see a lock file or infer the package manager from context. Skipping it is a mistake, not an optimisation.
- Run install **once**. Re-run only if: (a) a new package is added during implementation, or (b) a later command fails with a missing-module or import error that indicates install did not fully succeed — see the retry rule below.
- **Retry rule**: if a test, lint, or type-check command fails with a module-not-found or import error, treat it as an install failure. Return to Step 1, re-run the detection script, regenerate the override file (docker mode), re-run install, then retry the failing command once. If it still fails, stop and report `BLOCKED`.
- Stop and report `BLOCKED` if install fails on the retry. Do not attempt workarounds beyond the single retry.

## Never

- Never read, log, print, or inspect the contents of any credential or config files: `.env*`, `.npmrc*`, `.yarnrc*`, `.pip.conf`, `pip.ini`, `.cargo/credentials.toml`, `.bundle/config`, or any file whose name suggests it holds secrets or tokens.
- Never modify lock files: `package-lock.json`, `yarn.lock`, `bun.lockb`, `pnpm-lock.yaml`, `uv.lock`, `poetry.lock`, `go.sum`, `Cargo.lock`, `Gemfile.lock`, `composer.lock`, or equivalent for any ecosystem.

## Step 0 — Fast-path: check for existing override

```bash
[ -f "$MAIN_ROOT/docker-compose.override.yml" ] && echo "USE_DOCKER_FAST" || echo "RUN_DETECTION"
```

If this prints `USE_DOCKER_FAST`: set `INSTALL_MODE=docker`, skip Steps 1 and the override-writing sub-steps in the docker guide, and go directly to install. The override and volume definitions are already in place from a prior run.

If this prints `RUN_DETECTION`: continue to Step 1.

## Step 1 — Run the detection script

Run this script now. It will print either `USE_DOCKER` or `USE_HOST`.

```bash
PROJECT_ROOT="${PROJECT_ROOT:-$(pwd)}"

# 1. Explicit git config override
_mode=$(git -C "$PROJECT_ROOT" config --local agent.install-mode 2>/dev/null)

# 2. Infer from Makefile public install/deps/setup targets
#    Only the Makefile at PROJECT_ROOT is checked — never subdirectory Makefiles.
#    Guard: only scan when PROJECT_ROOT is at or inside the git root.
if [ -z "$_mode" ]; then
  _git_root=$(git -C "$PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null) || _git_root=""
  case "$PROJECT_ROOT/" in
    "$_git_root/"*) ;;       # at or inside the repo root — allow Makefile scan
    *) _mode="host" ;;       # outside repo boundary — skip scan, fall back to host
  esac
fi

if [ -z "$_mode" ] && [ -f "$PROJECT_ROOT/Makefile" ]; then
  # Match public targets (not starting with _) named install, deps, or setup.
  # [^=] after : avoids matching variable assignments (VAR := value).
  # Check if their recipe lines invoke docker compose directly.
  _uses_docker=$(awk '
    /^[a-zA-Z][a-zA-Z0-9_-]*[[:space:]]*:[^=]/ {
      in_target = ($0 ~ /^(install|deps|setup)[[:space:]]*:/)
    }
    in_target && /^\t/ && /docker[ -]compose|docker compose/ { print "yes"; exit }
  ' "$PROJECT_ROOT/Makefile")
  [ "$_uses_docker" = "yes" ] && _mode="docker"
fi

# 3. Fall back to compose-file presence
if [ -z "$_mode" ]; then
  { [ -f "$PROJECT_ROOT/docker-compose.yml" ] || \
    [ -f "$PROJECT_ROOT/docker-compose.yaml" ] || \
    [ -f "$PROJECT_ROOT/compose.yml" ]; } \
    && _mode="docker" || _mode="host"
fi

[ "$_mode" = "docker" ] && echo "USE_DOCKER" || echo "USE_HOST"
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
