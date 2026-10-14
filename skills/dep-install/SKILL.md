---
name: dep-install
description: >
  Decides a project's install mode (host or docker) once with the person, records it in the committed
  .coding-crew/dev-commands.json, and installs dependencies. Use when setting up a project, or when a command
  failed for a missing dependency; used by solve-issue, address-pr-comments, add-tests and upgrade-deps.
---

# Dep Install

You are invoked **on demand** — to set a project's install mode up, or because a command already
failed for a missing dependency — not as a routine step. Do not re-litigate whether install is
needed: read the mode, then install.

Every project command — an ad-hoc one, and a one-off `docker compose` call, included — runs through
`bash "<skill-dir>/scripts/checks/run.sh" --project-root "$PROJECT_ROOT" -- "<command>"`. It reads the
mode from this checkout's `.coding-crew/dev-commands.json` and runs the command on the host, or inside
docker in this checkout's own compose project, with its override added by the `docker` shim. In
docker mode, with no override yet, it installs first, and a failed install stops it with the service,
the step and its log: docker mode never runs a command on the host, except one that runs docker itself.

`PROJECT_ROOT` is the checkout, **inherited from the caller** — do not re-derive it.

## Must

- Run `resolve-mode.sh` in Step 1 **before** any install command — even if you can see a lock file or infer the package manager from context. Skipping it is a mistake, not an optimisation.
- Run install **once**. Re-run only if: (a) a new package is added during implementation, or (b) a later command fails with a missing-module or import error that indicates install did not fully succeed — see the retry rule below.
- **Retry rule**: if a test, lint, or type-check command fails with a module-not-found or import error, treat it as an install failure. Re-run install once — docker: `docker-install.sh --force`, which deletes the volume's completion stamp and reinstalls (without it, the stamp makes the retry a no-op); host: `host-install.sh` — then retry the failing command once. If it still fails, stop and report `BLOCKED`.
- Stop and report `BLOCKED` if install fails on the retry. Do not attempt workarounds beyond the single retry.

## Never

- Never read, log, print, or inspect the contents of any credential or config files: `.env*`, `.npmrc*`, `.yarnrc*`, `.pip.conf`, `pip.ini`, `.cargo/credentials.toml`, `.bundle/config`, or any file whose name suggests it holds secrets or tokens.
- Never modify lock files: `package-lock.json`, `yarn.lock`, `bun.lockb`, `pnpm-lock.yaml`, `uv.lock`, `poetry.lock`, `go.sum`, `Cargo.lock`, `Gemfile.lock`, `composer.lock`, or equivalent for any ecosystem.

## Step 1 — Read the mode, or set it up

```bash
bash "<skill-dir>/scripts/checks/resolve-mode.sh" --project-root "$PROJECT_ROOT"
```

It prints `INSTALL_MODE=docker` or `INSTALL_MODE=host`, and `DOCKER_SERVICE`: the committed
`.coding-crew/dev-commands.json`'s `install_mode` and `docker_service`. No `install_mode` means host.
Do not re-derive the mode yourself.

**No `install_mode` yet, and the project has a compose file** (`docker-compose.yml`,
`docker-compose.yaml` or `compose.yml`): the mode has never been decided. On a non-interactive run (a
headless/`-p` invocation or a subagent), never write `install_mode` or `docker_service`: continue in
host mode. On an interactive run, decide it with the person once:

```bash
bash "<skill-dir>/scripts/checks/detect-mode.sh" --project-root "$PROJECT_ROOT"
bash "<skill-dir>/scripts/checks/gen-override.sh" --project-root "$PROJECT_ROOT" --query services
```

`detect-mode.sh` reads the Makefile (`USE_DOCKER` when an install-like target runs docker compose);
the second lists the compose services. Ask the person whether the checks run in docker or on the
host, suggesting that verdict, and — for docker — in which service, suggesting the one the Makefile's
recipes use, else the first. Record the answer, and tell them to commit
`.coding-crew/dev-commands.json`:

```bash
cat > "$PROJECT_ROOT/.install-mode.json" <<'JSON'
{"install_mode": "<docker or host>", "docker_service": "<service, or omit the key for host>"}
JSON
(cd "$PROJECT_ROOT" && bash "<skill-dir>/scripts/git-workflow/write-commands-cache.sh" --response-file .install-mode.json)
rm -f "$PROJECT_ROOT/.install-mode.json"
```

## Step 2 — Follow the install guide

The mode is **session-wide**: every command for the rest of this session — install, test, lint,
type-check, format, verify — runs in it, through `run.sh`. State it before continuing:

> "INSTALL_MODE=docker — all subsequent commands run inside docker."
> or
> "INSTALL_MODE=host — all subsequent commands run on the host."

- `INSTALL_MODE=docker` → Read `references/docker-install.md` and follow it. Never fall back to host commands.
- `INSTALL_MODE=host` → Read `references/host-install.md` and follow it. Never switch to docker commands.
