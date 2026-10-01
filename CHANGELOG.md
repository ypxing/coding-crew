# Changelog

Users install from `main` (`bootstrap.sh`), and `install.sh --update` follows each agent's and
skill's own `version` in `registry.json`. Tagged releases mark milestones only, not every merge.
Record changes under `[Unreleased]` and move them under a version heading when you cut a release.

## [Unreleased]

- `to-issues`: slices are one externally observable behaviour verified at the highest existing test seam (first
  slice = thinnest end-to-end path), merged when they share a seam and neither is reviewable or demoable alone,
  with 3–8 acceptance criteria as the soft target. A coverage table traces every PRD `D<n>`/`B<n>` to its slices;
  the quiz asks only about outliers (contradicted assumptions, PRD `## Assumptions`, uncovered IDs, criteria-range
  outliers, shared surfaces, HITL choices) then one approve/adjust prompt; expand–contract sequencing comes from
  `## Compatibility & Migration`; `lint-issues.sh` runs before any `publish` and an `ERROR` publishes nothing.
- `crew-afk`: preflight runs `to-issues`' `lint-issues.sh` over the feature's open issues (and `issues-deps.json` /
  PRD when present) before command discovery or any worktree. An `ERROR` stops the run, quoting each line; `WARN`
  lines are logged; a linter that exits 2 or cannot run is logged without stopping. `--dry-run` reports without
  stopping. The `to-issues` assets are now a `crew-afk` dep, and a missing `lint-issues.sh` joins the
  missing-assets stop.
- `to-issues`: add `lint-issues.sh`, a read-only checker for an issue set (ERROR for cycles, unmatched
  `## Blocked by` refs, `--deps` drift and missing acceptance criteria; WARN for advisory problems).
  Installed at `.coding-crew/to-issues/scripts/`.

## [2.0.0]

First milestone release, with a new baseline. The 1.x line (v1.1.0–v1.29.157, plus untagged
1.30–1.38) was retired, so its history now lives only in git (`git log`).

### What ships

- **Platforms:** Claude Code, GitHub Copilot CLI, OpenAI Codex CLI and pi, installed by
  `bootstrap.sh` / `install.sh` and updated per entry with `--update`.
- **Planning:** `/crew-grill` and `/crew-brainstorm` → `/to-prd` → `/to-issues`, with local
  markdown issues or GitHub Issues (`/configure-tracker`).
- **`/crew-afk` sprint:** one `crew-coder` per issue, each in its own worktree. Every issue goes
  through deps → TDD → verify → `crew-reviewer` → acceptance-criteria gate → merge → close, with
  `crew-triage` deciding whether a failure gets a retry.
- **Feature-level gates:** an integration check on the merged feature branch, one review of the
  whole feature diff, a PRD audit, and actionable findings and fixable failures promoted into a
  Phase 2 fix pass.
- **GitHub tracker:** status labels, ticked criteria on close, and `Closes #n` lines (including
  the PRD once no work issue is left) in the PR that `--open-pr` opens.
- **Follow-up skills:** `/crew-address-findings`, `/solve-issue`, `/address-pr-comments`,
  `/add-tests`, `/upgrade-deps`, `/domain-modeling`, `tdd`, `dep-install`.
