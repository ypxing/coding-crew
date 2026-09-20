# Changelog

## [1.29.106]

### Fixed

- **`detect-mode.sh`'s git-containment check still forced `host` mode on Windows** even
  after v1.29.102's macOS symlink fix — the same root cause (a bare string comparison of two
  differently-rendered paths) but a different mismatch: `git rev-parse --show-toplevel`
  renders a Windows-absolute path as a bare drive letter (`C:/Users/...`), which a bash
  `pwd -P` comparison never matches. Removed the string comparison entirely — checking
  `-C "$PROJECT_ROOT" rev-parse`'s own exit status already answers "is this inside a git
  repo," since it resolves from inside `$PROJECT_ROOT` itself; there was never a need to
  compare rendered paths as strings in the first place.
- **`orchestrator/main.mjs` and `orchestrator/lib/dispatch.mjs` used `os.homedir()` instead
  of `$HOME`** to resolve every user-level path (agent definitions, crew-afk's own
  scripts dir). On Windows, `os.homedir()` reads `USERPROFILE`, not `HOME` — the documented,
  portable override (`TARGET_REPO=$HOME`) was silently ignored there, and a user-level
  install could never be found from a repo with no project-level copy of its own. Both now
  prefer `process.env.HOME` when set.

## [1.29.105]

### Fixed

- **A drive-letter Windows path from `git rev-parse --path-format=absolute --git-common-dir`
  was still getting the `$dir/` prefix wrongly prepended**, in `dispatch-codex-agent.sh`,
  `receipts.sh`, `verify-worktree.sh`, `detect-mode.sh`, and `ensure-env.sh` — the same five
  scripts the v1.29.100 `--path-format=absolute` fix touched, and the same underlying bug: git's
  own idea of "absolute" on Windows is `C:/Users/...`, which doesn't start with `/`, so the
  `case` guard each of these added to catch an already-absolute path never matched it and fell
  through to the relative-path branch anyway. Observed in `dispatch-codex-agent.sh` as a mangled
  `sandbox_workspace_write.writable_roots=["<worktree>/C:/Users/.../.git"]` — a codex worker's
  sandbox would have kept the real git dir read-only, the exact failure the v1.29.100 fix was
  meant to prevent. Each `case` now also matches `[A-Za-z]:*`.

## [1.29.104]

### Tests

- `dep-install-ensure-env.bats` had the same bug just fixed in `dep-install-docker-install.bats`:
  three tests set up a *dangling* symlink (target deliberately nonexistent) via a raw `ln -s`,
  which fails outright on Windows without symlink privilege — unlike a symlink to a target
  that already exists, which Windows/MSYS silently substitutes with a copy even without that
  privilege (confirmed from the CI logs: the sibling "symlinked AGENTS.md" tests elsewhere in
  the suite, which link to an existing file, already pass on Windows). Factored into a
  `make_dangling_symlink` helper that skips when the platform can't produce one.

## [1.29.103]

### Tests

- Several more bats tests hard-coded Unix/Linux-only assumptions surfaced by a Windows CI
  run: a raw `ln -s` in test setup (no fallback, unlike the scripts under test) that fails
  without symlink privilege; a `git rev-parse --git-common-dir` comparison missing the
  `--path-format=absolute` the script under test actually uses; two path-fragment assertions
  comparing against forward-slash literals against Node's native-separator output; and a
  fixed 15s dispatch-preflight timing bound that doesn't account for how much more expensive
  process spawning is under Git Bash's fork() emulation. Each now matches the same rendering
  the code under test produces, or gets a platform-specific bound.
- Skipped two `verify-worktree-docker.bats` docker-in-docker guard tests on Windows: CI logs
  show the recipe's real `docker.exe` runs instead of the test's stub even with the shell
  pinned to `sh`, so something in how GNU Make's Windows port resolves the recipe's `PATH`
  isn't reachable from this test's own prepend. The guard logic itself is still covered on
  Linux/macOS; fixing the Windows case needs an actual Windows box to iterate against.

## [1.29.102]

### Fixed

