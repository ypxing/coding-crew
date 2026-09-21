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
- **If `PROJECT_ROOT` is a linked worktree, always add this worktree's own git-mount `-e` flags too** — on every `docker compose run`, including install and every test/lint/type-check run. They are never baked into `docker-compose.override.yml` (that file is shared across every worktree; this worktree's `GIT_DIR` is not — see `gen-override.sh`'s own header comment), so each call resolves them fresh:

  ```bash
  GIT_ENV_ARGS=()
  while IFS= read -r line; do
    [ -n "$line" ] && GIT_ENV_ARGS+=(-e "$line")
  done < <(bash "<skill-dir>/scripts/gen-override.sh" --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" --query git-env)
  ```

  Empty for a plain (non-worktree) checkout, so `"${GIT_ENV_ARGS[@]}"` always expands safely — include it on every `docker compose run` below regardless of whether you already know `PROJECT_ROOT` is a worktree. Each bash tool call is a fresh shell (see the note above), so resolve `GIT_ENV_ARGS` in the *same* call as the `docker compose run` it applies to, not a separate one.

**Platform mismatch (`requested image's platform ... does not match the detected host platform`)**: `gen-override.sh` emits a `platform:` key per service matching the *host's* architecture by default — the override's later `-f` wins the compose merge, so this overrides whatever the project's own compose file or image pins, without editing that file. Set `CREW_DOCKER_PLATFORM=off` before generating the override if the image is genuinely single-arch and the host has emulation deliberately set up for it; `amd64`/`arm64`/`linux/...` force a specific platform regardless of host.

## Steps

Step 1 always calls `docker-install.sh`, whether or not `$MAIN_ROOT/.scratch/docker-install.done`
already exists or an override already sits at `$MAIN_ROOT/docker-compose.override.yml` — the
script itself checks its own fingerprint stamp and regenerates the override idempotently, so
there is no separate fast-path to skip ahead to by hand; a repeat call against an unchanged
`MAIN_ROOT` is already a fast no-op. Still apply the retry rule below if a later command fails
with a module-not-found error: a worktree's own branch may have added a dependency since the
last successful install.

Resolving and passing `GIT_ENV_ARGS` (see Never above) on every `docker compose run` you reach in
step 2 onward is never something to skip — it is per-invocation, not part of installing.

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

**Never read the contents of `.env*` or any credential config file** — not to log, not to inspect, not to verify.

Always continue to step 1 — this step never blocks. If `docker compose` later fails because a required env var is missing, stop and report blocked with the verbatim error.

### 1. Run install once, through the one locked mechanism every install goes through

**Check the install-command cache first**, the same way step 0a checked `credential_target`:
`$MAIN_ROOT/.coding-crew/dev-commands.json`'s `"install"` field may already hold this repo's
documented install command.

```bash
RAW=""
[ -f "$CACHE" ] && RAW=$(grep -o '"install"[[:space:]]*:[[:space:]]*\("[^"]*"\|null\)' "$CACHE" | head -1)
```

- A quoted command found — that is your `--install-cmd` below. Skip hunting for a Makefile
  target yourself; docker-install.sh dry-runs it for you (see below).
- `null` — a model already confirmed no documented install override exists. Continue without
  `--install-cmd`; do not re-derive this from the Makefile yourself.
- Empty (no cache file, or the key is missing) — check whether the Makefile has a public
  `install`/`deps` target whose recipe explicitly runs the package manager in every
  subdirectory that has a named volume (not just the root). If it does, that target invocation
  (e.g. `make install`) is your `--install-cmd`. Either way, persist whatever you conclude —
  the command, or `null` — so no future session re-scans this Makefile:

  ```bash
  cat > /tmp/install-discovery.json <<'JSON'
  {"install": "<the command you found, or null>"}
  JSON
  bash "<skill-dir>/scripts/write-commands-cache.sh" --response-file /tmp/install-discovery.json
  ```

