# Changelog

Users install from `main` (`bootstrap.sh`), and `install.sh --update` follows each agent's and
skill's own `version` in `registry.json`. Tagged releases mark milestones only, not every merge.
Record changes under `[Unreleased]` and move them under a version heading when you cut a release.

## [Unreleased]

- `write-pr` (new skill): writes a PR body for a human reviewer, adapted from mattpocock/skills' `pr`. It has three
  sections: Summary (the smallest pseudocode, call tree, file tree, Mermaid diagram or diff-sketch that makes the
  change clear), Evidence (before/after) and Merge Danger (one-way or two-way door, blast radius). Run it by hand as
  `/write-pr`.
- `crew-afk`: with `--open-pr`, a new `prWriter` role (plain dispatch; default timeout 10 min) follows `write-pr` over
  `base..feature` with the PRD and the review report. Its body goes at the top of crew-afk's block in the PR, above a
  checks line taken from the integration check's own record and the `Closes` lines. The PR is titled after the PRD.
  If the writer leaves no `## Summary`, the PR still opens and the run summary says why.
  `open-pr.sh` gains `--body-file` and `--title`.

- `solve-issue`: with `CREW_DEFER_FULL_CHECKS=1`, `run-checks.sh` runs only `typecheck` and `lint`; `test` and the
  other checks print `<key>: deferred …` and are left to the verify gate. Step 4 now says to run the affected tests
  before committing; Step 5 says to report a deferred check as `deferred`.

- `to-prd` / `crew-afk`: a PRD may carry `Origin: #<n>[, #<n>…]` under its `Actor:` line; `closingRefs` adds `Closes #n` for each exactly when it adds the PRD's own, and `close-shipped.sh` closes each open origin issue (commenting the PRD and PR) in the run that closes the PRD.
- `crew-afk`: under `tracker: github`, the fix issues `promote-findings.sh` creates carry their evidence instead of a
  pointer to a gitignored local report — `defer` embeds each promoted finding's full reviewer text under
  `## Review findings`, `defer-gaps` the audit's per-requirement evidence, `defer-integration` the tail of the failing
  output. `Source:` now names the kind (`review (<branch>)`, `PRD audit (prd-audit)`, `integration check
  (integration)`), `guard` reads it as before, and absolute and `.scratch/` paths are scrubbed from the body.
- `crew-grill`, `crew-brainstorm`: keep the design proportionate to the problem — size must be justified, by the
  problem or by the structure of what is built now (one owner per concern, no duplication, a needed test seam), never
  by needs nobody has yet. The problem is sized first (how often,
  the manual workaround's cost, what breaks if nothing is done — looked up, not asked), and solutions the user brings
  are inputs, not the menu. Every question deciding how much to build includes the do-least option (down to "by hand" or "leave it"); a larger
  recommendation needs evidence it falls short, not completeness alone, and names the follow-on components it drags
  in. A subtraction pass before the summary/approval proposes cutting any decision or component nothing depends on,
  and shows the cut list; `crew-grill` carries what stays cut into the PRD's Out of Scope.
  Sizing never replaces asking: good questions are kept, a requirement the user stated is priced and never relitigated,
  logic that would be copied into several places gets one shared owner, and frequency/cost are looked up, not asked.
- `crew-afk`: a worker's `verify-worktree.sh` and per-worktree `ensure-deps.sh` now run asynchronously, so two branches
  verify concurrently and a slow verify no longer stalls the other worker loops or a free slot's next dispatch. Merge
  and close stay blocking, and so serialized; timeouts still map to exit 124.
- `crew-afk`: a verify ended by a signal (not the call's own timeout) is *interrupted*, not failed — no triage, no
  coder, no failure logged, and the issue is verified again next round for free. Verify output that names no failing
  check is run a second time before triage; if still empty the issue is re-verified next round, never recoded.
- `crew-afk`: `merge-branches.sh` no longer fails a merge whose only conflicts are parallel issue branches bumping
  the same `registry.json` entry or appending to the same `CHANGELOG.md` heading. New
  `resolve-merge-conflicts.sh` keeps the higher semver per entry's `version` and both sides' appended entries
  (feature side first), completes the merge commit, and prints and traces each decision (entries and versions
  kept), so no coder is redispatched. Any other conflict, including any other `registry.json` field, still
  aborts the merge as before.
- `crew-reviewer`: new HIGH class, *second reader of the same input* — when a diff adds code that parses, validates
  or gates an input existing code already interprets, the reviewer compares the two by reading and reports any input
  the existing reader accepts that the new one rejects or reads differently, citing both sides.
- `to-issues`: a slice that adds a parser, validator or gate for an input the repo already holds examples of carries
  one criterion that it accepts them, naming the examples to copy into committed fixtures (never a live or gitignored
  directory); no examples, no criterion. `to-prd`'s `## Compatibility & Migration` names where that data lives.
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
  Installed at `.coding-crew/to-issues/scripts/`. `--known` names issues outside the set (preflight passes the
  done ones) so a resumed sprint's refs to them resolve; a ref resolves by its basename (path citations and
  markdown links included), prose like `schema/API` is not a ref, and `_None_` / `—` placeholders mean no blocker.

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