- **`detect-mode.sh` no longer falsely forces `host` mode for a project root reached through
  a symlink.** Its git-containment check compared `$PROJECT_ROOT` verbatim against
  `git rev-parse --show-toplevel`'s output, which git returns with symlinks already resolved.
  On macOS, `$TMPDIR` sits under `/var`, itself a symlink to `/private/var`, so every project
  root under a tmp dir failed this comparison and skipped the Makefile-based docker scan
  entirely, before ever looking at the Makefile. `$PROJECT_ROOT` is now canonicalized with
  `pwd -P` before the comparison.

## [1.29.101]

### Fixed

- **`detect-mode.sh`'s Makefile-target scan no longer relies on recipe text alone to catch
  docker.** A `make -n <target>` whose expanded recipe runs a nested `make` that only then
  invokes docker (or invokes it via a target chain the grep for `docker (compose|run|exec)`
  doesn't match) previously fell through to `host` mode. The scan now also shadows `docker`
  and `docker-compose` on `PATH` with stub binaries that just log their invocation, so any
  dry run that actually executes one — through however many layers of indirection — still
  flips the result to `docker`.

### Tests

- Several bats tests hard-coded assumptions that don't hold on Windows/MSYS or under root:
  path-separator comparisons, `CREW_SCRIPTS`/git mount path rendering, symlink-vs-copy `.env`
  fallback, and `chmod 000` actually denying the owner a read. Each now compares against the
  same tool's own rendering of the platform-specific value, or skips when the platform doesn't
  enforce the permission being tested, instead of asserting a Unix-specific literal.

## [1.29.100]

### Fixed

- **`git rev-parse --git-common-dir` is now called with `--path-format=absolute`** in
  `dispatch-codex-agent.sh`, `receipts.sh`, `verify-worktree.sh`, `detect-mode.sh`, and
  `ensure-env.sh`. Without it, a bare drive-letter Windows path (e.g. `C:/Users/...`) doesn't
  start with `/`, so each caller's own "is this already absolute" branch wrongly treated it as
  relative and mangled it.
- **`dep-install`'s Makefile-target scans (`detect-mode.sh`, `detect-service.sh`,
  `ensure-env.sh`, `host-install.sh`) no longer gate on `make -n <target>`'s exit status.** A
  recipe whose expanded text contains the literal word "make" (not just the `$(MAKE)` variable)
  makes some GNU Make builds — notably 3.81, the last GPLv2 version and still macOS's default —
  actually run it instead of only printing it under `-n`, so a real (sandboxed, daemon-less)
  docker failure could make the dry run exit non-zero even though the recipe text itself was
  right there in its output. Each now treats a non-empty dry-run as the "target exists" signal.
- **`ensure-env.sh` and `gen-override.sh` fall back to copying instead of symlinking** when
  `ln -s` doesn't produce a real symlink — the default on Windows without Developer Mode or
  elevation, where MSYS's own undocumented fallback can otherwise silently substitute a
  hardlink or copy that this code then trusted without verifying.

## [1.29.99]

### Fixed

- **`crew-afk` no longer tears down a worktree whose worker process status is unconfirmed.**
  `finishPartial`/`finishBlocked` only skipped closing the herdr pane when `worker.dispatch.herdrFailed`,
  but still removed the worktree underneath it — a reused herdr pane's `--wait` can falsely settle
  on a stale idle/done from a prior turn, or sit on a blocked dialog, so the underlying agent
  process may still be alive. Both paths now keep the worktree in place too when `herdrFailed`,
  matching the existing `keepWorktree` reuse path, so next round's `ensureWorktree` can reuse it in
  place instead of racing a live process for its own directory.
- **`ensure-deps.sh`'s cached-install re-run no longer aborts under bash 3.2 (macOS's stock
  `/bin/bash`) when there's no captured git env.** `env "${GIT_ENV_LINES[@]}" ...` treats an empty
  array as unbound under `set -u` on bash < 4.4; switched to `"${GIT_ENV_LINES[@]+"${GIT_ENV_LINES[@]}"}"`.
