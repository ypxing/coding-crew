---
mode: feature
base_sha: 47e8d1ec1c29c22d4a8d10b7df476b3a9cf0aaab
head_sha: e092df11c1fffe6bb5deb99badc11ae82eb0902c
slug: docker-deps-isolation
via: refs/pull/382/head
---
Replay of the first feature review of docker-deps-isolation (`dispatch/feature-d1`, run 1: whole feature,
`[STATE] feature-reviewed tip=e092df11c1ff`): the diff `47e8d1ec1c29..e092df11c1ff`, one reviewer reading the
whole PRD (#378). The SHAs are reachable through `refs/pull/382/head` (PR #382's head, `6f3c64d`; the branch is
gone from origin); fetch it before running if they do not resolve. That review found 4 other defects (fixed in
#381) and missed this one; a manual review of the merged PR found it, and `5f88bf6` fixed it.
Escaped: `skills/dep-install/scripts/shim/docker:40` (and `shim/docker-compose`), where the shim looks for the real binary.
PRD D2 prescribes "searching `PATH` minus the shim's own dir" and #379's criterion repeated it, so the code matches the
PRD and the per-issue review passed it. No per-issue note exists for this one.

## Expected misses

- shim-mutual-exec: The shim finds the real docker by skipping only its own directory on `PATH` (`shim/docker:36-40`), as PRD D2 prescribes. With two copies of the shim on one `PATH` (two crew installs, or a project install and a user install, each with its `shim/` dir first), copy A skips its own dir, finds copy B's `docker` as the "real" binary and execs it; B skips its own dir, finds A's, and execs it: they exec each other forever (under bats, writing stderr until the disk fills).

## Reference judgement

D2 says the real binary is "found by searching `PATH` minus the shim's own dir", and `shim/docker` does exactly that, so a reviewer who checks the code against D2 finds it correct. It is not: the PRD's prescription fails on an input the shim can receive (another shim on `PATH`). The fix (`5f88bf6`) makes each copy carry a marker line and skip any candidate carrying it. Caught only if a finding says that two copies of the shim on one `PATH` find and exec each other without end (or that the PATH search can resolve to another shim), and names D2 as the decision that prescribes it. A finding about the override path, option parsing or `docker-compose` argument handling is not it; "matches D2, so fine" is a miss.

## PRD

<!-- PRD issue #378: PRD: Docker deps isolation: per-worktree override, compose shim, content-addressed volumes -->
### Problem Statement

Actor: a developer running crew-afk (or `/solve-issue`) on a docker-mode project.
Origin: #366

Docker mode shares one set of named dependency volumes, one `$MAIN_ROOT/docker-compose.override.yml` and one pinned compose project across every worktree and every sprint. Since #359 several sprints can run in one repo at once, and that model breaks:

1. **A second sprint wipes the first one's dependencies.** The sprint's one install (`ensure-deps.sh:507-563`, `--force`) reinstalls into the volume the first sprint's coders and verify gates are reading. A worker's own dep-install retry does the same inside one sprint.
2. **A worktree with a different lockfile has no install of its own.** The worktree call installs nothing (`ensure-deps.sh:486-505`). The one install reads the **main checkout's** lockfiles (`sprint.mjs:157`, `--dir mainRoot`), not the feature branch's.
3. **It depends on compose auto-discovering `docker-compose.override.yml`.**
   - The file is written into the repo root unconditionally (`gen-override.sh:561`), overwriting a project's own committed override.
   - It is symlinked into every worktree (`_link_override`, `worktree.mjs:40`).
   - A recipe that runs `docker compose -f a.yml -f b.yml` (common in repos with several compose files) never loads it, so it is refused outright (`detect-compose-bypass.sh`, `docker-install.sh:152-158`).

No incident is recorded. The source is the PR #365 feature-review finding `crew-finding:d252d728b8ce`, plus a stated requirement: two concurrent crew-afk runs on one machine in docker mode, with multi-compose-file repos supported.

### Solution

- Each worktree gets its own compose override, kept in its git dir, never in the repo tree.
- A small `docker` / `docker-compose` shim on `PATH` adds that override as the last `-f` to every `docker compose` call crew makes, whatever form the call takes. That covers crew's own calls, a project recipe's nested calls with or without `-f`, and calls a coder types.
- Dependency volumes are named by a hash of the lockfiles. A worktree, sprint or sandbox with the same lockfiles shares a populated volume; a different lockfile gets its own.
- Installs run only when the volume has no completion stamp, under a lock inside the volume. Nobody reinstalls into a volume someone else is reading.
- Unreferenced volumes are removed at worktree cleanup.

It works on a host with Docker Desktop, in a sandbox running its own `dockerd`, and in a sandbox using the outer host's socket.

### Behaviours

- **B1** — given a Makefile recipe running `docker compose -f a.yml -f b.yml run app npm test` in a docker-mode worktree, `run.sh -- make test` runs it with the worktree's override as the last `-f` and the dependency volumes mounted, at `run.sh` (bats, fake `docker` on `PATH`)
- **B2** — given a docker-mode setup, no file named `docker-compose.override.yml` is written or linked into `MAIN_ROOT` or any worktree; a project's own committed override is loaded unchanged, ahead of crew's, at `gen-override.sh` / `docker-install.sh`
- **B3** — given two worktrees with different lockfiles, each gets its own dependency volume name and its own install; given two with identical lockfiles, they map to one volume and the install runs once, at `ensure-deps.sh --slug` under `USE_DOCKER` (bats)
- **B4** — given a volume whose stamp is present, a second sprint's worktree install runs no install command and reports `DEPS: docker-present`, at `ensure-deps.sh`
- **B5** — given a branch whose lockfile changed after its deps install, verify installs into the new-hash volume before running checks, at `verify-worktree.sh`
- **B6** — given a coder dispatch, its env's `PATH` starts with the shim dir, so a bare `docker compose run` the coder types loads the override, at `buildDispatch` / `Sprint.childEnv()`
- **B7** — given volumes whose hash no live worktree or the main checkout maps to, `cleanup-worktrees.sh` removes them and leaves another owner's volumes alone, at `cleanup-worktrees.sh`

### Decisions

- **D1** — `gen-override.sh` writes the override to `$(git -C <project-root> rev-parse --path-format=absolute --git-dir)/crew-compose.override.yml`. A linked worktree's lands in `.git/worktrees/<name>/` and goes away with the worktree; the main checkout's lands in `.git/`. The file is per worktree, so it holds:
  - this worktree's own `GIT_DIR`/`GIT_COMMON_DIR` **values** as `environment:` entries;
  - the read-only `.git` mount at `/git-common` plus the `hooks`/`info` volumes;
  - the env passthrough names, platform and project-name pin, and sandbox CA bundle, as today (`gen-override.sh:508-552`).

  Every dependency volume gets an explicit top-level `name: wt_<proj>_<owner4>_<eco>_<dir>_<lock8>`:
  - `<lock8>` is one hash over all manifest and lockfile files the ecosystem scan finds, since one install writes every volume;
  - `<owner4>` is a hash of `hostname` + `MAIN_ROOT`'s realpath.

  An explicit `name:` means `-p`/`COMPOSE_PROJECT_NAME` no longer rename volumes. The rest of the detection and the `--query` fields stay as they are. Slice 1 introduces the location and the `GIT_DIR` values; slice 2 the hashed names.
- **D2** — `skills/dep-install/scripts/shim/docker` and `shim/docker-compose` (bash). Applies to `docker compose …` and `docker-compose …`:
  - **Placement:** inserts `-f <override>` after every `-f` the caller gave, just before the compose subcommand.
  - **With no `-f`:** first adds `COMPOSE_FILE`'s entries (split on `COMPOSE_PATH_SEPARATOR`, default `:`). Without `COMPOSE_FILE`, it adds the default compose file found in the working or `--project-directory` dir (`compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`) and that dir's `docker-compose.override.yml` when present.
  - **Finding the override:** `$CREW_COMPOSE_OVERRIDE` when set, else `<git-dir of cwd>/crew-compose.override.yml`. Neither exists (host mode, or not a git repo) → the call passes through unchanged.
  - **Option values skipped:** `-f/--file`, `-p/--project-name`, `--project-directory`, `--env-file`, `--profile`, `--ansi`, `--progress`, `--parallel`, and docker's `-c/--context`, `-H/--host`, `--config`, `-l/--log-level`.
  - **No subcommand found:** passes through unchanged with one `crew-shim: …` line on stderr.
  - Every other docker command passes through untouched.
  - **Real binary:** found by searching `PATH` minus the shim's own dir. Not found → exit 127 with `crew-shim: no real docker on PATH`.
- **D3** — Who puts the shim on `PATH`:
  - `run.sh` and `docker-install.sh` prepend `<SELF_DIR>/shim` and set `CREW_COMPOSE_OVERRIDE` explicitly. `run.sh` runs compose from the caller's cwd (`run.sh:173-188`), so a cwd lookup could miss.
  - `Sprint.childEnv()` (`sprint.mjs:206`) and `buildDispatch`'s shared env (`dispatch.mjs:42-50`) prepend `<CREW_INSTALL_DIR>/dep-install/scripts/shim` (`install-dir.mjs:19`) to `process.env.PATH`. `Effects` already merges `{...process.env, ...this.env, ...env}` (`effects.mjs:178,234,354`). The dispatch env is built by the orchestrator, so the platform adapters are untouched.

  Neither `run.sh` nor `docker-install.sh` builds `-f` or `-e` itself any more: they run `docker compose run --rm <svc> …`. `run.sh`'s `nested` route merges into `host`, so `--via` is `docker|host`; `detect-docker-nesting.sh` still decides whether a command is wrapped. `verify-worktree.sh:671` passes `--via` from `--describe`; it also accepts and ignores a stale `nested` from an older describe output. `--describe` drops `OVERRIDE_FILE` and prints `OVERRIDE=<path>`.
- **D4** — `docker-install.sh` installs only when a volume lacks its stamp. In one `docker compose run --rm <svc> sh -c …` (through the shim):
  1. If `<root vendor path>/.crew-stamp` exists, exit "present".
  2. Otherwise `mkdir <root vendor path>/.crew-lock`, writing its start epoch into it. Waiting is bounded by `--timeout`; a lock older than `--timeout` is removed and taken.
  3. Re-check the stamp, run the install, write the stamp, then remove the lock in a `trap` on every exit path (a signal killing the container's shell leaves the lock, which the stale rule recovers).

  An install command that runs docker itself takes and releases the lock in separate container runs around the host command; the empty-volume probe (exit 5, `docker-install.sh` step 4) stays. Failure writes no stamp and saves the log. Removed: `--force` on the sprint path, the `.scratch/docker-install.fingerprint` fast path (`docker-install.sh:105-121`), the 30s `--lock-timeout` and exit 4. `--force` stays for dep-install's module-not-found retry: it deletes the stamp, then installs under the lock.
- **D5** — `ensure-deps.sh`:
  - **`MAIN_ROOT` call in docker mode:** only `_merge_mode_cache docker <service>` (`:472`); no override, no install.
  - **Every `--slug` call** (issue, `_baseline`, `_integration`; `preflight.mjs:270`) runs `docker-install.sh` and reports `DEPS: docker-present` | `docker-installed <cmd>` | `failed <cmd> (exit N) (see <log>)`. The log goes to `<sprint dir>/docker-install-<stem>.log`.
  - **Removed:**
    - `DOCKER_MARKER`/`docker-install.done` (`:433`) and the `--link-only` call (`:500-501`);
    - the sprint-level `DEPS: docker-failed` and its handling, `main.mjs:845-847` with `dockerDepsFailureMessage` (`preflight.mjs:500`, imported `main.mjs:121`). A baseline whose install fails already returns `status: "fail"` (`preflight.mjs:324-326`), which stops the run as `[BASELINE-RED]` (`loop.mjs:169-173`).

  `prompts.mjs:24` and `report.mjs:219` describe the DEPS values and are updated to match.
- **D6** — `verify-worktree.sh`, in docker mode (per `run.sh --describe`), runs `docker-install.sh --project-root <dir>` (install-if-missing) before the first check. A failure fails the verify as a `deps` check with the install's tail. `CREW_VERIFY_DOCKER=off` skips it along with docker.
- **D7** — `cleanup-worktrees.sh`, after removing worktrees, runs `docker volume ls -q --filter name=^wt_<proj>_<owner4>_`. It keeps every name listed in a live `crew-compose.override.yml` (each `git worktree list --porcelain` entry's git dir, which covers every sprint of this repo, plus the main checkout's) and `docker volume rm`s the rest. A failed `rm` (volume in use) is skipped silently; no docker on `PATH` is a silent skip.
- **D8** — Removed:
  - **`gen-override.sh`:** the repo-root write (`:561`), `_link_override` and `--link-only` (`:195-227`), `--query git-env` (`:232-246`) and the bare `GIT_COMMON_DIR`/`GIT_DIR` passthrough entries (`:527-528`).
  - **`worktree.mjs:40`:** `docker-compose.override.yml` leaves `BUILTIN_ENTRIES`.
  - **`run.sh` / `docker-install.sh`:** `GIT_ENV_*` code at `run.sh:126-139,173-188` and `docker-install.sh:260-272`.
  - **`ensure-deps.sh:586-598`:** the host-mode `--query git-env` export. In host mode no crew override exists, so the shim passes through.
  - **`detect-compose-bypass.sh`:** keeps only the `docker run`/`docker exec` reason; `-f`, `COMPOSE_FILE` and `-p` no longer bypass.
  - **`resolve-mode.sh:98`:** the "`$MAIN_ROOT/docker-compose.override.yml` exists ⇒ docker" signal. The mode comes from git config and the `dev-commands.json` cache, as before.

  - **Cleanup of an older install's file:** `ensure-deps.sh`'s `MAIN_ROOT` docker call deletes a generated `$MAIN_ROOT/docker-compose.override.yml` an older install left (one holding a `wt_<PROJ_SLUG>_` volume key). A project's own file is never touched (see Compatibility).
- **D9** — Docs:
  - **`docker-install.md`:** the "always pass both `-f`" rule (`:17`), the git-env `-e` prose (`:19-25`) and the sample (`:184`) become "use `docker compose` as usual; crew's shim adds the override". It also documents one line for a human's own terminal: `export PATH="<skill-dir>/scripts/shim:$PATH"`.
  - **`dep-install/SKILL.md` and `solve-issue/SKILL.md`:** an ad-hoc command, a one-off `docker compose` one included, goes through `run.sh -- <cmd>`. Both skills' checks already go through `run.sh` (`solve-issue/scripts/run-checks.sh:78`).
- **D10** — `install.sh`'s `install_assets_tree` marks only `*.sh` executable (`install.sh:352`). It also marks every file under a `shim/` directory executable, so `PATH` lookup finds the extensionless `docker`/`docker-compose`.

Dependency direction: the orchestrator (`sprint.mjs`, `dispatch.mjs`) → crew-afk scripts (`ensure-deps.sh`, `verify-worktree.sh`, `cleanup-worktrees.sh`) → dep-install scripts (`run.sh`, `docker-install.sh`) → `gen-override.sh` and the shim. The shim depends on nothing but the override file's path.

### Trust Boundaries & Risks

- **The shim wraps every `docker` call** on crew's `PATH`. A parsing mistake must never drop or reorder the caller's arguments: an unrecognised shape passes through verbatim (D2). It never `eval`s its arguments; it execs the real binary with an argv array.
- **The lock lives inside a shared volume.** A holder killed by `SIGKILL` leaves it; the start-epoch stale rule bounds the wait to `--timeout`.
- **Cleanup deletes docker volumes.** It is scoped to this owner's name prefix and keeps any name a live override references, so another sandbox or clone's volumes are never matched.

### Compatibility & Migration

- **Behaviour changes for crew users:**
  - No more `docker-compose.override.yml` in the repo root or worktrees.
  - Volume names change, so the first sprint after upgrading does one cold install.
  - `DEPS: docker-failed` no longer exists.
  - `run.sh --via nested` and `gen-override.sh --query git-env`/`--link-only` are removed.
- **Left behind by older installs:**
  - **A generated `$MAIN_ROOT/docker-compose.override.yml`.** Its first line is `name: …` and it carries the `wt_<proj>_` volume names. Compose would still auto-load it for a bare call, so `ensure-deps.sh`'s `MAIN_ROOT` docker call deletes it **only** when it is a generated one (contains a `wt_<PROJ_SLUG>_` volume key). A project's own file is never touched.
  - **Worktree symlinks** to it go with their worktrees.
  - **Old `wt_<proj>_nm_*` volumes** (no owner component) are not matched by D7's prefix; the user removes them by hand (`docker volume ls -q --filter name=^wt_<proj>_`), and Further Notes says so.
  - **`.scratch/docker-install.{done,fingerprint}`** files go unread.

### Testing Decisions

- **Seam:** the scripts themselves, run by bats with a fake `docker` first on `PATH` that logs its argv and plays the volume (a temp dir per volume name), following `tests/dep-install-docker-install.bats` and `tests/verify-worktree-docker.bats`.
- **Shim matrix:** `-f a -f b` → ours last before the subcommand; `COMPOSE_FILE` set; discovery with and without the project's own override; `--project-directory`; each value-taking option's value not mistaken for the subcommand; non-compose commands, no override and unparseable input all pass through verbatim; the shim dir excluded when resolving the real binary.
- **#366's required case** under `USE_DOCKER`: two worktrees with different lockfiles get different volume names, each installed; identical lockfiles give one name and one install. Nothing named `docker-compose.override.yml` appears in either tree.
- **Install and cleanup:** stamp present → no install command; lock held → waits; stale lock taken; failure → no stamp; cleanup removes this owner's unmapped volumes only.
- **Orchestrator:** `node --test` checks that `childEnv()` and `buildDispatch`'s env start `PATH` with the shim dir.
- **Rewritten:** `tests/dep-install-gen-override-{project-name,git-mount}.bats`, `dep-install-detect-compose-bypass.bats`, `crew-afk-ensure-deps.bats`, `verify-worktree-docker.bats`, `dep-install-docker-install.bats`, and any `run.sh` test using `--via nested`.

### Out of Scope

- `docker run` / `docker exec` recipes (still refused).
- Bind-mount path translation for a sandbox that uses the outer host's docker socket (unchanged from today).
- Sharing volumes between two clones of one repo.
- A persistent package-manager cache volume.

### Further Notes

- **Accepted trade-offs:** a coder's in-container `npm install foo` adds to the old shared volume before the lockfile hash changes (additive); a lockfile change costs one cold install.
- **Manual acceptance (human, paid):** two concurrent crew-afk sprints on one real docker-mode repo, one of them changing a lockfile.
- **After upgrading:** remove old volumes with `docker volume rm $(docker volume ls -q --filter name=^wt_<proj>_nm_)`, or the ecosystem's prefix.