**Then run `scripts/docker-install.sh`** — the one mechanism every docker install goes through,
whether this is a fresh worktree's own call or the sprint's own MAIN_ROOT warm-up
(`ensure-deps.sh`'s docker path). It generates the override, checks the fingerprint stamp
(skipping a no-op reinstall when nothing changed), dry-runs a Makefile `--install-cmd` for
docker-in-docker nesting before wrapping it, and — the reason to call it here instead of
hand-running `docker compose` yourself — takes a lock shared across every worktree of this
`MAIN_ROOT` before actually installing, so this call and any other install already in flight
(the sprint's own warm-up, or a sibling worktree's own dep-install session) can never run at the
same time against the same shared volume:

```bash
bash "<skill-dir>/scripts/docker-install.sh" \
  --project-root "$PROJECT_ROOT" --main-root "$MAIN_ROOT" \
  --lock-timeout 1800 \
  # only if step 0 resolved one:
  --credential-target "make _registry" \
  # only if the cache/Makefile check above resolved one:
  --install-cmd "make install"
```

Unlike every other `docker compose` call in this guide, this one needs no `GIT_ENV_ARGS` of your
own — `docker-install.sh` resolves and passes them itself for the `docker compose run` it
constructs internally.

Handle its exit code:

- **0** — installed (or skipped: manifests unchanged since the last successful install into
  this shared volume). Continue to step 2.
- **2** — nothing this mechanism could do here (no compose file, no service, no supported
  ecosystem, or an `--install-cmd` that itself invokes docker — nesting it would just repeat the
  same docker-in-docker failure). Report this plainly rather than guessing a workaround.
- **3** — the install command failed *inside* the container. Report `BLOCKED` with the tail of
  output the script prints to stderr.
- **4** — could not acquire the lock within `--lock-timeout`: another install (the sprint's own
  warm-up, or a sibling worktree) is still running. **Stop and report `BLOCKED`** with that
  message — do not fall back to running `docker compose` yourself. That fallback is exactly the
  unlocked, uncoordinated install this mechanism exists to prevent: two installs racing the same
  shared named volume causes real lock contention inside the container (a package manager's own
  lockfile, or dpkg/apt), not just a herdr-UI nuisance. If this repeats, the sprint's own
  warm-up may itself be stuck — that is a sprint-level problem to surface, not something this
  session should retry around.

### 2. All subsequent `docker compose` commands must pass both `-f` flags and this worktree's git-env args

**Complete steps 0–1 in order before running any `docker compose` command. Do not skip ahead.**

Pass both `-f "$PROJECT_ROOT/docker-compose.yml" -f "$MAIN_ROOT/docker-compose.override.yml"` on every `docker compose` command — including test, lint, and type-check runs. Never omit the `-f override` flag. Resolve and pass `"${GIT_ENV_ARGS[@]}"` (see Never above) on every one of these too, in the same bash call — a lint/test run that shells out to git (coverage tooling, a `--changed` flag, a release plugin reading the commit SHA) hits the same unmountable-host-path failure an install-time postinstall hook does.

## Install failures

If install fails because the container's entrypoint ignores the command, check the compose file for an `entrypoint:` key and override it:

```bash
docker compose \
  -f "$PROJECT_ROOT/docker-compose.yml" \
  -f "$MAIN_ROOT/docker-compose.override.yml" \
  run --rm "${GIT_ENV_ARGS[@]}" --entrypoint sh <service> -c "<install-command>"
```

If install fails due to missing auth tokens, network errors, or Docker not running — stop immediately and report blocked with the verbatim error. Do not attempt workarounds.

If install fails with `fatal: not a git repository: .../worktrees/<name>` from a postinstall hook (lefthook, husky, simple-git-hooks, etc.), that is a linked worktree's `.git` file pointing at an absolute host path the container can't see. `gen-override.sh` already mounts `MAIN_ROOT`'s `.git` read-only in the shared override (`/git-common`, plus a writable `info/` overlay for lefthook's own config-checksum write there); the failure almost always means `GIT_ENV_ARGS` (see Never above) was resolved but not actually passed on *this* `docker compose run` — double-check the `-e` flags are on the exact command that failed, in the same bash call that resolved them. If they were passed and the failure persists, the project's tooling is likely resolving git some other way (e.g. `GIT_WORK_TREE`, a submodule) that `GIT_DIR`/`GIT_COMMON_DIR`/`core.hooksPath` don't cover. Report blocked with the verbatim error rather than hand-editing the override.