- **`dep-install`'s `ensure-env.sh`/`gen-override.sh` worktree-vs-main-root comparisons now work on
  Windows.** Both used bash's `-ef` (device/inode identity), which MSYS's NTFS emulation doesn't
  reliably support; both now compare `pwd -P`-resolved paths instead.
- **CI installs a bash >= 4 on macOS runners** before any test step runs, since Apple has frozen
  `/bin/bash` at 3.2 (GPLv2) and several scripts (`declare -A`, empty-array expansion under
  `set -u`) require bash >= 4.

### Added

- **`solve-issue` now tells a bug-fix issue to fix shared behavior at the function every caller
  routes through**, not only at the call site the issue names, so a guard added at one caller
  doesn't leave every sibling still broken.
- **`solve-issue` now commits after every TDD GREEN, not only once at the end**, via
  `commit-changes.sh --prefix "[<slug>][WIP]"`, so a dispatcher timeout that kills a run mid-loop
  still leaves a resumable commit on the branch instead of an indistinguishable-from-unstarted
  worktree. These WIP commits get squashed away before merge.
- **`tdd`'s refactor checklist now includes removing abstractions that cycle didn't earn its
  keep** (an interface with one implementation, config for a value that never changes).

## [1.29.98]

### Fixed

- **`crew-afk`'s herdr pane/tab titles now carry the issue number.** `dispatchViaHerdr` built the
  visible tab label and pane title from the bare issue slug alone (e.g. `implement-user-auth
  (coder)`), so a human scanning panes across multiple issues and rounds couldn't tell which
  pane belonged to which issue — only the internal herdr agent name carried the `i<N>-` prefix.
  Both now show `#<issueNumber> <slug>` when an issue number is known.

## [1.29.97]

### Removed

- **Dropped CodeGraph support.** `ensure-codegraph.sh` (and its dedicated pipeline step, run
  between deps and dispatch) is gone, along with the `codegraph`/`codegraph_explore` search
  fallback in `crew-coder`'s protocol and every platform file, and the codegraph-preference
  callout in `crew-brainstorm`/`crew-grill`. Workers fall back to keyword search (`Grep`/`grep`)
  unconditionally now; nothing reads or writes a `.codegraph/` index anymore.

### Changed

- **`discover-commands.sh` (used by `add-tests`) now tells its command-discovery prompt to report
  a Makefile target's own invocation** (e.g. `make test`) rather than a paraphrased "equivalent"
  command, since the recipe can hide guards, prerequisites, or CI/local conditionals a paraphrase
  would drop.

## [1.29.96]

### Added

- **`dep-install` skips a redundant install when manifests are unchanged since its own last
  successful run.** `host-install.sh` and `docker-install.sh` now fingerprint every recognised
  lockfile/manifest (`manifest-fingerprint.sh`) before doing any ecosystem detection, and skip
  straight to done on a match. Both scripts gain `--force` to bypass that fast path, and the
  skill's own retry rule (triggered by a module-not-found error) now passes it — otherwise the
  retry would see the same unchanged manifests and skip itself again, making the retry a no-op.

## [1.29.95]

### Changed

- **`upgrade-deps` now also scans for advisories on transitive-only dependencies.**
  Cross-referencing an audit against the step-2 inventory alone misses any advisory on a
  package that never gets its own row there (e.g. `follow-redirects` pulled in only via
  `axios`). After cross-referencing, the skill now scans the raw audit output a second time
  for advisories with no matching step-2 row, names the direct dependency pulling each one
  in, and checks whether another issue in the same batch already resolves it as a side effect
  of its own bump before filing a duplicate.
- **Major-bump review step 6a (tarball diff) is now a required minimum, not skippable in favor
  of the changelog text search (6e).** 6b–6d must each be attempted and their result — including
  "skipped because X" — stated in the issue; a silent omission read as "not checked" is
  indistinguishable from "checked and clean" to whoever picks up the issue next.
- **"It's just a dev-tool/config dependency" no longer excuses downgrading a major bump's
  status on its own.** That reasoning is about blast radius, not whether behavior changed, and
  a lint/build tool major can still hide a judgment-call regression (e.g. mass-suppressed lint
  rules) that the mechanical checks won't catch. Only a proven zero-code-diff still downgrades.

