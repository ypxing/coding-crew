# Changelog

## [1.29.58]

### Added

- **`crew-afk` can now hold the reviewer and triage judge to a different model tier than the
  coder, explicitly** — previously `--model` applied identically to all three, with no way to
  say "review stricter than the coder wrote it." An optional `.coding-crew/afk-models.json`
  (`{coder, reviewer, triage}`, all keys optional) fills this in: an omitted `reviewer`/`triage`
  still defaults to the coder's own resolved model (the existing guarantee — a role can never
  end up weaker by accident, only by an explicit, on-record choice), and `--model` on the CLI
  still overrides the file's `coder` for that run. No numeric ranking across arbitrary model
  strings (most of this repo's own platforms pass an opaque string through to their own CLI, so
  a universal rank table would be a lie); the one case this repo does know a real order for —
  Claude Code's own `opus`/`sonnet`/`haiku` aliases — gets an advisory (non-blocking) warning
  when a role explicitly diverges to a weaker one.
- **Dispatch logs now name the model and issue actually used.** The orchestrator's own trace log
  (`orchestrator.log`) gains `model=<value>` on every `dispatch-coder`/`dispatch-review`/
  `dispatch-triage` step marker — previously only the `pi`/`codex` platforms' own dispatch-script
  logs recorded a model at all, and none of the four platforms' logs named which issue a
  `[DISPATCH]` line belonged to. `dispatch-agent.sh`/`dispatch-codex-agent.sh`'s `[DISPATCH]`
  line now also carries `slug=<issue>`, matching the convention their own `[TOOL]`/`[TOOL-ERROR]`
  lines already used.
  - registry.json: crew-afk 2.2.44 -> 2.2.45 (`orchestrator/lib/pipeline.mjs`,
    `orchestrator/lib/model-config.mjs`, `skills/crew-afk/scripts/dispatch-agent.sh`,
    `skills/crew-afk/scripts/dispatch-codex-agent.sh`).

## [1.29.57]

### Fixed

- **Resuming a `crew-afk` sprint from wherever the shell happened to be sitting could silently
  adopt the wrong branch as the feature branch**: `session-init.sh`'s default-branch heuristic
  only checked whether the current branch equaled the repo's default branch, so re-running with a
  slug that already had a `.scratch/<slug>/sprint.env` from an earlier session — while sitting on
  an issue branch left over from a prior round, a detached HEAD, or a colleague's branch — read
  "not on default" as "already on the right one" and never switched to the recorded
  `FEATURE_BRANCH`. Fixed by pinning to the session's recorded feature branch first, checking it
  out if the shell isn't already there, before either branch-setup path runs.
- **A reused issue branch (this round's resume, or a worktree left over from an earlier
  `crew-afk` invocation) could fork from the feature branch before other issues merged into it**,
  leaving the coder to work from a stale base and the gap to surface as an unexplained conflict at
  the merge gate ~45 minutes later. `ensureWorktree` now flags a reused branch, and `runWorker`
  forward-merges the feature branch into it inside its own worktree before the coder starts; a
  merge conflict aborts cleanly and reports the issue as blocked instead of masking it.
  - registry.json: crew-afk 2.2.43 -> 2.2.44 (`orchestrator/lib/pipeline.mjs`,
    `orchestrator/lib/worktree.mjs`, `skills/crew-afk/scripts/session-init.sh`).
- **`gen-override.sh`'s per-ecosystem passthrough vars were named and commented as if they only
  ever carried proxy settings**, which obscured that the same bare-name convention also covers
  non-proxy secrets — Node's `NPM_TOKEN` for private-registry auth during `npm install` was
  missing from the list entirely. Renamed `ECO_PROXY_VARS` to `ECO_ENV_PASSTHROUGH` and added
  `NPM_TOKEN` to the Node ecosystem's list.
  - registry.json: dep-install 1.3.21 -> 1.3.22 (`skills/dep-install/scripts/gen-override.sh`).

## [1.29.56]

### Fixed

