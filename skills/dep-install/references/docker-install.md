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

**Platform mismatch (`requested image's platform ... does not match the detected host platform`)**: `gen-override.sh` emits a `platform:` key per service matching the *host's* architecture by default — the override's later `-f` wins the compose merge, so this overrides whatever the project's own compose file or image pins, without editing that file. Set `CREW_DOCKER_PLATFORM=off` before generating the override if the image is genuinely single-arch and the host has emulation deliberately set up for it; `amd64`/`arm64`/`linux/...` force a specific platform regardless of host.

## Steps

> **If you arrived here via the fast-path** (override already exists at `$MAIN_ROOT/docker-compose.override.yml`): skip steps 0–1 and go directly to step 2 (run install).
>
> **If `$MAIN_ROOT/.scratch/docker-install.done` exists**: an AFK sprint already warmed the shared
> volume for this checkout before any worktree existed (`ensure-deps.sh`'s docker path, mechanized
> because generating the override and running the install command are both deterministic). Skip
> steps 0–2 entirely and go to step 3 — the volume this worktree's compose file also mounts already
> has the baseline deps. Still apply the retry rule below if a later command fails with a
> module-not-found error: this worktree's own branch may have added a dependency the shared install
> ran before that branch existed.

### 0. Check the cache, then ensure `.env` exists

**a. Check the cache first.** `$MAIN_ROOT/.coding-crew/dev-commands.json`'s `"credential_target"`
field may already hold this repo's answer — written once by a sprint's own
`discover-commands.sh`/`write-commands-cache.sh`, or by a prior dep-install session's own step
b below:

```bash
CACHE="$MAIN_ROOT/.coding-crew/dev-commands.json"
RAW=""
[ -f "$CACHE" ] && RAW=$(grep -o '"credential_target"[[:space:]]*:[[:space:]]*\("[^"]*"\|null\)' "$CACHE" | head -1)
```

- `$RAW` holds a quoted command — that is the credential target. Skip straight to step c.
- `$RAW` is the bare word `null` — a model already scanned this repo's Makefile and confirmed
  no credential-generating target exists. Trust it: skip straight to step c with no
  `--credential-target`, and do not re-scan the Makefile yourself.
- `$RAW` is empty (no cache file, or the key is missing entirely) — nobody has asked this
  question for this repo yet. Continue to step b.

**b. Read the Makefile** (`$PROJECT_ROOT/Makefile`), if present. Scan for:

- Targets that generate package-manager credential config files (e.g. `.npmrc`, `.yarnrc.yml`,
  `pip.conf`, `.cargo/credentials.toml`) via `envsubst`, `echo`, or template files
  (`.npmrc.tpl`, `pip.conf.tpl`, etc.)
- Comments describing required secrets, so you recognise a target's *purpose* even when its
  name alone does not say so

Persist whatever you conclude — the full command to run it (e.g. `make _registry`, not just the
bare target name — same shape as `install`/`env`), or a confident "none" — so no future
dep-install session has to scan this Makefile again:

```bash
cat > /tmp/credential-target-discovery.json <<'JSON'
{"credential_target": "<the command you found, e.g. \"make _registry\", or null if you checked and found none>"}
JSON
bash "<skill-dir>/scripts/write-commands-cache.sh" --response-file /tmp/credential-target-discovery.json
```

**c. Run the env setup script**, passing `--credential-target` with whichever command (from the
cache in step a, or your own scan in step b) you resolved, if any:

Run `scripts/ensure-env.sh` from the same directory you read this skill file from:

```bash
# No credential target resolved:
bash "<skill-dir>/scripts/ensure-env.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT"
# A credential target resolved (from the cache, or step b):
bash "<skill-dir>/scripts/ensure-env.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --credential-target "make _registry"
```