## [1.29.94]

### Removed

- **Dropped `crew.lock`, `--version`, `--from-lockfile`, and `bootstrap.sh`'s matching flags.**
  The pinned-version team-distribution flow only refreshed `crew.lock` when `--version` was
  explicitly passed — a plain re-install (the common case) left a previously pinned lockfile
  stale with no warning, and `--update` would silently keep "updating" against that stale pin.
  `--update` now always reads `.coding-crew/manifest.json`, which every install already writes
  unconditionally.

## [1.29.93]

### Changed

- **`crew-coder`, `crew-code-reviewer`, and `crew-triage` reports are now read exclusively from
  their `<slug>.<role>.report.json` sidecar file.** `report.mjs` no longer falls back to scanning
  a dispatch's final message for a fenced ` ```json ` block or the older markdown headings
  (`Status:`, `Branch:`) — a missing or invalid sidecar is read as the fail-closed state
  (`blocked` for a worker, `unmet` for a review, `fixable` for triage) deterministically, the
  same way for every platform and for both the headless and herdr dispatch paths.
  `dispatchViaHerdr` drops its pane-text-scraping fallback (`extractHerdrReply` and its
  echo/end-marker heuristics) to match: a herdr pane that settles idle/done with no sidecar now
  fails the same way the headless path already did, instead of reconstructing a result from
  rendered terminal text — the least robust, least-verified code in that file.
- **`crew-coder` no longer writes a per-worker `traces/<branch>.log` file.** The `[START]`/`[DONE]`
  trace was a write with no reader now that `report.mjs` only ever reads the sidecar; removed
  outright rather than trimmed further.

## [1.29.92]

### Changed

- **`upgrade-deps`'s major-bump review is now five mechanical signals instead of a single
  changelog text search.** Step 6 ("Mechanical impact signals") now runs, in order: a tarball
  diff between the current and target versions (proves zero code change when metadata/docs are
  all that moved), a structural API diff against the call sites step 5 found, breaking-change
  commit mining against the package's declared repo, a disposable-worktree
  typecheck/test/lint run at the bumped version, and — last resort — the changelog text search
  step 6 used to do alone. A major bump whose tarball diff is provably empty, with no confirmed
  export break and a clean worktree run, now downgrades to `Status: ready-for-agent` instead of
  always escalating to `ready-for-human`; every other major-bump case still escalates
  regardless of how many mechanical checks came back clean, since those checks are proxies for
  behavior that could still have changed underneath them. Step 4's `npm ls`/`why` conflict scan
  is now paired with a resolver dry-run (`npm install --dry-run`, `pnpm add --lockfile-only`, or
  `yarn up --mode=update-lockfile`) so the safety checklist reports the actual post-bump
  resolution instead of inferring it from today's tree. The skill also resolves
  `dev-commands.json`'s `typecheck` field up front (via `add-tests`'s own discovery/cache
  mechanism) so step 6d has a real command to run.

### Fixed

- **`.worktreeinclude`'s `.env` entry is now provisioned into a worktree as a real copy
  instead of a symlink.** A symlink to mainRoot's absolute path resolves to a path that
  does not exist for a worker running inside a container that bind-mounts only the
  worktree, so a from-worktree read/write of `.env` failed with ENOENT even though the
  file was "there" from the host's point of view. Every other `.worktreeinclude` entry
  (`node_modules`, `.venv`, `docker-compose.override.yml`, …) is still symlinked.

## [1.29.91]

### Changed

- **crew-afk keeps a failed herdr dispatch's pane open by default instead of closing it
  immediately.** A `DISPATCH-FAIL` used to close the tab the moment it was logged, so the one
  thing worth inspecting — what the pane actually rendered — was already gone. `CREW_HERDR_KEEP_PANE`
  is no longer opt-in for this; set `CREW_HERDR_KEEP_PANE=0` to restore the old close-on-fail
  behavior (e.g. to avoid panes piling up in unattended CI). A retry's fresh dispatch name now
  folds in the round number (`i42-r2-...`) so it never collides with a still-open kept pane from
  an earlier round under `agent_name_taken`.
