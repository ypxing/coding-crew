# Docker Install

Use this when `docker-compose.yml`, `docker-compose.yaml`, or `compose.yml` exists at `PROJECT_ROOT`.
Do **not** run any command on the host — everything runs inside the container.

`PROJECT_ROOT` and `MAIN_ROOT` are established at session startup by the caller. Each bash tool call runs in a fresh shell — variables do not persist between calls. At the top of every bash call, assign both to their literal values from session startup:

```bash
PROJECT_ROOT="/absolute/path/to/worktree"
MAIN_ROOT="/absolute/path/to/main-checkout"
```

## Never

- Never run any install or project command on the host — everything runs inside the container.
- Never use `docker-compose` (v1 hyphenated binary) — always use `docker compose` (v2 plugin).
- Always pass both `-f "$PROJECT_ROOT/docker-compose.yml" -f "$MAIN_ROOT/docker-compose.override.yml"` on every `docker compose` command.
- **Never write `docker-compose.override.yml` manually** — always generate it via `gen-override.sh`. Hand-writing the file skips proxy env vars and produces generic volume names that collide across worktrees.

## Steps

> **If you arrived here via the fast-path** (override already exists at `$MAIN_ROOT/docker-compose.override.yml`): skip steps 0–1 and go directly to step 2 (run install).

### 0. Read Makefile and ensure `.env` exists

**a. Read the Makefile** (`$PROJECT_ROOT/Makefile`), if present. Scan for:

- Targets that reference `.env` (e.g. `cp .env.example .env`, `$(MAKE) .env`)
- Environment variable names used in recipes (e.g. `$(NPM_TOKEN)`, `export FOO`)
- Any comments describing required secrets or setup
- Targets that generate package-manager credential config files (e.g. `.npmrc`, `.yarnrc.yml`, `pip.conf`, `.cargo/credentials.toml`) via `envsubst`, `echo`, or template files (`.npmrc.tpl`, `pip.conf.tpl`, etc.)

This step is always done — the Makefile reveals how the project works and what env vars are expected.

**b. If `.env` does not exist at `PROJECT_ROOT`:**

- If `.env.example` exists: `cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"`
- Otherwise: `touch "$PROJECT_ROOT/.env"`

**c. Generate credential config files if the Makefile has a target for them:**

- If a Makefile target generates a package-manager credential config file (identified in step a), run that target:
  ```bash
  make -C "$PROJECT_ROOT" <target-name>
  ```
- If no Makefile target exists but a `.tpl` file is present (e.g. `.npmrc.tpl`, `pip.conf.tpl`), generate via `envsubst`:
  ```bash
  envsubst < "$PROJECT_ROOT/<name>.tpl" > "$PROJECT_ROOT/<name>"
  ```
- Skip silently if neither exists.

**d.** Log what was done (e.g. "Created .env from .env.example; generated .npmrc from Makefile target").

**Never read the contents of `.env*` or any credential config file** — not to log, not to inspect, not to verify.

Always continue to step 1 — this step never blocks. If `docker compose` later fails because a required env var is missing, stop and report blocked with the verbatim error.

### 1. Generate `docker-compose.override.yml`

Run the generation script. It reads the compose file, detects the ecosystem from manifest files (`package.json`, `pyproject.toml`, etc.), and writes the override deterministically — same repo, same output every run.

```bash
bash "$MAIN_ROOT/.claude/skills/dep-install/scripts/gen-override.sh" \
  --project-root "$PROJECT_ROOT" \
  --main-root "$MAIN_ROOT"
```

The script prints what it wrote, which ecosystem it detected, and which services it found. If it exits non-zero, stop and report `BLOCKED` with the error message.

The override file is written to `$MAIN_ROOT/docker-compose.override.yml` and is shared across all worktrees — do not write it to `PROJECT_ROOT`.

### 2. Run install once

Named volumes start empty — always run install inside the container.

Check whether the Makefile has a public `install` or `deps` target whose recipe explicitly runs the package manager in every subdirectory that has a named volume (not just the root). If yes, use it:

```bash
docker compose \
  -f "$PROJECT_ROOT/docker-compose.yml" \
  -f "$MAIN_ROOT/docker-compose.override.yml" \
  run --rm <service> make install
```

Otherwise, run the package manager directly for each directory with a named volume. Pass all `cd && install` commands in a single `sh -c` to avoid re-starting the container per directory:

```bash
docker compose \
  -f "$PROJECT_ROOT/docker-compose.yml" \
  -f "$MAIN_ROOT/docker-compose.override.yml" \
  run --rm <service> sh -c "
    cd /opt/app && <install-command> &&
    cd /opt/app/events && <install-command>
  "
```

Pass both `-f` flags on every `docker compose` command.

### 3. All subsequent `docker compose` commands must pass both `-f` flags

**Complete steps 0–2 in order before running any `docker compose` command. Do not skip ahead.**

Pass both `-f "$PROJECT_ROOT/docker-compose.yml" -f "$MAIN_ROOT/docker-compose.override.yml"` on every `docker compose` command — including test, lint, and type-check runs. Never omit the `-f override` flag.

## Install failures

If install fails because the container's entrypoint ignores the command, check the compose file for an `entrypoint:` key and override it:

```bash
docker compose \
  -f "$PROJECT_ROOT/docker-compose.yml" \
  -f "$MAIN_ROOT/docker-compose.override.yml" \
  run --rm --entrypoint sh <service> -c "<install-command>"
```

If install fails due to missing auth tokens, network errors, or Docker not running — stop immediately and report blocked with the verbatim error. Do not attempt workarounds.