Pass the command through unwrapped, exactly as discovered — do not put `docker compose run`
around it yourself either way. The script itself dry-runs it against `detect-docker-nesting.sh`
before evaling it: if the recipe already invokes docker, the script skips it (falling back to
template expansion) rather than risk nesting docker-in-docker.

The script itself already checks `dev-commands.json`'s own `"env"` field for a documented
`.env`-bootstrap command before falling back to its `.env.example`-or-empty convention — that
lookup needs no model involvement, so this step does not repeat it. It prints a one-line log of
what it did and always exits 0 — this step never blocks.

**Never read the contents of `.env*` or any credential config file** — not to log, not to inspect, not to verify.

Always continue to step 1 — this step never blocks. If `docker compose` later fails because a required env var is missing, stop and report blocked with the verbatim error.

### 1. Generate `docker-compose.override.yml`

Run the generation script. It reads the compose file, detects the ecosystem from manifest files (`package.json`, `pyproject.toml`, etc.), and writes the override deterministically — same repo, same output every run.

Run `scripts/gen-override.sh` from the same directory you read this skill file from:

```bash
bash "<skill-dir>/scripts/gen-override.sh" \
  --project-root "$PROJECT_ROOT" \
  --main-root "$MAIN_ROOT"
```

The script prints what it wrote, which ecosystem it detected, and which services it found. If it exits non-zero, stop and report `BLOCKED` with the error message.

If more than one service was found, use `dev-commands.json`'s `"docker_service"` field (Step 0 of
`SKILL.md`) as `<service>` below rather than picking one — it is not necessarily the first
service listed, and an unrelated service (a db, a sidecar with a different toolchain) will not
have the package manager the install/verify commands below need.

The override file is written to `$MAIN_ROOT/docker-compose.override.yml` and is shared across all worktrees — do not write it to `PROJECT_ROOT`.

### 2. Run install once

Named volumes start empty — always run install inside the container.

**Check the cache first**, the same way step 0a checked `credential_target`:
`$MAIN_ROOT/.coding-crew/dev-commands.json`'s `"install"` field may already hold this repo's
documented install command.

```bash
RAW=""
[ -f "$CACHE" ] && RAW=$(grep -o '"install"[[:space:]]*:[[:space:]]*\("[^"]*"\|null\)' "$CACHE" | head -1)
```

- A quoted command found — that is the target/command step a would otherwise have you guess at.
  Still dry-run it per step a's own rule below (a documented command can itself invoke docker),
  but skip hunting for which Makefile target it is.
- `null` — a model already confirmed no documented install override exists. Continue with steps
  a/b's own per-manifest-file detection unchanged; do not re-derive this from the Makefile
  yourself first.
- Empty (no cache file, or the key is missing) — continue with steps a/b unchanged, then persist
  whatever you conclude the same way step 0b does, using `{"install": "<command or null>"}`.

**a. Is there a Makefile `install`/`deps` target?** Check whether the Makefile has a public `install` or `deps` target whose recipe explicitly runs the package manager in every subdirectory that has a named volume (not just the root).

- **No** — skip to step b (run the package manager directly).
- **Yes** — dry-run it first, to make sure wrapping it in `docker compose run` would not nest docker inside docker:

  ```bash
  make -n install   # or: make -n deps
  ```

  - If that output already contains `docker compose`, `docker run`, or `docker exec` (directly, or via a variable — `make -n` expands those too), the recipe manages its own container. Run it **on the host, unwrapped** — do not put `docker compose run` around it — then skip the rest of this step:

    ```bash
    make install
    ```

  - Otherwise (no docker indirection in the recipe), run it inside the container and skip step b:

    ```bash
    docker compose \
      -f "$PROJECT_ROOT/docker-compose.yml" \
      -f "$MAIN_ROOT/docker-compose.override.yml" \
      run --rm <service> make install
    ```

**b. Run the package manager directly** for each directory with a named volume. Pass all `cd && install` commands in a single `sh -c` to avoid re-starting the container per directory:

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