- **An `AC: unmet` review verdict now reuses the coder's already-open herdr pane for its retry**,
  the same way a verify failure already did, instead of always starting the fix cold.
- **A worker dispatch that died (timeout, process crash, herdr transport failure) is now retried
  as `partial` instead of `blocked` when its branch already has commits** — there is real work
  worth resuming next round, not just a repeat failure to report.
- **A coder's own honest partial self-report now reuses its already-open herdr pane for the
  retry too**, the same one-reuse-per-issue bound `AC: unmet` and a fixable verify failure
  already get.
- **The JS-side kill on a `herdr agent prompt` call now waits 2 minutes past herdr's own
  `--timeout` before firing**, instead of racing it at the same instant. That race could let our
  own `SIGKILL` win and erase herdr's chance to ever print the `agent_prompt_stalled`/`timeout`
  JSON its exit is diagnosed from, leaving a `DISPATCH-FAIL` with empty stderr and a
  falsely-false `timedOut`; the JS-side timer now only backstops a herdr CLI that hangs without
  ever honouring its own `--timeout`. Herdr call failures also now propagate the CLI's actual
  exit code instead of always logging `1`.
- **A herdr `agent prompt` failure with no stdout/stderr at all now runs a one-off `herdr status`
  check** to say whether the server crashed or restarted mid-sprint, or is still running (a
  transport/session-specific hiccup with that one pane) — previously this logged identically to
  every other silent failure, with no way to tell which one retrying would fix.
- **`ensureWorktree` no longer stalls on a branch whose tree is byte-identical to `base`'s**, even
  though ancestry can't see it as a fast-forward (a squash elsewhere produces a new commit
  carrying the same tree). That branch holds no unique work — typically debris left by a prior
  run whose commits were later squashed into the feature branch and never cleaned up — so it's
  deleted and recreated fresh from `base` instead of stalling for a human. A real ancestry
  mismatch with actual unique content still stalls, unchanged.

### Added

- **`add-tests` skill**: discovers the project's coverage/integration commands, ranks
  under-covered files by external-dependency import > recent-diff touch > inverse coverage,
  resolves a per-ecosystem mocking convention (repo precedent > built-in defaults > ask-once,
  cached to `test-conventions.md`), routes findings to a real or explicitly-labeled
  "component test (mocked)" tier, and hands them to `to-issues` as `ready-for-agent` issues
  rather than slicing/publishing them itself. The shared `discover-commands.sh`/
  `write-commands-cache.sh` cache (`dev-commands.json`) grows two new fields, `coverage` and
  `integration`, following the same only-if-documented/else-null convention as the existing six.
- **`upgrade-deps` skill**: audits outdated npm/yarn/pnpm dependencies across a monorepo for
  security-advisory exploitability, transitive/peer conflicts, and real call-site usage, with a
  targeted changelog review for major bumps, then files `ready-for-agent`/`ready-for-human`
  issues (batched for trivial in-range bumps, one per risky package or coupled group otherwise)
  with a required safety checklist and test additions, for `crew-afk`/`solve-issue` to execute.
  Never touches `package.json`, lockfiles, or `node_modules` itself.

## [1.29.90]

### Added

- **A user-level install now honors each platform's own config-dir override instead of always
  writing under `$HOME`.** `install.sh`/`uninstall.sh` previously hardcoded `$HOME/.claude`,
  `$HOME/.copilot`, `$HOME/.pi/agent`, `$HOME/.codex` at user scope, so a user who points their
  CLI elsewhere via `CLAUDE_CONFIG_DIR`, `COPILOT_HOME`, `PI_CODING_AGENT_DIR`, or `CODEX_HOME`
  got files installed where that CLI never reads them. Both scripts now resolve each platform's
  destination through the matching env var (falling back to the `$HOME`-relative default when
  unset), and `uninstall.sh` removes from wherever `install.sh` actually wrote.

