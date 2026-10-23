# Docker Install

Use this when the dev commands file's `install_mode` is `docker`. `PROJECT_ROOT` is inherited from the caller;
each bash call is a fresh shell, so write its literal value into every call.

Nothing runs on the host but docker itself: `docker-install.sh` and `run.sh` decide where every command runs.
Each checkout is its own compose project, with dependency volumes named by a hash of its manifests and
lockfiles, and crew's `docker` shim adds this checkout's generated override as the last `-f` of every
`docker compose` call. So:

- Use `docker compose` (v2), never `docker-compose`, and add no override, `-p` or git-env `-e` flags of your own:
  the override already names this checkout's compose project and carries its `GIT_DIR`/`GIT_COMMON_DIR`.
- **Never write the override manually**: `docker-install.sh` generates it, and a hand-written one has volume
  names without the lockfile hash. Nothing named `docker-compose.override.yml` is written into the repo; a
  project's own committed one is loaded unchanged, ahead of crew's.
- After setting or unsetting a proxy, CA or token variable (`HTTPS_PROXY`, `NPM_TOKEN`, …), re-run
  `docker-install.sh` (no `--force`) so the override passes it.
- **In your own terminal** (a human, outside an agent session), a bare `docker compose` loads the override once
  the shim is first on `PATH`: `export PATH="<skill-dir>/../coding-crew-lib/scripts/checks/shim:$PATH"`.

## 1. Install

```bash
bash "<skill-dir>/../coding-crew-lib/scripts/checks/docker-install.sh" --project-root "$PROJECT_ROOT" --timeout 1800
```

It reads `docker_service`, `install` and `registry_auth` from the dev commands file (dep-install's Step 1 has
already made sure they were asked: do not look for them yourself) and installs only when the volumes lack its
completion stamp, so a repeat call against unchanged lockfiles installs nothing. Add `--force` only on the
retry rule's module-not-found retry: a package installed into the volume since the stamp was written is not in
the lockfile, and `--force` reinstalls.

- **0** — the volumes hold the install: it ran, or the stamp was already there (`Present: …`). Go to step 2.
- **2** — nothing this mechanism can do here (no compose file, no service, no supported ecosystem). Report it
  plainly rather than guessing a workaround.
- **3** — the install command failed. Report `BLOCKED` with the stderr tail it prints, which ends
  `docker-install: failed — service <s>, step <step>, exit <n>`.

## 2. Every later command through `run.sh`

```bash
bash "<skill-dir>/../coding-crew-lib/scripts/checks/run.sh" --project-root "$PROJECT_ROOT" -- "<command>"
```

Every test, lint, type-check and other ad-hoc command, a one-off `docker compose` one included. Never
hand-build the `docker compose run` invocation.
