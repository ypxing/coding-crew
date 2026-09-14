# Changelog

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