## [1.29.89]

### Fixed

- **Command discovery (`discover-commands.sh`) no longer trusts a partial `.coding-crew/dev-commands.json` as fully discovered.** It used to skip re-running discovery the moment the cache file existed at all, regardless of which of the six fields (`test`/`lint`/`typecheck`/`install`/`env`/`credential_target`) it actually contained. That let a partial write — e.g. `ensure-deps.sh`'s own `install_mode`/`docker_service` fields landing first because an earlier sprint's model dispatch failed (expired credentials, a timeout) before ever writing the six discovery fields — permanently starve every later sprint of full discovery, since the file "already existed." The skip now requires all six fields to be *present* (any value, including JSON `null`, which still means "checked, confirmed no such command") before trusting the cache; a cache missing even one field falls through and re-runs discovery.

## [1.29.88]

### Fixed

- **`install.sh` now re-execs into a newer bash instead of dying with `declare: -A: invalid
  option` on macOS.** Apple's stock `/bin/bash` is 3.2 (frozen there since the GPLv2→GPLv3
  switch) and `install.sh`'s own `#!/bin/bash` shebang is resolved by the kernel from that
  hardcoded path, not from `$PATH` — so a newer Homebrew bash already on a user's `PATH` was
  never picked up just by running the script (which is what `bootstrap.sh`'s `exec "$INSTALL"`
  does). The registry-read cache needs `declare -A` (bash ≥ 4). The script now detects bash < 4,
  hops to a findable newer bash (Homebrew's common install locations, or `PATH`), and exits with
  `brew install bash` guidance if none exists.

### Added

- **`install.sh claude --skills a,b,c` now treats that list as the full desired skill set:** a
  name present in a prior `--skills` install but missing from this one is uninstalled, instead
  of being silently left on disk forever. `write_manifest()`'s merge only adds/updates keys, so
  without this a shrunk `--skills` list had no way to actually drop anything. The new
  `prune_skills_not_in()` shells out to `uninstall.sh --skill` — the existing single writer of
  skill removal — rather than duplicating that logic, then deletes the pruned key from
  `manifest.json` so the merge doesn't resurrect it.

## [1.29.87]

### Removed

- **The `caveman` and `improve-codebase-architecture` skills are gone**, along with their
  `registry.json` entries, `install.sh`/`bootstrap.sh`/`unbootstrap.sh`/`uninstall.sh` examples,
  doc references, and structural tests. Both were third-party skills (`JuliusBrussee/crew-caveman`,
  `mattpocock/skills`) this repo no longer maintains as part of its distribution.

## [1.29.86]

### Fixed

- **`runWorker`/`runReview`/`runTriage` now delete each dispatch's `.report.json` sidecar
  before writing that round's prompt, instead of leaving a prior round's (or a prior resumed
  sprint's) sidecar sitting at the same fixed path.** `waitForSidecarReport` in `dispatch.mjs`
  treats `existsSync` as "found" the instant the herdr wait settles, so a stale sidecar from an
  earlier dispatch to the same slug was read back as this round's verdict whenever the coder's,
  reviewer's, or triage agent's turn died before writing a fresh one — a false verdict rather
  than the intended pane-scrape fallback.

## [1.29.85]

### Changed

- **The `<slug>.report.json` sidecar-first dispatch policy (already used for the crew-coder
  worker) now also covers the reviewer and triage agents.** `dispatchViaHerdr` checks each
  role's report file before scraping the pane at all: the review and triage prompts now name
  a `reportPath` and instruct the agent to write its verdict there as its last action, falling
  back to the same fenced-json-in-prose reply only if that file never lands.
  `parseReviewReport`/`parseTriageReport` accept the parsed sidecar and prefer it over the
  captured text entirely, same policy `parseWorkerReport` already had. Closes the same class of
  herdr read-capture failure (empty/garbled pane render) for review and triage that the worker
  fix already closed — a genuine verdict no longer depends on a terminal scrape succeeding.

---

Older entries have been moved to [docs/CHANGELOG-archive.md](docs/CHANGELOG-archive.md).