- **The git-common mount's per-worktree `GIT_DIR`/`GIT_COMMON_DIR`/`hooksPath` redirect never
  reached a project's own nested `docker compose run`**: `gen-override.sh --query git-env` only
  ever gets consumed as `-e KEY=VALUE` flags on a `docker compose run` our own scripts invoke
  directly (`docker-install.sh`, `verify-worktree.sh`'s non-nested path). When a project's own
  Makefile/script recipe shells out to `docker compose run` itself — exactly the case
  `detect-docker-nesting.sh` exists to detect, so we run it on the host instead of nesting it —
  there is no compose invocation of ours to attach `-e` flags to. The shared override's
  `/git-common` mount still reached that nested container for free (compose auto-discovers
  `docker-compose.override.yml`), but the env vars did not, so git inside it fell back to the
  worktree's unmountable absolute host `gitdir:` pointer and any git command (most commonly a
  package manager's postinstall hook running `lefthook install`) failed with
  `fatal: not a git repository`. Fixed in two parts: `gen-override.sh` now also emits
  `GIT_COMMON_DIR`/`GIT_DIR`/`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` as bare
  `environment:` passthrough entries in the shared file (same convention as the proxy vars —
  names only, no worktree-specific value ever written to the shared file); `verify-worktree.sh`'s
  docker-nesting branch and `ensure-deps.sh`'s cached-install host exec now `export` the same
  `--query git-env` output into their own process env before running the host command, so its
  inner `docker compose run` picks the values up from there instead of from a `-e` flag.
  - registry.json: dep-install 1.3.20 -> 1.3.21 (`skills/dep-install/scripts/gen-override.sh`),
    crew-afk 2.2.42 -> 2.2.43 (`skills/crew-afk/scripts/verify-worktree.sh`,
    `skills/crew-afk/scripts/ensure-deps.sh`).

## [1.29.55]

### Fixed

- **The git-common mount added in 1.29.50/1.29.51 never actually applied in the `crew-afk`
  sprint path**: it only fired when `gen-override.sh` was invoked with `--project-root` set to
  a linked worktree, but the pipeline's real generation call is always `--project-root=$MAIN_ROOT`
  (`ensure-deps.sh`'s one sprint-wide call, before any worktree exists) — every worktree only ever
  symlinks to that file, so the mount's env vars were never computed for any of them. A worktree's
  own `docker compose run` (a mid-sprint install after a new dependency, or any test/lint/typecheck
  command shelling out to git) could still hit `fatal: not a git repository` from a linked
  worktree's unmountable `.git` file — the exact failure the mount was written to close.
  `gen-override.sh`'s `GIT_DIR` is inherently per-worktree, but the override file it would have to
  live in is shared across every worktree by design, so baking it into that file was never going
  to work under concurrent worktrees anyway (two worktrees' own generation calls would clobber
  each other's `GIT_DIR`). Split the fix in two instead: the mount itself (read-only `MAIN_ROOT/.git`
  bind + writable `info/` overlay) is identical for every worktree and now always baked into the
  shared file, generated from `MAIN_ROOT` alone; the worktree-specific env vars
  (`GIT_DIR`/`GIT_COMMON_DIR`/the `core.hooksPath` redirect) are resolved fresh per invocation via
  a new `gen-override.sh --query git-env` and passed as `docker compose run -e` flags — cheap,
  stateless, and safe under concurrency since nothing is written to disk. Wired into
  `docker-install.sh`, `verify-worktree.sh`, and `docker-install.md`'s worker-facing instructions.
  - registry.json: dep-install 1.3.19 -> 1.3.20 (`skills/dep-install/scripts/gen-override.sh`,
    `skills/dep-install/scripts/docker-install.sh`, `skills/dep-install/references/docker-install.md`),
    crew-afk 2.2.41 -> 2.2.42 (`skills/crew-afk/scripts/verify-worktree.sh`).

## [1.29.54]

### Fixed

- **1.29.53 made the docker-mode dependency check unskippable in prose, but a worker was still
  observed substituting its own `node_modules`/`PATH` probing for it** — a STOP instruction can't
  force a tool call. `ensure-deps.sh` already resolves `install_mode`/`docker_service` into
  `.coding-crew/dev-commands.json` before any worktree or worker exists, so the orchestrator now
  hands that verdict to the coder directly as `INSTALL_MODE=`/`DOCKER_SERVICE=` in its dispatch
  prompt, the same way `MAIN_ROOT` is already handed over rather than derived. `solve-issue` trusts
  a stated `INSTALL_MODE` outright and skips its own detection script, but still invokes
  `dep-install` unconditionally when it says `docker` — receiving the mode as a fact doesn't make
  install optional. A direct, non-orchestrated `/solve-issue` run (no cache yet) is unaffected: the
  worker's own detection step remains the fallback.
  - registry.json: crew-afk 2.2.40 -> 2.2.41 (`orchestrator/lib/prompts.mjs`), solve-issue 1.9.10 ->
    1.9.11 (`skills/solve-issue/SKILL.md`).

## [1.29.53]

### Fixed

- **solve-issue's dependency step let a worker's own probing (checking for `node_modules`/`.venv`,
  a package manager on `PATH`, etc.) substitute for the docker-mode check**, so a docker-mode
  project could skip straight to Step 3 without ever installing deps. The skill now tells the
  worker to run the docker-mode check first, before any other exploration, and makes explicit that
  docker mode's `dep-install` invocation is never optional or deferred to "if a command fails" —
  docker mode has no host-side fallback.
  - registry.json: solve-issue 1.9.9 -> 1.9.10 (`skills/solve-issue/SKILL.md`).

## [1.29.52]

### Fixed

- **lefthook's config-checksum write under commondir's `info/` had no config-based override the
  way `core.hooksPath` covers hooks**, so it still hit the read-only `/git-common` mount from
  1.29.50/1.29.51 and failed install inside a real linked worktree. `gen-override.sh` now overlays
  a second, writable named volume at `/git-common/info` on top of the read-only mount — Docker
  resolves the more specific bind target on top of the broader one, so only that subdirectory
  becomes writable while objects/refs/hooks stay read-only underneath it.
  - registry.json: dep-install 1.3.18 -> 1.3.19 (`skills/dep-install/scripts/gen-override.sh`,
    `skills/dep-install/references/docker-install.md`).
- **`.env` reached a worktree only via `dep-install`'s `ensure-env.sh`, which requires a worker to
  have actually reached that step first** — a worktree created before then (or a worker that never
  gets there) never gets it. `ensureWorktreeInclude()` now lists `.env` in `.worktreeinclude`
  alongside `docker-compose.override.yml`, so every worktree's own `applyWorktreeInclude()`
  symlinks it in deterministically at creation time instead, same as the override entry already
  gets.
  - registry.json: crew-afk 2.2.39 -> 2.2.40 (`orchestrator/lib/worktree.mjs`, `orchestrator/main.mjs`).

## [1.29.51]

### Fixed

- **1.29.50's git metadata mount broke installs it had never touched before**: it fired for
  *any* git checkout, not just linked worktrees, so a plain (non-worktree) checkout's already-
  writable `.git` (reachable through the project's normal bind mount) got redirected to the new
  read-only `/git-common` mount instead — breaking `lefthook install`/`husky`/etc. with
  `read-only file system` where nothing was broken before. Also, since git hooks always live in
  the shared commondir (never per-worktree), even a genuine linked worktree hit the same
  read-only failure on hook install. `gen-override.sh` now only mounts/overrides
  `GIT_DIR`/`GIT_COMMON_DIR` when `PROJECT_ROOT`'s gitdir actually sits under
  `commondir/worktrees/<name>` (a real linked worktree), and redirects `core.hooksPath` to a
  writable scratch dir (`/tmp/git-hooks-container`) via `GIT_CONFIG_*` env vars so a hook
  installer's write never touches the read-only mount at all.
  - registry.json: dep-install 1.3.17 -> 1.3.18 (`skills/dep-install/scripts/gen-override.sh`,
    `skills/dep-install/references/docker-install.md`).

## [1.29.50]

### Added

- **A worktree's git metadata is an absolute host path a docker container can never see**, so any
  git command run inside one — most commonly a package manager's postinstall hook
  (lefthook/husky/simple-git-hooks) — failed with `fatal: not a git repository`, taking the whole
  install step down with it. `gen-override.sh` now mounts `MAIN_ROOT`'s real `.git` dir read-only
  at a fixed container path (`/git-common`) and sets `GIT_DIR`/`GIT_COMMON_DIR` to it, so git never
  needs to resolve the unmountable path at all. Controlled by `CREW_GIT_MOUNT` (`on` by default,
  `off` to disable); resolved once per project regardless of ecosystem, and fails soft (no mount)
  when the project root isn't a real git checkout.
  - registry.json: dep-install 1.3.16 -> 1.3.17 (`skills/dep-install/scripts/gen-override.sh`,
    `skills/dep-install/references/docker-install.md`).

## [1.29.49]

### Fixed

- **A multi-service `docker-compose.yml` could route every check through the wrong service**:
  `verify-worktree.sh`/`docker-install.sh` fell back to whichever service `gen-override.sh`
  happened to list first, with no awareness of which service actually has the project's
  toolchain (e.g. a `node` service alongside an unrelated `compass` service with no `pnpm`) —
  every typecheck/lint/test call silently ran against the wrong container. A new
  `detect-service.sh` best-effort probes a project's own Makefile recipes (`docker compose run
  --rm node ...`) for the service a human already told it to use, and `ensure-deps.sh` caches
  the result as `dev-commands.json`'s new `"docker_service"` field — read by both scripts ahead
  of the file-order fallback, alongside the existing `agent.install-service` git-config override.
  A miss leaves the field unset and every reader falls back to today's behavior unchanged.
- **Renamed `dev-commands.json`'s `"mode"` field to `"install_mode"`** for clarity now that it
  has a `"docker_service"` sibling — a bare `"mode"` read ambiguously next to `"install"`
  (the install command). `detect-mode.sh` and `ensure-deps.sh`'s `_merge_mode_cache` both read
  and write the new name; an old cache with only `"mode"` simply misses once and re-derives.
  - registry.json: crew-afk 2.2.38 -> 2.2.39 (`skills/crew-afk/scripts/ensure-deps.sh`,
    `skills/crew-afk/scripts/verify-worktree.sh`), dep-install 1.3.15 -> 1.3.16
    (`skills/dep-install/scripts/detect-mode.sh`, `skills/dep-install/scripts/docker-install.sh`,
    new `skills/dep-install/scripts/detect-service.sh`).

## [1.29.48]

### Fixed

- **Host installs never wrote the `.coding-crew/dev-commands.json` `"mode"` cache** the previous
  release added for docker — only the docker branch of `ensure-deps.sh` called
  `_merge_mode_cache`, so a host project still paid `detect-mode.sh`'s full Makefile `make -n`
  dry-run loop on every worktree/issue. `ensure-deps.sh`'s `MAIN_ROOT` call now also caches
  `host` mode when resolution lands there.
- **`detect-mode.sh` aborted under `set -euo pipefail`** reading a `dev-commands.json` that has
  no `"mode"` field yet (e.g. one written before this cache existed): `grep` finds nothing,
  exits non-zero, and pipefail took the whole pipeline down with it. The `sed` stage now ends
  with `|| true` so a cache miss falls through to the existing detection order instead of
  crashing.
  - registry.json: crew-afk 2.2.37 -> 2.2.38 (`skills/crew-afk/scripts/ensure-deps.sh`),
    dep-install 1.3.14 -> 1.3.15 (`skills/dep-install/scripts/detect-mode.sh`).

## [1.29.47]

### Fixed

- **The docker/host mode verdict was cached to `.scratch/install-mode`**, a per-sprint scratch
  file that a fresh sprint (or a worker resolving a different install of `dep-install` outside
  `.scratch`) never saw, forcing re-detection every time. `ensure-deps.sh` now merges the verdict
  into the committed `.coding-crew/dev-commands.json`'s `"mode"` field instead — trusted
  indefinitely, the same as its `install`/`env`/`credential_target` fields — via a new
  `_merge_mode_cache` helper that preserves the other fields already in that file rather than
  clobbering them. `detect-mode.sh` and `dep-install`'s `SKILL.md` read the same field.
- **`detect-mode.sh`'s Makefile heuristic was a static `awk` text scan** for `docker compose`/
  `docker run`/`docker exec` inside a hand-picked set of candidate targets, so any indirection
  through a Make variable or `ifeq` branch it didn't special-case resolved to the wrong mode.
  It now dry-runs each candidate target with `make -n` and greps the expanded recipe instead —
  the same pattern `host-install.sh` and `ensure-env.sh`'s `_makefile_env_command` already use —
  so Make itself resolves the indirection.
  - registry.json: crew-afk 2.2.36 -> 2.2.37 (`skills/crew-afk/scripts/ensure-deps.sh`),
    dep-install 1.3.13 -> 1.3.14 (`skills/dep-install/SKILL.md`,
    `skills/dep-install/scripts/detect-mode.sh`).

## [1.29.46]

### Added

- **`selectDispatchable`'s `## Blocked by` parsing only recognized literal `NN-slug.md`
  filenames**, but issues are commonly cross-referenced as `Issue NN` prose, and any dependency
  written that way was silently invisible to the dispatch gate. `to-issues` now also writes
  `.scratch/<feature-slug>/issues/issues-deps.json` — a flat filename -> blocker-filenames map
  sourced from the same blocking edges the user already confirmed — and `parseIssue` prefers that
  file over the markdown heuristic when it has an entry for the issue. `resolveBlockedBy` is the
  fallback: it still resolves `Issue NN` references to a sibling filename in `open/` or `done/`
  for issues with no JSON entry.
  - registry.json: crew-afk 2.2.35 -> 2.2.36 (`orchestrator/lib/tracker.mjs`), to-issues 1.4.0 ->
    1.4.1 (`skills/to-issues/SKILL.md`).

## [1.29.45]

### Fixed

- **A `crew-code-reviewer` `AC: unmet` verdict sent the coder back through the full
  `workerPrompt` + resume-note restart** — the same re-read-the-whole-issue-from-scratch path
  used for a brand-new issue, even though the reviewer had just judged the branch's code
  acceptable overall and flagged only a specific unmet criterion. `runHousekeeping` now tags
  that verdict with a new `criteria-unmet` reason (alongside the existing
  `verification-failed:fixable`/`:not-fixable` tags), and `runWorker` routes it to `fixPrompt`
  instead — the same narrower retry a fixable verify failure already gets. `fixPrompt` gains a
  `kind` parameter (`"verify"` | `"review"`) so the prompt correctly attributes the fix to the
  reviewer's verdict rather than a triage pass.
  - registry.json: crew-afk 2.2.34 -> 2.2.35 (`orchestrator/lib/pipeline.mjs`,
    `orchestrator/lib/prompts.mjs`).

## [1.29.44]

### Fixed

- **A docker-mode project's `docker-compose.override.yml` could miss a first-round worktree
  entirely.** The only path that carried it into a worktree was `gen-override.sh`'s
  docker-present fast path inside `ensure-deps.sh`, which requires `DOCKER_MARKER` already on
  disk — a race the first round's concurrently-created worktrees could lose, leaving that
  worktree without the override and no later step to add it. `orchestrator/lib/worktree.mjs`
  gains `ensureWorktreeInclude()`, called once from `main.mjs` before any worktree exists for the
  sprint, which adds `docker-compose.override.yml` to the repo's `.worktreeinclude` manifest if
  it isn't already listed. Every worktree's own `applyWorktreeInclude()` then symlinks it in
  deterministically at creation time instead of depending on that race. A no-op when the entry is
  already present, and safe to call even when the project has no
  `docker-compose.override.yml` at all — `applyWorktreeInclude()` already skips entries whose
  source is missing.
  - registry.json: crew-afk 2.2.33 -> 2.2.34 (`orchestrator/lib/worktree.mjs`,
    `orchestrator/main.mjs`).

### Docs

- Reworked README.md: install instructions and a 3-step quickstart now lead the page, the plan/
  build/review walkthrough is condensed, and the platform-specific caveats (Copilot's `--agent`
  resolution, pi/Codex local-CLI-only support) are consolidated instead of repeated across
  sections. No behavior change.

## [1.29.43]

### Changed

- **`credential_target` now caches a full command (e.g. `"make _registry"`), not a bare
  Makefile target name — the same shape `install`/`env` already use.** A human hand-editing
  `.coding-crew/dev-commands.json` had no way to tell, from the file alone, that this one field
  (of six) held a bare name while the other five held runnable commands; the mismatch also meant
  a target name alone couldn't express "run this via something other than a plain `make`
  invocation." `discover-commands.sh`'s prompt and `docker-install.md`'s manual fallback both now
  ask for the command, and `ensure-env.sh` `eval`s it directly instead of reconstructing
  `make -C <dir> <target>` itself.
  - `ensure-env.sh` now runs a discovered `credential_target` command through
    `detect-docker-nesting.sh` first — the same guard `docker-install.sh`'s `--install-cmd` and
    `verify-worktree.sh`'s discovered test/lint/typecheck commands already use — so a
    credential-generating recipe that already invokes docker itself is skipped (falling back to
    the mechanical `.tpl`-expansion convention) rather than risking a nested `docker compose run`
    with no docker CLI to nest into.
  - A failing or nesting-unsafe `credential_target` command now falls through to the `.tpl`
    fallback instead of aborting the script — fixing a latent gap where `set -e` made this step's
    documented "never blocks" contract untrue for this one field.

## [1.29.42]

### Added

- **`dev-commands.json` gains a sixth cached field, `credential_target`: the Makefile target
  (if any) whose recipe generates package-manager credential config files (`.npmrc`, `pip.conf`,
  `.cargo/credentials.toml`, …) from a template or env vars.** Until now every dep-install
  session that needed this answer re-scanned the project's Makefile by hand
  (`docker-install.md`'s own step 0), every time, because there was nowhere to cache a model's
  conclusion the way `install`/`env` already were. `discover-commands.sh`'s sprint-level prompt
  now asks about it as a sixth category alongside test/lint/typecheck/install/env, and
  `docker-install.md`/`host-install.md` both check the cache first and persist their own
  from-scratch conclusion back to it when they have to look themselves.
  - `write-commands-cache.sh` now merges rather than overwrites: a response is only authoritative
    for the fields it actually names, so a caller that only ever investigates a subset (e.g.
    solve-issue's own DISCOVER fallback, which only ever determines test/lint/typecheck) no
    longer clobbers a previously-cached `install`/`env`/`credential_target` value back to `null`.
    A field neither this response nor any earlier write ever named is omitted from the file
    entirely, distinct from a cached `null` ("a model already looked and found nothing").
  - `ensure-deps.sh` forwards a cached `credential_target` to `docker-install.sh`'s new
    `--credential-target` flag, which passes it straight through to `ensure-env.sh`.
  - No change to the `install`/`env` cache semantics beyond the merge fix above, and no change
    to gate order, receipts, or dispatch mechanics.

registry.json: crew-afk 2.2.31 -> 2.2.32, dep-install 1.3.11 -> 1.3.12, solve-issue 1.9.7 ->
1.9.8 (solve-issue's own files are unchanged; its DISCOVER fallback now benefits from
write-commands-cache.sh's merge fix without any wording change of its own).

## [1.29.41]

### Fixed

- **A demoted worker's unmet acceptance criteria weren't guaranteed to survive into the next
  round's resume.** `finishPartial` wrote the issue's `## Progress` section from the worker's
  free-text `progress`/`notes` field alone; if the coder's own summary didn't happen to name
  every gap it had already identified in its report's structured `criteria` array, the next
  round's worker had no way to know about it short of re-discovering it itself. `finishPartial`
  now also appends any of the worker's own `criteria` entries reported as unmet, verbatim, to
  the Progress note — carrying forward the structured signal instead of depending on the prose
  restating it. (Not applicable to a partial retained by the independent review's own
  criteria-unmet verdict — there the worker believed everything was met, so its own array is
  empty and the review's detail already rides in the demotion reason.)

## [1.29.40]

### Fixed

- **A worker's own up-front `detect-mode.sh` check could disagree with `ensure-deps.sh`'s
  `DEPS: docker` verdict for the same worktree, silently falling back to a host-mode
  install with no deps in either mode.** `ensure-deps.sh` persisted its docker verdict only
  via `git config --local agent.install-mode` — a key shared by every worktree of one
  checkout (not per-worktree, despite being written from inside one), written once per
  issue by a step that now runs concurrently across issues (`mapPool`). A lock race between
  two issues' `ensure-deps.sh` calls could silently drop the write (`2>/dev/null || true`),
  and a worker resolving a different install of `dep-install` than `ensure-deps.sh` used (a
  different platform's skill copy, a stale global one) had no shared signal to fall back on
  either. `detect-mode.sh` now also checks a plain cache file,
  `$MAIN_ROOT/.scratch/install-mode`, written once by `ensure-deps.sh`'s single MAIN_ROOT
  call (before any worktree exists, so there is nothing to race), ahead of its own Makefile
  heuristic — a fixed, well-known path any copy of `detect-mode.sh` can agree on regardless
  of which one answers.
- **A worktree that reached `DEPS: docker-present` (the fast path, MAIN_ROOT's shared docker
  volume already warmed) never got its own `docker-compose.override.yml` symlink.**
  `docker-install.md` tells a worker on this fast path to skip straight to "run install",
  which skips the only step (`gen-override.sh`) that creates it; `ensure-deps.sh`'s own fast
  path never called it either. Mechanical gates (`verify-worktree.sh`, `docker-install.sh`)
  always pass `-f $MAIN_ROOT/docker-compose.override.yml` explicitly and never needed the
  symlink, but a bare `docker compose run` a worker or human types by hand silently lost the
  override (proxy vars, platform pin, and the shared named volume) in that worktree.
  `gen-override.sh` gains `--link-only`, which just (re)points the worktree's own
  `docker-compose.override.yml` at MAIN_ROOT's without regenerating it; `ensure-deps.sh`
  calls it on the `docker-present` fast path.

registry.json: crew-afk 2.2.29 -> 2.2.30, dep-install 1.3.10 -> 1.3.11.

## [1.29.39]

### Changed

- **`solve-issue` and `to-prd` now guard against redundant context re-billing** — `solve-issue`'s exploration step tells the agent to batch grep patterns and file reads into fewer, larger tool calls rather than one call per item (each call re-bills the whole accumulated context), and its verification reference runs typecheck/lint/tests as one composite shell invocation that captures every exit code instead of three sequential calls. `to-prd` now also asks the PRD's technical-decisions section to name existing utilities/conventions issue implementers should reuse, so each issue's coder doesn't have to re-grep for context the PRD skill already gathered.

registry.json: solve-issue 1.9.6 -> 1.9.7, to-prd 1.2.1 -> 1.2.2.

## [1.29.38]

### Changed

- **Refactored docker-in-docker nesting detection into a shared utility** — extracted the heuristic that prevents nesting docker-in-docker from `verify-worktree.sh` into a new `detect-docker-nesting.sh` script so both `verify-worktree.sh` (discovered test/lint/typecheck commands) and `docker-install.sh` (--install-cmd override) can share the same logic and stay in sync.

registry.json: crew-afk 2.2.28 -> 2.2.29, dep-install 1.3.9 -> 1.3.10.

## [1.29.37]

### Fixed

- **docker-install.sh now catches docker-in-docker nesting via --install-cmd** — when the override command names docker directly or runs a Makefile target that shells out to docker, it exits with code 2 (nothing to do) instead of nesting into another layer where docker CLI would be absent.

## [1.29.36]

### Fixed

- **Improved error handling and reliability in `ensure-deps.sh` and `docker-install.sh`** with enhanced test coverage for edge cases and dependency installation scenarios.

## [1.29.35]

### Changed

- **All skill description files across platforms (`claude.SKILL.md`, `codex.SKILL.md`,
  `copilot.SKILL.md`, `pi.SKILL.md`) now consistently document the live stream behavior** — unified
  wording that describes step markers and throttled heartbeats as the primary signal, and directs
  users to the trace file only when they need deeper detail. Aligns with Tier 0 PRs 1–4 of the
  sprint-visibility plan.

## [1.29.34]

### Added

- **crew-afk sprints now stream a throttled live heartbeat during coder/review/triage
  dispatch, and every trace-file line is formatted consistently** — PRs 2–4 of the
  sprint-visibility plan (`.scratch/crew-afk-visibility/plan.md`), building on PR 1's
  `[STEP]` markers.
  - PR 2: pi and codex previously had no live signal at all during a dispatch (only
    claude/copilot did — pi's/codex's own bash dispatchers only ever wrote to the trace
    file). `dispatch-agent.sh`/`dispatch-codex-agent.sh` now also print a throttled copy of
    their `[TOOL]`/`[TOOL-ERROR]` line to stdout (every 5th call or 30s, whichever comes
    first); `dispatch.mjs` wires this live for every platform via a new `onTrace` callback,
    which `pipeline.mjs` routes into `ctx.log`, slug/round-tagged. Full per-tool-call detail
    keeps going to the trace file only, unthrottled. Verified end to end on a 3-issue,
    `--max-parallel 3` sprint: total live-stream output stayed at ~4.9KB/132 lines,
    comfortably under pi's 50KB/2000-line tool-result cap.
  - PR 3: every `[TOOL]`/`[TOOL-ERROR]` trace-file line now carries a `[HH:MM:SSZ]`
    timestamp and `slug=` tag consistently (previously missing on the claude/copilot path).
    Raw JSON `args=` dumps are replaced with a one-line summary (`$ <command>` for a shell
    call, a bare path for read/write/edit), falling back to a capped JSON preview only for
    an unrecognized tool shape. Any remaining truncation now cuts on a safe boundary and
    appends `…(+N chars)` instead of a bare mid-string cut.
  - PR 4: all four `skills/crew-afk/*.SKILL.md` now describe the live stream — step markers
    plus heartbeats — as the primary signal, demoting
    `.scratch/<feature-slug>/traces/orchestrator.log` to "check it only if you want more
    than the stream showed."
  - No dispatch-mechanism change, no new dependency, no change to `report.mjs` parsing,
    receipts, or gate order.

registry.json: crew-afk 2.2.25 -> 2.2.26.

## [1.29.33]

### Added

- **crew-afk sprints now print a `[STEP]` marker to the live stream before every gate**
  (`worktree`, `deps`, `dispatch-coder`, `verify`, `dispatch-review`, `dispatch-triage`,
  `merge`, `close`), tagged `slug=<slug> round=<n>` — Tier 0 of the sprint-visibility plan
  (`.scratch/crew-afk-visibility/plan.md`, PR 1). Until now the three slow dispatches (coder
  up to 45m, review/triage up to 20m each) were totally silent in the live stream a user is
  actually watching; only the trace file saw anything. The existing gate-outcome lines
  (`DEPS:`, the verify/merge/close scripts' own stdout, the findings-promotion guard/defer
  lines) are now tagged `slug=`/`round=` too, so concurrent issues' output stays
  attributable when interleaved. No dispatch-mechanism change, no new dependency, no change
  to `report.mjs` parsing, receipts, or gate order — see the plan file for the full
  investigation and the tiers not shipped yet (throttled dispatch heartbeats, trace-file
  formatting, skill wording, per-dispatch cost/usage).

registry.json: crew-afk 2.2.24 -> 2.2.25.

## [1.29.32]

### Added

- **`gen-override.sh` now also symlinks `docker-compose.override.yml` into `PROJECT_ROOT`
  when it differs from `MAIN_ROOT`.** Every mechanical caller (`docker-install.sh`,
  `verify-worktree.sh`) and `docker-install.md`'s own instructions already pass the file's
  absolute `MAIN_ROOT` path via an explicit second `-f` on every `docker compose` command —
  that stays the correct, cwd-independent way to invoke it and is unchanged. The symlink is a
  safety net for the one case that contract can't cover: a worker's ad hoc `docker compose
  run` typed with no `-f` at all used to silently drop the override (proxy vars, platform
  pin, named volumes) instead of failing loudly, since compose's own same-directory
  `docker-compose.override.yml` discovery convention only fires when the file is actually
  present next to `docker-compose.yml` in the worktree. Mirrors `ensure-env.sh`'s existing
  `.env` link, including its dangling-symlink handling (a stale link left over from a
  worktree reused against a different `MAIN_ROOT` is cleared and relinked, not left broken)
  and its "leave a live entry alone" rule (a project's own committed override file at
  `PROJECT_ROOT` is never overwritten). `-ef` skips the one `MAIN_ROOT`-only call (before any
  worktree exists) so it never links the file to itself.

registry.json: dep-install 1.3.6 -> 1.3.7.

## [1.29.31]

### Fixed

- **A running crew-afk sprint could dispatch, merge, and close a `ready-for-agent` issue that
  actually belonged to a *different* feature's `.scratch/<other-feature>/issues/open/` dir onto
  its own feature branch.** `selectDispatchable()`/`listOpenIssueFiles()` scanned every feature
  dir under `.scratch/` unconditionally; a live sprint's dispatch loop (`loop.mjs`) now passes
  its own `sprint.featureSlug` so the scan is confined to that one feature. The same
  cross-feature ambiguity existed one step earlier: a bare `crew-afk run` (or `plan`) with no
  `--feature-slug` relied on `session-init.sh`'s own `find | head -n 1` fallback to silently pick
  one of several feature dirs with a ready issue. `orchestrator/main.mjs` now resolves the
  feature slug itself before `session-init.sh` (or anything else) touches disk, and refuses with
  a `--feature-slug <slug>` menu instead of guessing whenever more than one feature dir has a
  ready issue; `plan` uses the same resolution so its preview always matches what a following
  `run` would do. `tracker.mjs` gains an optional `featureSlug` on both functions; `main.mjs`
  gains `resolveFeatureSlug`/`readyFeatureCandidates`.
- **`squash-commits.sh` could squash a completed issue's commit message using a *different*
  feature's `done/` file, and could pick the wrong feature's `sprint-state.json` outright when
  two features coincidentally recorded the same branch name.** The script re-derived
  `FEATURE_SLUG`/`STATE_FILE` unconditionally by matching the current branch against every
  `.scratch/*/sprint-state.json`, even though `loop.mjs`'s `wrapUp()` already hands it both,
  correctly resolved by `session-init.sh`, via `sprint.childEnv()` on every real sprint run. It
  now prefers an inherited, non-empty `FEATURE_SLUG`/`STATE_FILE` outright and only falls back to
  the branch-matching glob for a standalone invocation with neither set. The completed-issue
  lookup that builds the squash commit's title was similarly unscoped, globbing
  `.scratch/*/issues/done` for the completed slug; it now looks only under
  `.scratch/$FEATURE_SLUG/issues/done`.

registry.json: crew-afk 2.2.23 -> 2.2.24.

## [1.29.30]

### Fixed

- **`env` now gets the same script-side Makefile safety net `install` already had, closing a
  gap that let a discovered `env` (and, less often, `install`) come back `null` even after
  discover-commands.sh's prompt was twice strengthened (v1.29.11, v1.29.27) to require opening
  any Makefile before answering either as `null`.** That instruction is a strong nudge to the
  model, not a guarantee it is followed on every run — reported in the wild as an orchestrator
  log showing both fields `null` for a repo whose Makefile plainly had `deps`/`.env` targets,
  while pasting the identical prompt into an interactive session answered correctly. `install`
  already had a script-side backstop independent of the model: `host-install.sh` mechanically
  scans any Makefile for an `install`/`deps` target before falling back to lockfile
  conventions. `env` had no equivalent — `ensure-env.sh`'s only fallback was the mechanical
  `.env.example`-or-empty convention, so a repo whose real bootstrap lived only in a Makefile
  target (`env`, `.env`, `dotenv`, `setup-env`) got an empty or wrong `.env` with nothing left
  to catch it. `ensure-env.sh` gains `_makefile_env_command`, tried between the discovered
  override and the mechanical convention, mirroring `host-install.sh`'s own scan including its
  docker-recipe skip.

registry.json: dep-install 1.3.5 -> 1.3.6.

## [1.29.29]

### Changed

- **A crew-afk branch that fails verification is now triaged before it is redispatched, instead
  of always getting a full coder re-implementation.** A new independent agent, `crew-triage`
  (never the coder that wrote the branch — the same reason review isn't a self-grade), reads the
  captured failing check output and the branch's own diff and answers one question: is this
  fixable by more code on this branch, or an environment/infrastructure problem (registry,
  network, Docker, credentials, ...) that no recoding touches? A `fixable` verdict routes the next
  round to a new, narrow `fixPrompt` ("the code is otherwise acceptable, make the smallest change
  that fixes exactly this") instead of the generic "resume the whole issue" prompt. A
  `not fixable` verdict skips the coder *and* triage entirely for one cheap, coder-free deps +
  verify retry (catches a transient blip for free); if the identical failure recurs, the issue is
  marked blocked and tagged `environment` so `crew-summary.sh` lists it under a new
  `## Environment Blockers (need a human)` section, distinct from an ordinary code-review
  blocker. `orchestrator/lib/report.mjs` gains `parseTriageReport`; `orchestrator/lib/prompts.mjs`
  gains `triagePrompt`/`fixPrompt`; `orchestrator/lib/pipeline.mjs` gains `runTriage`/
  `handleVerificationFailure` and two new retention-reason tags
  (`verification-failed:fixable`/`verification-failed:not-fixable`). `crew-triage` is a new agent
  in `registry.json`, installed automatically as a `crew-afk` dependency on every platform.

### Changed

- **The discovered dev-loop commands cache moves from the gitignored, per-sprint-ephemeral
  `.scratch/commands.json` to a committed, human-editable `.coding-crew/dev-commands.json`.**
  Every fresh clone or new sprint used to re-pay the discovery model call, and nobody could
  correct a wrong answer without it being silently overwritten. `discover-commands.sh` now
  bootstraps once: it skips (no model call) whenever `.coding-crew/dev-commands.json` already
  exists, and only re-runs on an explicit `--refresh` (or `CREW_COMMANDS_REFRESH=1`) — there is
  no more staleness re-check against CLAUDE.md/AGENTS.md/Makefile content. `write-commands-cache.sh`
  drops the now-pointless `sourceHash` field; the written schema is exactly
  `test`/`lint`/`typecheck`/`install`/`env`. `ensure-env.sh`, `ensure-deps.sh`, and
  `verify-worktree.sh` all read the override from the new path, and `verify-worktree.sh`'s
  cache-usability check no longer looks for `sourceHash` (it now checks for a real field like
  `"test"`). `solve-issue`'s own cache fast path follows the same rename. Because the file is
  committed but nothing auto-commits it, `crew-summary.sh` and `solve-issue`'s final report step
  both print a one-line reminder when `.coding-crew/dev-commands.json` has uncommitted changes at
  `MAIN_ROOT`; `crew-summary.sh`'s existing `--no-reminder` flag now suppresses this reminder too.

## [1.29.27]

### Fixed

- **Command discovery now treats `install` and `env` symmetrically: both require Makefile
  inspection before concluding `null`.** Previously, only `install` had a mandatory Makefile
  check documented in the prompt; `env` could be answered `null` based on doc silence alone.
  Both categories are equally likely to live as Makefile targets (`make install`,
  `make env`) rather than in prose, so both now require the same rule: you MUST open any
  Makefile in the list before answering `null` for either category. This overrides the "stop
  once confident" instruction to prevent the model from skipping the Makefile check just
  because the docs already answered test/lint/typecheck.

## [1.29.26]

### Added

- **Command discovery now also finds a documented `.env`-bootstrap command, and `ensure-env.sh`
  uses it before falling back to its own mechanical `.env.example`-or-empty convention** — the
  same pattern `install` already follows for `ensure-deps.sh`. `discover-commands.sh` /
  `write-commands-cache.sh` now ask for and cache a fifth field, `env`, in
  `.scratch/commands.json`, sourced from the same CLAUDE.md/AGENTS.md/Makefile read
  `ensure-env.sh` deliberately never does itself. A missing cache, a cached `null`, or a
  discovered command that fails or never actually leaves a `.env` behind all fall through to
  the existing mechanical convention unchanged — `ensure-env.sh` still never blocks.

## [1.29.25]

### Fixed

- **A worktree's `.env` no longer diverges from a real one already at `MAIN_ROOT`.**
  `ensure-env.sh` only ever checked `PROJECT_ROOT/.env`, so a worktree with no
  `.worktreeinclude` entry for `.env` (or one created before `MAIN_ROOT/.env` existed) would
  mint its own, independent copy from `.env.example`/empty instead of the real one. It now
  accepts `--main-root`: when `MAIN_ROOT/.env` already exists, `PROJECT_ROOT/.env` is linked
  to it instead of regenerated; when neither exists, generation happens exactly once, at
  `MAIN_ROOT`, before linking every worktree to it. `host-install.sh` and `docker-install.sh`
  now forward `--main-root` through to it, and `ensure-deps.sh` forwards its own
  `MAIN_ROOT_EFFECTIVE` to `host-install.sh`.
- **A `.env` this script creates or links can no longer be committed by a worker's own
  `git add -A`.** Without a project's own `.gitignore` entry for `.env`, a worktree's `.env`
  (now sometimes a symlink into `MAIN_ROOT`) got staged and merged like any other file — and
  a symlink merging into a real file at `MAIN_ROOT` fails with "untracked working tree files
  would be overwritten by merge". `ensure-env.sh` now adds `.env` to the shared
  `.git/info/exclude` (never the project's own tracked `.gitignore`) whenever it creates or
  links one.

## [1.29.24]

### Fixed

- **crew-afk no longer forwards an unrecognised CLI argument two hops down into a
  `--jira`-only script.** A bare word that was neither a known flag nor a `.scratch/`
  path (e.g. a typo'd feature slug, or free-form prose) used to be silently pushed into
  `passthrough` and die inside `feature-branch-setup.sh` with a confusing "Unknown
  argument" — three layers from where the mistake was made. `orchestrator/main.mjs` now
  rejects it immediately, lists the accepted forms, and suggests the closest existing
  `.scratch/<feature-slug>` directory by edit distance when one is close enough to be a
  likely typo.
- **All four `crew-afk` platform skills (`claude.SKILL.md`, `codex.SKILL.md`,
  `copilot.SKILL.md`, `pi.SKILL.md`) now resolve a sprint target before running anything**
  when the user's arguments aren't already recognisable CLI syntax. Instead of forwarding
  free-form phrasing straight into the orchestrator and predicting the failure it was
  about to cause, the skill looks up real `.scratch/*` feature directories, resolves the
  user's words against them, and only proceeds on an unambiguous match — asking instead of
  guessing when zero or multiple candidates fit.

## [1.29.23]

### Changed

- Updated crew-code-reviewer references and protocol
- Updated registry version information
- Enhanced crew-afk summary script
- Improved test coverage for crew-code-reviewer and worker chain token budget

## [1.29.22]

### Fixed

- **crew-afk no longer silently reuses a stale worktree branch on a fresh issue dispatch.**
  `ensureWorktree` decided reuse purely from whether a git ref named `crew/<feature>/<slug>`
  already existed, independent of whether the issue itself had any recorded progress. Branch
  refs are never deleted except by `cleanup-worktrees.sh`'s own ancestry-checked sweep, so a
  leftover branch from an earlier, abandoned attempt (a crashed run, a premature dispatch)
  could sit in the repo with a base that predates work the current sprint has since merged.
  Dispatching that issue again reused the stale branch as-is — no rebase, no warning — and the
  mismatch only surfaced ~45 minutes later as an unexplained `merge-failed` conflict at the very
  end of the pipeline, indistinguishable from a genuine same-round sibling conflict. `runWorker`
  now tells `ensureWorktree` whether this dispatch actually expects a resume (the issue has a
  `## Progress` section); when it doesn't and the existing branch's base is not an ancestor of
  it, the issue is reported `blocked` immediately, with a reason naming the stale branch, instead
  of paying for a worker + review cycle that was always going to conflict at merge.

## [1.29.21]

### Changed

- **crew-afk's dispatch skill now tells the user where to look during a long sprint.** All four
  platform variants (`claude.SKILL.md`, `codex.SKILL.md`, `copilot.SKILL.md`, `pi.SKILL.md`) gained
  a step pointing at `.scratch/<feature-slug>/traces/orchestrator.log`, which the orchestrator
  already writes live — previously undiscoverable unless you knew to look for it, so a quiet
  stdout stream during a long-running dispatch looked indistinguishable from a stuck one.

## [1.29.20]

### Added

- **`to-issues` now surfaces shared surfaces during the quiz step, instead of leaving overlap
  entirely to chance.** While exploring the codebase, note any schema/type/function more than
  one drafted slice would need to modify — a narrower thing than "touches the same file", which
  is the normal (and safe) shape of vertical slicing. Each shared surface found is listed
  explicitly in the quiz, asking the user to sequence it, merge the slices, or leave it parallel.
  This is a deliberate judgment call at breakdown time, not an automatic file-overlap dependency
  rule — a blanket rule would serialize additive, non-conflicting work and defeat crew-afk's
  parallel dispatch for a problem (real content conflicts) that vertical slicing is supposed to
  make rare in the first place.
- **crew-summary now tells a human how to resolve a merge conflict, not just that one exists.**
  A `merge-failed` retention (verify passed, review returned all-met, only `git merge --no-ff`
  itself conflicted) is the one retained-branch reason crew-afk cannot retry its way out of —
  `merge-branches.sh` aborts cleanly and never attempts resolution, by design. The end-of-sprint
  summary previously only listed the branch under "## Retained Branches" with no next step. It
  now adds a "## Merge Conflicts (need a human)" section with the three manual steps (merge by
  hand, resolve, re-run crew-afk) so the stalled sprint's fix is discoverable without reading
  `merge-branches.sh`'s source.

## [1.29.19]

### Fixed

- **dispatch-agent.sh prompt read race in review pass.** Fixed issue where prompt file could disappear between existence check and read, causing silent dispatch failures.

## [1.29.17]

### Fixed

- **crew-afk's review pass could silently run on nothing, and the gap it left behind never
  cleared.** `dispatch-agent.sh` checked `[[ -f "$PROMPT_FILE" ]]` at the top and only read
  the file's contents at the very bottom, `pi ... "$(cat "$PROMPT_FILE")"`, after resolving
  the agent definition, validating its tool allowlist, and creating log/event directories —
  a real gap between "the file exists" and "the file is actually read". On a real sprint the
  prompt file was gone by the time that `cat` ran: `cat` failed, the command substitution
  silently produced an empty string, and `pi` was dispatched with essentially no prompt,
  exiting 0 having done nothing. `parseReviewReport` read that as an empty review report and
  `promote-findings.sh mark-not-run` correctly recorded the branch as unreviewed and retained
  it for another round — but the retry's own successful review landed in a *different*,
  later-timestamped report file, and nothing ever retracted the stale `not_run` stub in the
  first file. The end-of-sprint summary's `## Unreviewed Branches` section read that stub
  forever after, flagging a branch as never reviewed even though a complete, all-met review
  for it existed on disk. Fixed on both ends: `dispatch-agent.sh` now reads the prompt into a
  variable immediately next to the existence check, and a failed or empty read is a hard
  dispatch failure instead of a silently degraded one; `promote-findings.sh remind` now
  clears a branch's `not_run` gap once a later report shows a genuine `AC:` verdict for that
  same branch, so a retried review that actually ran is not reported as one that never did.

## [1.29.16]

### Added

- **crew-afk's worker/reviewer dispatch is visible while it runs, on all four platforms.**
  Every dispatch used to be a black box: pi's `-p` and codex's `codex exec` print nothing
  until the whole turn is done, and claude/copilot's plain `-p` text output was only ever
  buffered into `--out` at the end — so a sprint's trace log went from `[DISPATCH]` straight
  to `[DISPATCH-END]` with nothing in between, however many tool calls or however long a
  worker actually ran. All four now go through that platform's own event-stream mode
  instead — pi's `--mode json`, codex's `--json`, claude's `--output-format stream-json
  --verbose`, copilot's `--output-format json` — and a recognised tool call becomes a
  `[TOOL]`/`[TOOL-ERROR]` line in the sprint's trace log *as it happens*, so `tail -f` on
  that log shows what a worker is doing while it is doing it. pi/codex trace this from bash
  (`dispatch-agent.sh`/`dispatch-codex-agent.sh`'s own `trace_event`, both verified against a
  real run of the actual CLI); claude/copilot trace it from `dispatch.mjs`
  (`formatJsonTraceLine`), since neither has a bash dispatcher to do it from. The full raw
  event stream is kept next to each report as `<out>.events.jsonl` for anyone who needs more
  than the one-line trace; only the final assistant text — the one thing `report.mjs` and
  `parseReviewReport` actually parse — goes into the report file itself
  (`extractFinalText`/each dispatcher's own extraction), so the pipeline's report-parsing
  contract is unchanged. codex needed no such extraction: `--output-last-message` already
  writes the final message regardless of `--json`.

## [1.29.15]

### Added

- **`verify-worktree.sh` caps a check command's own output instead of streaming it
  through unbounded.** TEST/LINT/TYPECHECK commands (`make testUnit`, a full `npm test`
  run, …) can print far more than anyone reading a sprint's trace log wants, and every
  caller paid for that in full: a human's own terminal, and the orchestrator
  (`ctx.log(verify.stdout.trim())` in `pipeline.mjs`, which also feeds `console.error`
  and the trace log). Output over `CREW_VERIFY_OUTPUT_LINES` (default 200) lines from a
  *failing* check is now capped to its tail; from a *passing* one it is dropped
  entirely — a check that passed is not why anyone rereads a sprint's log, however
  verbose its own suite is, and showing it anyway would mean the trace log keeps
  growing with every issue's test-suite size even when nothing ever fails. Either way
  the full output is persisted to `.scratch/verify-<category>.log` in the worktree and
  that path is named in the output — the same tail-plus-persisted-log convention
  `ensure-deps.sh` already uses for a failed install's output. Applies to the host path
  and both docker-mode paths (`docker compose run`, and the docker-in-docker host
  fallback).

## [1.29.14]

### Added

- **`ensure-deps.sh` persists a failed install command's full output to disk instead of
  discarding it.** A `docker-failed`/`failed <cmd> (exit N)` outcome only ever carried its
  package manager's own tail on stderr, which the orchestrator (`Sprint.installDeps` /
  `runWorker` in `orchestrator/lib`) never captures — only the one `DEPS:` line does, so the
  actual error was unrecoverable once the round's log was all that was left to read. Every
  failure branch (docker install, a discovered install override, host-install.sh) now also
  copies its full output to a file — beside the `--slug` marker when one exists
  (`<marker>.deps.log`), the shared `.scratch/docker-install.log` for the one docker
  main-root install, or `<dir>/.scratch/deps-install.log` otherwise — and names that path in
  the `DEPS:` line itself, so it survives into whatever log already captures that line.

## [1.29.13]

### Added

- **`scripts/cut-release.sh` mechanizes this repo's own release step.** `commit, tag, push,
  release` had no tooling behind it: doing it meant re-deriving the next semver number from git
  tags, eyeballing `registry.json` for entries needing a version bump (exactly what
  `tests/registry-version-bump.bats` already checks), hand-crafting the tag, and remembering to
  push both branch and tag. The script reads the version to release from `CHANGELOG.md`'s own top
  heading (one source of truth, not two that can disagree), verifies it is greater than the
  nearest previous release tag, runs the existing registry-version-bump check, then tags HEAD and
  pushes branch + tag. `--dry-run` runs every check without tagging or pushing. Maintainer-only:
  not referenced by `registry.json`, ships to no consumer.

### Removed

- **Four stale maintainer-only docs (`docs/CHANGELOG-archive.md`, `docs/crew-afk-scripts.md`,
  `docs/crew-afk-orchestrator.md`, `docs/crew-afk-as-code-plan.md`) are gone.** They were design
  history nobody needed to re-read; every remaining reference to them (`CHANGELOG.md`,
  `CLAUDE.md`, `scripts/skill-utils/git-workflow/README.md`, and three bats tests in
  `tests/install.bats`, `tests/prompt-integrity.bats`, and `tests/crew-afk-ensure-deps.bats` that
  asserted their content) was updated or removed alongside them, so nothing points at a file that
  no longer exists.

## [1.29.12]

### Changed

- **`install.sh` memoizes registry.json reads per skill instead of re-invoking `jq` once per
  platform.** `install_single_skill` recurses once per platform when `PLATFORM=all` (four calls
  for one skill), and most of what it reads per skill — `source-dir`, `version`, `scripts`,
  `deps`, `agent-deps`, `assets.source`/`dest`, the claude `install` path — does not vary by
  platform at all, so a full default install spawned ~2,400 `jq` processes reading the same
  values four times over. New `_skill_scalar`/`_skill_list` cache each lookup by skill (plus
  platform, for the fields that are genuinely platform-scoped: an `install-<platform>` override,
  `body[<platform>]`, `platform-files[<platform>]`), so a value already read for a skill this run
  is a bash lookup, not a spawn. Git Bash has no real `fork()`, so this is disproportionately
  cheap there.
- **`tests/helpers/render.bash`'s render cache is now keyed by a content hash of every input that
  can change a rendered result** (`agents/`, `skills/`, `scripts/`, `registry.json`,
  `install.sh`), stored under a fixed path outside any single bats run's own tmpdir — not by that
  run's own tmpdir, as before. The old cache paid `install.sh`'s `jq`-heavy cost again on every
  separate `bats` invocation, which is most of a local edit/run/edit loop, even when nothing
  rendered had actually changed. A hash hit now costs nothing; a hash miss (something changed)
  still pays the real cost once. CI is unaffected — every job starts from a fresh clone, so it is
  a hash miss exactly as often as before.

### Fixed

- **`solve-issue`, `crew-code-reviewer`, and `dep-install`'s host-install path named only
  `CLAUDE.md`, and read it unconditionally even when a caller already had it in context.** A
  project documenting its conventions or install command in `AGENTS.md` instead (Codex and other
  AGENTS.md-only harnesses) was silently missed, even though `verify-worktree.sh`'s own command
  discovery already treats `CLAUDE.md` and `AGENTS.md` as equivalent, falling back to the latter.
  Separately, every caller — including one whose platform already auto-loads `CLAUDE.md` at
  session start — re-read a file already in front of it. All three now check `CLAUDE.md` or
  `AGENTS.md`, and skip the reread when the content is already part of the caller's context.

registry.json: solve-issue 1.9.3 -> 1.9.4, dep-install 1.3.1 -> 1.3.2, crew-code-reviewer 1.7.0 ->
1.7.1.

## [1.29.11]

### Fixed

- **`discover-commands.sh`'s prompt let the model call `install` a confident `null` purely
  from CLAUDE.md/AGENTS.md silence, before ever reading a Makefile that could have answered
  it.** `install` is the category prose docs are least likely to mention — it is far more
  often only an explicit target in a Makefile, which sits later in the prompt's priority
  order — but the "stop reading once you have a confident answer for all four categories,
  including a confident no-command" instruction let the model settle on `install: null` as
  soon as `test`/`lint`/`typecheck` were answered from docs, without ever opening the
  Makefile. `ensure-deps.sh`'s own fallback independently re-checks the Makefile for targets
  literally named `install`/`deps`, so a standard target was caught twice regardless; a
  target named anything else (`bootstrap`, `setup`, …) was not, and `install` silently ended
  up `null` with nothing left to catch it. The prompt now carves out an explicit exception:
  before answering `install` as `null`, open any Makefile in the candidate list and check it
  for an install-shaped target, even if the other three categories already have confident
  answers from docs.
- **The host install path had no `.env` handling at all, while the docker path already did.**
  `dep-install`'s `ensure-env.sh` (mechanical `cp .env.example .env`, or an empty touch, no
  content ever read) was wired only into `docker-install.sh`'s own steps 0b/0c —
  `host-install.sh`, the path every non-docker repo takes, never called it, so a host-mode
  project needing a `.env` before its tests/lint/typecheck could run got nothing from either
  script. `host-install.sh` now calls `ensure-env.sh` itself, unconditionally and
  best-effort, before attempting a Makefile target or a lockfile-based install — including
  when no install method is found at all, since the checks that run after this script don't
  care whether an install ran.

## [1.29.10]

### Fixed

- **A `claude -p` dispatch launched from inside a Claude Code session (command discovery,
  coverage validation, or a worker itself) inherited that parent session's own
  `CLAUDE_CODE_SESSION_ID`/`CLAUDE_CODE_CHILD_SESSION` env vars and attached to its hook
  chain instead of starting a session of its own.** A global `UserPromptSubmit` hook firing
  on the child's prompt could rewrite or swallow it before the agent ever saw it — command
  discovery's own probe hit exactly this, coming back with claude's default "your message
  came through empty" greeting instead of an answer, so the sprint fell back to per-check
  discovery with no error anyone could see. `buildDispatch` (every worker/reviewer dispatch)
  and `dispatchPlain` (command discovery, coverage validation) now explicitly set both vars
  to `""` in the child's environment for the claude platform, severing the inherited session
  identity so the child always starts its own.

## [1.29.9]

### Fixed

- **`dispatchPlain()`'s claude case could leak a "learned" note across every worktree and
  future interactive session.** Every `dispatchPlain` call — command discovery, coverage
  validation — is a one-shot, stateless reasoning pass that re-derives its answer from a
  source hash or the current diff, so nothing benefits from persisting across runs; worse,
  claude's auto-memory project directory is shared across every worktree in the repo, and
  this dispatch gets full write-tool access before any worktree exists. `dispatchPlain` now
  sets `CLAUDE_CODE_DISABLE_AUTO_MEMORY=1` for the claude platform only — pi, codex, and
  copilot are unaffected. `Effects.spawnWithTimeout()` also records each call's `env` (dry-run
  and live), the seam the new tests in `tests/orchestrator/dispatch.test.mjs` use to assert the
  flag is present for claude and absent for every other platform.

## [1.29.8]

### Fixed

- **`discover-commands.sh` and `write-commands-cache.sh` resolved `MAIN_ROOT` via
  `git rev-parse --show-toplevel`, which returns the *current* worktree's own root, not the
  shared main checkout, when run from inside one.** `discover-commands.sh` is only ever
  invoked by `commands.mjs` with `cwd=mainRoot` before any worktree exists, so this never
  surfaced there, but `write-commands-cache.sh` is also solve-issue's own script (shared via
  `registry.json`'s `scripts` field): its Step 5 DISCOVER fallback — taken whenever the
  sprint-level cache is missing or stale, e.g. `--no-commands`, a dispatch timeout, or an
  unparseable model response — runs from inside the dispatched worker's worktree. A fallback
  write from there landed in that worktree's own throwaway `.scratch/commands.json`, invisible
  to every later reader (`verify-worktree.sh`, another issue's `solve-issue`, a later
  `discover-commands.sh` run) and gone once the worktree was removed — so the one discovery a
  sprint is supposed to do once got silently repeated by every worker that hit the fallback,
  with no cache ever shared. Both scripts now resolve `MAIN_ROOT` the same way
  `verify-worktree.sh` already does: the inherited `$MAIN_ROOT` env var first (what
  `dispatch.mjs`/`dispatch-agent.sh` already export into every worker), then a new
  `_main_root_of` helper (mirroring `verify-worktree.sh`'s own, via `git rev-parse
  --git-common-dir`) that finds the main worktree's root from any linked worktree with no env
  var at all, and only then the old `--show-toplevel` guess. New tests in
  `tests/crew-afk-write-commands-cache.bats` and `tests/crew-afk-discover-commands.bats` cover
  resolution from inside a real linked worktree, with and without `$MAIN_ROOT` set.

## [1.29.7]

### Added

- **Command discovery now also finds an `install` command, and `ensure-deps.sh` uses it before
  falling back to its own mechanical guess.** `discover-commands.sh` / `write-commands-cache.sh`
  answer a fourth field alongside `test`/`lint`/`typecheck`: `install`, reported only when
  CLAUDE.md/AGENTS.md/Makefile explicitly documents one (never guessed, same rule as the other
  three). `ensure-deps.sh` deliberately never reads those files itself — see its own header
  comment — so this is the one place a documented override reaches it. Consuming it required an
  ordering change: `Sprint.init` no longer calls `ensure-deps.sh` itself; `main.mjs` now runs
  one-time command discovery first and only then calls the new `sprint.installDeps()`, so a
  discovered override is already on disk at `.scratch/commands.json` by the time the sprint-level
  `ensure-deps.sh --dir $MAIN_ROOT` call reads it — commands finding before deps installing, so
  the finding can be used rather than raced. `ensure-deps.sh`'s presence guard (step 3) also treats
  a non-null override as its own evidence of a dependency step, so a custom bootstrap script with
  no lockfile for the guard's manifest heuristic to find is no longer misreported `DEPS: none`. A
  discovered command that fails is reported `DEPS: failed <cmd> (exit N)`, never silently
  reinterpreted as `host-install.sh`'s own `none`/`failed` signals. New tests:
  `tests/crew-afk-discover-commands.bats`, `tests/crew-afk-write-commands-cache.bats`,
  `tests/crew-afk-ensure-deps.bats` (the override, its interaction with the presence guard, and
  the failure path), and `tests/orchestrator/sprint.test.mjs` (discovery-before-deps ordering, and
  an end-to-end run using a discovered override instead of `host-install.sh`).

## [1.29.6]

### Fixed

- **`dispatchPlain()`'s claude case placed the prompt right after `--add-dir mainRoot`, with
  no `--model` in between whenever a sprint ran without `--model` (the default).** `--add-dir`
  is variadic (`<directories...>`), so claude's own CLI parser consumed the prompt as a
  second directory instead of treating it as `-p`'s positional argument. claude then saw no
  prompt at all and exited 1 with "Input must be provided either through stdin or as a
  prompt argument", surfaced by `commands.mjs` as "Command discovery: model dispatch did not
  complete (exit 1)" — the same symptom as 1.29.4's `--tools ""` bug, with a different flag
  as the culprit. The prompt now sits immediately after `-p`, before `--permission-mode` and
  `--add-dir`, matching copilot's already-safe argv order, so no later flag's arity can ever
  swallow it again.

## [1.29.5]

### Changed

- **Command discovery's prompt no longer pastes the full content of CLAUDE.md/AGENTS.md/
  Makefile/manifest files into claude/pi/codex/copilot's `-p` argv.** It now lists the found
  files' *paths*, in the same priority order it always hashed them in (docs, then build
  files, then manifests), and tells the model to read them itself and stop once it has an
  answer for all three categories — `dispatchPlain()` already hands every caller the same
  read/bash/edit/write toolset an interactive session gets (see 1.29.4), so the model no
  longer needs the content pre-quoted for it. Saves tokens on repos with a large CLAUDE.md
  and files the model doesn't end up needing, and removes any dependence on how much file
  content a single CLI argument can hold.

## [1.29.4]

### Fixed

- **Command discovery's agent-less dispatch stripped tool access with a `noTools` option
  (pi: `--no-tools --no-context-files`, claude: `--tools ""`), added in 1.29.3 — and claude's
  `--tools` flag is variadic.** Without a `--model` override (the default, unless a sprint
  passes `--model`), `--tools ""` sat directly in front of the prompt on claude's argv, so
  claude's own arg parser swallowed the prompt into `--tools`'s value list instead of
  treating it as the `-p` positional argument. claude then saw no prompt at all and exited 1
  with "Input must be provided either through stdin or as a prompt argument", surfaced by
  `commands.mjs` as "Command discovery: model dispatch did not complete (exit 1)" and
  silently falling back to per-check discovery on every claude sprint. `noTools` is reverted
  outright: `dispatchPlain()` now always hands the model the same read/bash/edit/write
  toolset an interactive session would, exactly as it did before 1.29.3, and exactly as
  coverage validation's own `dispatchPlain()` call already relied on.

## [1.29.3]

### Fixed

- **`discoverCommands()` tested `/skipped/i` against discover-commands.sh's entire stdout —
  the whole prompt, including every candidate file quoted in full — instead of just its own
  one-line skip message.** A real `CLAUDE.md`/`AGENTS.md` containing the word "skipped"
  anywhere in its prose (e.g. "...because I skipped this; don't repeat the mistake.", a
  perfectly ordinary sentence in a repo's own docs) made that regex match, so the whole step
  silently returned before ever calling the model: no dispatch, no
  `.scratch/commands-response.md`, no `.scratch/commands.json`, and — because the
  short-circuit fires before any of the branches that log — no line in the trace log to
  explain why, reproduced end-to-end against a real repo hitting exactly this. The same shape
  existed in coverage validation's own skip check in `loop.mjs`, reachable through a feature
  slug containing "skipped" (coverage-validation.sh's stdout embeds `$FEATURE_SLUG` on every
  line). Both now test only the first line of the script's stdout, which is the only line
  either script's skip paths ever print.
- **`dispatchPlain()`'s command-discovery call handed the model a live read/bash/edit/write
  toolset with no restriction**, even though its prompt already quotes every candidate file in
  full and needs zero tool calls to answer. `dispatchPlain()` now takes a `noTools` option;
  command discovery passes `true` (pi: `--no-tools --no-context-files`, claude: `--tools ""`).
  Coverage validation's own `dispatchPlain()` call, which does need to grep merged code, is
  unaffected — `noTools` defaults to `false`.
- **`commands.mjs` never checked `discover-commands.sh`'s own exit code**, only the model
  dispatch's — a crash mid-script (an unreadable candidate file, for example) fell through into
  dispatching whatever partial stdout survived as if it were a real prompt, silently. It now
  logs and bails on a non-zero exit instead.
- **A `CLAUDE.md` symlinked to `AGENTS.md` (or any two candidate files with identical content)
  was quoted twice in the discovery prompt**, doubling that portion of the prompt's token cost
  for no new information. `discover-commands.sh` and `write-commands-cache.sh` now dedupe
  candidate files by content hash before building the prompt/source hash, in the same fixed
  order as before.

## [1.29.2]

### Fixed

- **Command discovery's own progress/failure lines ("Command discovery: ...") were only ever
  printed live to stderr, never persisted anywhere** — unlike every other pre-loop and
  per-round step, whose lines also land in the sprint's `.scratch/<slug>/traces/orchestrator.log`
  via `ctx.log`. Since this step runs once, unattended, before any worktree exists, a bad model
  response, a dispatch timeout, or a `write-commands-cache.sh` parse failure left no artifact at
  all once the live terminal output was gone — exactly the situation reported after a fresh
  v1.29.0 install produced no `.scratch/commands.json` with no way to tell why after the fact.
  `orchestrator/main.mjs` now appends the same lines to `sprint.traceLog`, so a failed discovery
  is diagnosable from the trace log alone on the next run.
- **`tests/registry-version-bump.bats` only diffed `registry.json`'s own fields, not the actual
  files an entry ships.** It would have caught v1.29.1's `scripts[]` additions, but not this
  release's own `orchestrator/main.mjs` edit — crew-afk's version had to bump *again* (2.2.0 →
  2.2.1) to cover it. The test now also diffs each entry's `source-dir` tree, `assets.source`
  tree, and resolved `scripts[]`/`platform-files[]` paths against the nearest released tag.

## [1.29.1]

### Fixed

- **v1.29.0's new `discover-commands.sh`/`write-commands-cache.sh` scripts never reached an
  already-installed repo via `install.sh --update` (crew.lock or legacy-manifest path), because
  neither `crew-afk` nor `solve-issue` had its `registry.json` version bumped alongside the new
  `scripts[]` entries.** Both update paths gate reinstallation purely on that version string
  changing (`run_update_from_lockfile`/`run_update` in `install.sh`), so an unchanged version
  reads as "nothing to do" and silently keeps the old file set forever — no error, no log line,
  just a repo that runs `crew-afk` and never gets `.scratch/commands.json`. `crew-afk` bumps
  2.1.0 → 2.2.0 and `solve-issue` bumps 1.8.1 → 1.9.0 so `--update` actually ships them. A new
  `tests/registry-version-bump.bats` diffs `registry.json` against the nearest released tag and
  fails when an entry's own fields changed without its version also changing, so this class of
  bug can't ship silently again.

## [1.29.0]

### Added

- **Command discovery (test/lint/typecheck) is now a one-time, cached model call instead of a
  regex re-derived per worktree.** `orchestrator/lib/commands.mjs` adds a fifth model-dispatch
  point — alongside the coder, reviewer and opt-in coverage validation — that runs once per
  sprint, before any worktree exists: `discover-commands.sh` decides whether a call is needed
  (skipping, at zero tokens, when none of CLAUDE.md/AGENTS.md/Makefile/manifest files exist, or
  when an existing `.scratch/commands.json`'s `sourceHash` already matches their current
  content), an agent-less `dispatchPlain()` reads whichever of those files a repo actually has
  and answers with the three commands, and `write-commands-cache.sh` persists the answer —
  recomputing the hash itself rather than trusting the caller. `verify-worktree.sh` now reads
  that cache first for each category (trusting an explicit `null` as "no local command", not
  re-guessing it), falling back to its pre-existing CLAUDE.md/Makefile/ecosystem-convention
  chain only when the cache is absent or unrecognised. `solve-issue`'s Step 5 gets the same
  cache-first fast path, and writes the cache itself after a manual discovery when there was
  none. A model reading real-world prose/tables/bullet lists replaces the fragile per-check
  regex that broke on documentation a regex has no reliable way to parse (e.g. a table cell
  noting "don't use this shortcut, it's broken"). New `crew-afk` flag: `--no-commands`.

## [1.28.8]

### Fixed

- **`gen-override.sh`'s generated override never set compose's top-level `name:` key**, so every
  `docker compose` invocation that lists it last in `-f` (per `docker-install.md`,
  `verify-worktree.sh`, `docker-install.sh`) fell back to resolving the project name from the
  basename of the *first* `-f` file's directory — the worktree's own compose file — instead of
  the main checkout. That siloed the intended-to-be-shared named volumes per worktree (e.g.
  `component-with-mock_wt_myproj_nm_root` instead of one shared `wt_myproj_nm_root`), even though
  the volume name prefix itself was already keyed off `MAIN_ROOT`. The override now emits
  `name: <project-name>` derived from `MAIN_ROOT`, sanitized to compose's stricter project-name
  rules (lowercase, must start with a letter or digit). A new `--query project-name` field
  exposes the same derivation for callers that need to detect it without re-parsing.

## [1.28.7]

### Fixed

- **`verify-worktree.sh`'s docker-mode log line echoed the pre-substitution, host-path command
  while actually running the container-cwd, path-substituted one** — reading as if a host path had
  leaked into the container, when only the log line was wrong.
- **A dangling `.worktreeinclude` symlink was never healed.** `existsSync` follows symlinks, so it
  reports `false` for a dangling symlink — the same value it reports for "nothing here yet". That
  made `applyWorktreeInclude`'s `symlinkSync` hit `EEXIST` on a stale link (a worktree reused after
  `.worktreeinclude` changed, or a link pointing somewhere other than the current source) and
  swallow it as "a pre-existing entry is not a failure", so it never healed — workers then failed on
  their own `cp .env.template .env` with "not writing through dangling symlink". `lstatSync` (no
  follow) now distinguishes nothing-at-dest (link it), a live entry (leave it, resume matters), and
  a broken symlink (clear it and relink to the current source). `dep-install`'s `ensure-env.sh` had
  the same failure mode one layer down (`-f` also reports `false` for a dangling symlink) and gets
  the same fix.
- **`verify-worktree.sh`'s discovered commands carried embedded host paths (`-C`,
  `--manifest-path`, `--prefix`/`-p`), which only made sense on the host.** All three
  `_discover_*_command` functions now return a bare command (`make test`, `bats .`, `cargo test`,
  `npm test`, `npx tsc --noEmit`), relying solely on the existing `cd "$WORKTREE_DIR" && ...`
  (host) / `cd "$DOCKER_CONTAINER_SRC" && ...` (docker) wrappers — matching `host-install.sh`'s
  cd-then-bare-command convention already used everywhere else in this repo. As part of the same
  fix, a bare `make <target>` discovered in docker mode is now dry-run first (`make -n <target>`)
  and checked for a `docker compose`/`run`/`exec` call, directly or via a variable `make -n` fully
  expands; a recipe that already manages its own docker call now runs on the host, unwrapped,
  instead of being nested inside an outer `docker compose run` — avoiding docker-in-docker.
  `docker-install.md`'s agent-facing `make install`/`deps` shortcut prose gets the same dry-run
  guard.

## [1.28.6]

### Added

- **`gen-override.sh` now pins the docker-mode override's `platform:` key to the host architecture
  by default**, so a project's own compose file or image pinning `platform: linux/amd64` no longer
  surfaces as "requested image's platform ... does not match the detected host platform" on an
  arm64 host — or the qemu-emulation flakiness behind that warning, which was reaching
  `verify-worktree.sh` as a real `TEST: fail` rather than a cosmetic line. The override's `-f`
  always comes after the project's own compose file in every `docker compose` invocation
  (`docker-install.sh`, `verify-worktree.sh`'s docker-mode checks), so its `platform:` key wins the
  compose merge without editing the project's file. `CREW_DOCKER_PLATFORM` controls it: `host`
  (default, matches `uname -m`), `amd64`/`arm64`/`linux/...` to force a platform regardless of
  host, or `off` to emit no key at all and leave the project's own pin in charge — for images that
  are genuinely single-arch and a host that already has emulation deliberately set up for them. New
  `--query platform` field on `gen-override.sh` for introspection. 8 new tests in
  `tests/dep-install-docker-install.bats`.

## [1.28.5]

### Fixed

- **`verify-worktree.sh` ran every check on the host, even for a docker-mode project, so a
  worktree's `node_modules` never existed where the gate looked for it.** `dep-install`'s
  `gen-override.sh` mounts a *named volume* over the ecosystem's dependency directory at a
  container-side subpath, not a host bind-mount — that is by design, the same volume warmed
  once and shared by every worktree of a `MAIN_ROOT` (see 1.28.1's eager `ensure-deps.sh`).
  Content installed there lives only inside that volume, never on the host filesystem, in
  the worktree or in `MAIN_ROOT` either. `docker-install.md` already tells a worker "every
  subsequent docker compose command must pass both `-f` flags — including test, lint and
  type-check runs", but a worker's own compliance never reached the one consumer that is
  not a model: `verify-worktree.sh` is a gate and cannot read a skill, so it kept running
  `make test` / `npm test` directly on the host, failing every check that touched the
  dependency directory regardless of whether the docker-mode install had succeeded.

  `verify-worktree.sh` now detects docker mode the same way `ensure-deps.sh` leaves it to
  find — `git config --local agent.install-mode docker`, plus the worktree's own compose
  file and `$MAIN_ROOT/docker-compose.override.yml` already having been written — and, only
  when every signal resolves, routes each discovered check through
  `docker compose -f <worktree>/docker-compose.yml -f $MAIN_ROOT/docker-compose.override.yml
  run --rm <service> sh -c "cd <container-src> && <check>"`, reusing `gen-override.sh
  --query services/container-src` (read-only) for the service and path the same way
  `docker-install.sh` already does. A command generated against the host worktree path
  (`make -C "$dir" test`, belt-and-braces per `_discover_test_command`) is rewritten with
  that path substituted for `.`, since the container's cwd is already the project's
  container-side source root and the host path does not exist inside it at all. Any missing
  signal — no `agent.install-mode`, no override file yet, no compose file, no resolvable
  `dep-install` scripts — falls back silently to the existing host path: **a gate must never
  stall a sprint because docker introspection failed.** `CREW_VERIFY_DOCKER=off` is the
  rollback lever, independent of `CREW_DEPS`, back to the always-host behaviour this gate
  had before. 8 new tests in `tests/verify-worktree-docker.bats`, `docker` stubbed
  throughout so these pin argument construction and the fallback safety net, not a real
  daemon.
- `_discover_test_command`'s Python branch matched "any `.py` file exists" at the worktree
  root or under `tests/`, so an unrelated build/deploy script (`deploy.py`, `fabfile.py`, …)
  made an otherwise-Python-free project attempt `pytest` and fail it, instead of honestly
  reporting `TEST: not_run`. Now matches only conventionally-named test files:
  `test_*.py` / `*_test.py` at the root or under `tests/`.

## [1.28.4]

### Fixed

- **`crew-coder`'s report file and final message were the same stringified JSON, which
  defeated the point of having two artifacts.** 1.28.2 fixed the two-*shapes* problem
  (markdown template plus a JSON echo, with the markdown thrown away unread) by making
  both channels pure JSON — but that traded it for a two-*copies* problem: `<slug>.report.md`
  (the dispatch's captured final message) and `<slug>.report.json` (the sidecar) ended up
  byte-for-byte identical, so the `.md` file carried no information the `.json` one didn't.
  The final message now leads with one line (`Status: complete|partial|blocked`) and a short
  human-readable summary before the same JSON block, verbatim, last — `report.mjs` still
  reads the sidecar first and falls back to the fenced block in the message if the sidecar
  write failed (the reliability property 1.28.2 added), but `<slug>.report.json` holds only
  the JSON object and `<slug>.report.md` is now an actual report a human can read. Also
  fixed four tests left asserting the pre-1.28.2 markdown headings (`### Acceptance
  Criteria`, `- [ ]` checkboxes, `## Issue: <slug>`) that no longer exist under either shape.

## [1.28.3]

### Fixed

- `ensure-deps.sh`'s presence guard ran before its docker-mode check, for every call
  including the one MAIN_ROOT call that generates `docker-compose.override.yml`. A repo
  that already had a host-side `node_modules` at `$MAIN_ROOT` (predating
  `.worktreeinclude` excluding it, or a contributor's own local install) reported `DEPS:
  present` and never reached `docker-install.sh` — the override was never written, no
  worktree ever saw `docker-present`, and every worker was left to run its own
  `dep-install` from scratch. The MAIN_ROOT call now runs `detect-mode.sh` ahead of the
  presence guard and skips the guard when it says `USE_DOCKER`; worktree calls are
  unaffected, since an inherited dep dir via `.worktreeinclude` there genuinely means
  there is nothing to do.

## [1.28.2]

### Fixed

- `crew-coder`'s report was two shapes: a markdown template (`## Issue:` / `### Notes`) plus a JSON
  block echoing the same fields. `report.mjs` parses the JSON alone and only falls back to scraping
  markdown when no JSON exists anywhere, so the markdown report was generated on every run and then
  thrown away unread. The protocol and example now specify one report shape — the JSON block,
  written to the sidecar file and repeated verbatim as the final message — with `notes` (was
  `### Notes`) as one of its fields.

## [1.28.1]

### Fixed

- `solve-issue` Step 2's docker-mode check only looked at `agent.install-mode` git config or an
  existing `docker-compose.override.yml`. `detect-mode.sh` also reads a Makefile `install`/`deps`
  target for a docker command — a worktree in docker mode by that heuristic alone silently read as
  host mode and never got its deps in either mode. Step 2 now runs the real script instead of
  duplicating a narrower guess of its own.

## [1.28.0]

### Added

- `ensure-deps.sh` now mechanizes docker-mode installs for the one MAIN_ROOT call a sprint makes
  before any worktree exists: it runs `dep-install`'s new `docker-install.sh` (the docker-mode
  sibling of `host-install.sh` — deterministic ecosystem/service/command selection, no judgement)
  under an `mkdir`-based lock, then writes `$MAIN_ROOT/.scratch/docker-install.done`. A worktree's
  own `ensure-deps.sh` call only checks that marker (`DEPS: docker-present`) and never installs
  itself — the named volume it would write into is shared by every worktree of this checkout by
  design, so the install must run once, not once per worktree. `CREW_DOCKER_INSTALL=off` rolls it
  back to the previous always-deferred `DEPS: docker` behaviour, independently of `CREW_DEPS`.
- `gen-override.sh --query <services|ecosystem|container-src|manifest-dirs>` — prints one detected
  fact and exits, so a caller that needs to *run* an install can reuse this script's own detection
  instead of re-parsing the compose file and manifests a second time.

### Fixed

- `gen-override.sh`'s `CONTAINER_SRC` detection ran under `set -euo pipefail` with no `|| true` on
  a pipeline that legitimately returns no match — the documented `/app` fallback for a compose file
  with no matching bind-mount line was dead code; the script exited early instead of reaching it.

---

Older entries (v1.0.0–v1.27.0) have been removed; see git history for that range if needed.
