# Changelog

Users install from `main` (`bootstrap.sh`), and `install.sh --update` follows each agent's and
skill's own `version` in `registry.json`. Tagged releases mark milestones only, not every merge.
Record changes under `[Unreleased]` and move them under a version heading when you cut a release.

## [Unreleased]

- `crew-afk`: at a report-only feature drain, the finding a `duplicate_of` was folded into is marked `report_only` in the report (the fold's copy no longer differs from it in severity and location), so it stays open and keeps the run from green.
- `crew-afk`: review findings are promoted only after their branch merges and its issue closes; a branch whose close was refused promotes on the retry that completes the merge, from its saved review (not when an earlier run already promoted it). Findings triage reads a branch's change from its merge commit's first parent, and the feature review's from its own range, instead of a diff against the feature branch.
- `crew-afk`: a branch's newest review block carries the findings its earlier blocks (any `sprint-review-*.md`, including an earlier run's) raised and it does not repeat, marked `"carried": true`; a `not_run` block keeps the previous findings carried. The summary counts them, and `remind` and the PR's posted findings label them `(earlier review)`.
- `crew-afk`, `to-issues`, `to-prd`, `upgrade-deps`, `crew-address-findings`: shared fragments live flat at `skills/_shared/fragments/<key>.md`; the `common/` and per-platform lookups are gone (the four per-platform `tracker-configuration.md` copies were identical), as is the unused skill-local `fragments/<platform>/` lookup. Installing crew-afk removes the old `common/` and per-platform fragment directories.
- `crew-afk`: a later feature review that writes its `feature` block closes an earlier run's not-run `feature-<n>` area in `review-rollup.mjs`, so `remind` and the summary no longer report it; a gap from the same run is written after the block and still shows.
- `crew-afk`: a whole-feature review is split by a planner into up to `maxParallel` areas, each read end to end by its own concurrent `crew-reviewer` (`feature-<n>`) given an `Area:` block of its files and the full text of its PRD decisions; findings join one `feature` block and are promoted once. A failed planner gives one whole-diff area; a failed area is recorded not-run as `feature-<n>`. An incremental review stays one reviewer.
- `crew-afk`: the feature review covers the whole feature (merge-base with origin's default branch, else the local one) instead of only the run's `base_sha`, then only the commits added since (`feature_review.reviewed_tip`, `state.sh feature-reviewed`); an unchanged tip dispatches no reviewer, and the wall-clock cap with a claimable issue left skips it.
- `crew-afk`: the per-branch review checks the PRD decisions an issue implements. The review prompt gains a `PRD decisions this issue implements:` block — the PRD's `- **D<n>** — …` / `- **B<n>** — …` lines for the IDs under the issue's `## Implements` (PRD from `.scratch/<slug>/PRD.md`, `prd-issue.md`, or fetched once per run under `tracker: github`) — and a branch contradicting one is `unmet` with `detail` naming the ID. An ID with no PRD line, or a failed fetch, only warns.
- `crew-afk`, `solve-issue`: codex's plain roles run read-only (only their result directory writable). `--targeted` sees through env assignments, `env`/`time` and `bundle exec`/`poetry run`-style wrappers and a `;` with no space when deciding a runner takes no file arguments, and counts mocha's `test/*.js`, phpunit's `*Test.php`, nested `__tests__/` and colocated tests under a `helpers/` source dir as test files. The full-suite deviation is also spotted inside a subshell or a quoted `bash -lc '…'`. `ORCHESTRATOR_PREFETCH=1` starts the node-suite prefetch only for a bats run that includes an orchestrator wrapper.
- `crew-afk`: a red baseline also stops a worker still installing deps before its coder starts, and an attempt whose coder it stopped is retried by a coder next run (not routed to verify-only). The read-only guard excuses a feature-branch or `HEAD` move only for a git that can move them (a merge, not a `worktree prune`), a crew branch's only for a branch-moving git or its worktree's own activity, and compares worktree paths by realpath. `open-pr.sh --no-push` sets only the draft state, leaving the PR's body and closing lines; a `--draft` create falls back to a ready PR only when the repo refuses drafts. Under `tracker: github` a fix issue created but not yet listed past the cap still counts as work the cap left undone.
- install: the retired agent files are removed on every platform by any install (not only crew-afk's, for its platform), so dropping the manifest's `agents` strands none. crew-afk's shared fragments are a registry `more-assets` entry, which install, uninstall and the version gate all see. `unbootstrap.sh --agent` is gone with `uninstall.sh --agent`.
- `crew-afk`: an integration-red run still pushes nothing and opens no PR, but a PR an earlier run opened for the branch is turned into a draft with the reason in its crew-afk block (`open-pr.sh --no-push`, which updates only an open PR).
- `crew-afk`: an issue blocked without a branch (a failing `## Requires`) is listed with its reason in the `--open-pr` note (`state.sh blocked` records `blocked_reasons` for every blocked issue). A repo that refuses draft PRs gets a ready PR, with `PR-STATE-FAILED:` naming why, instead of none.
- `crew-afk`: codex reads its prompt (protocol and task) on stdin again (`codex exec … -`), so no codex prompt hits an argv limit. The argv guard checks each argv string against the 128 KiB cap (pi's protocol and prompt are separate strings) and, on Windows, the whole command line against 32,767 characters. The plain roles (command finder, PRD auditor, PR writer) dispatch through their platform's adapter like every other role (codex with its sandbox flags, pi with `--mode json`, final text and cost read from the event stream). Every claude dispatch runs with auto-memory off. A pane-hosted worker leads its own process group, so a timeout or interrupt kills its children too.
- `solve-issue`, `crew-afk`: a coder's `run-checks.sh --targeted` runs only the tests its own branch changed — crew-afk sets `CREW_BASE_REF` to the feature branch, which the merge-base used to miss — and only real test files (a helper, fixture or other file under `tests/` is no longer handed to the runner). A test command whose runner takes no file arguments (`make`, `go`, `cargo`, `gradle`, `mvn`, …) reports `test: deferred (the test command takes no test file arguments)` instead of running with paths appended.
- `crew-afk`: a red baseline now also kills the dispatches already running (`[BASELINE-RED]`), so the run exits 1 at once instead of after the coders' timeouts; their branches are kept, unverified, for the next run (a free attempt). Past the wall-clock cap or a red baseline the idle-slot poller lists the tracker no more. The cap counts as hit only when it left an issue unclaimed or a fix issue parked, so a run that finished everything after minute 120 is green; a cap hit exits 2 even when the attempt cap also ended the run.
- `crew-afk`: a SIGHUP to the orchestrator (terminal closed, SSH dropped) kills every worker's process group and exits 129, as SIGINT/SIGTERM already did; `doctor` reads a flag folded into brackets in a CLI's `--help` (claude's `--append-system-prompt[-file]`), so it no longer fails on every claude install.
- `crew-afk`: the read-only guard snapshots every `crew/<feature>/*` ref, the feature branch and the branch `HEAD` is on for every reviewer and triage dispatch, not only the dispatch's own branch. A concurrent effect no longer switches the `HEAD` and feature-branch checks off: only a main-checkout ref move (a merge) excuses those, and only a busy worktree excuses its own branch. A violated dispatch's cost is still recorded. A per-issue verify that ran with uncommitted files in the worktree no longer caches its tree as passing (`[TREE-NOT-CACHED]`).
- `crew-afk`: its roles are no longer agents. `crew-coder`, `crew-reviewer` and `crew-triage` leave `registry.json` (with crew-afk's `agent-deps`); their protocols move to `orchestrator/roles/{coder,reviewer,triage}.md` and the reviewer's checklists and scripts to `orchestrator/roles/reviewer/`, all shipped with the orchestrator to `.coding-crew/crew-afk/roles/`. Installing crew-afk removes every file listed in the new `retired-agents` (the old per-platform agent files, `.coding-crew/agents/`, `.coding-crew/code-review/`); `--update` of an install whose manifest lists agents installs crew-afk and drops them; `./install.sh <platform> crew-coder` installs crew-afk with a note; `uninstall.sh --agent` and unknown `uninstall.sh` arguments are refused instead of removing everything. The coder's prompt now ends with each named skill's installed SKILL.md path (`solve-issue`, `dep-install`, `tdd`), and the report JSON is defined once, in the coder protocol, which the worker prompt points at.
- `crew-afk`: the four launchers render from one `SKILL.md` with `{{PLATFORM}}` and no per-platform fragments; every platform's frontmatter pre-approves the shell (`allowed-tools: Bash, shell`). The unused `skills/crew-afk/references/test-*.sh` scripts are deleted, and `install.sh --update` removes them from installs.
- `crew-afk`: the `--open-pr` PR body describes the PR's whole range — from the feature branch's merge-base with origin's default branch (`origin/HEAD`, else `origin/main`, else `origin/master`) — instead of only the latest run's commits; the run's recorded `base_sha` is used only when there is no origin default branch.
- `crew-afk`: `doctor` runs each active platform CLI's `--help` (`codex exec --help` for codex) and reports a PROBLEM, exit 1, when the output lacks a flag its adapter declares in `requiredFlags` for a full-permission headless run.
- `crew-afk`: every spawned child runs in its own process group; a timeout (`exec`, `bashAsync`, `spawnWithTimeout`) or SIGINT/SIGTERM to the orchestrator kills the whole group, grandchildren included (exit codes unchanged: 124, 128+signal). Script lookup also checks `CLAUDE_CONFIG_DIR`, `COPILOT_HOME`, `PI_CODING_AGENT_DIR`, `CODEX_HOME` (after the project install, before the `$HOME` defaults).
- `crew-coder`, `crew-reviewer`, `crew-triage`, `crew-afk`: the per-platform agent files (`claude.*`, `copilot.agent.md`, `pi.*`, `codex.agent.toml`) and the shim install are gone; `agents/<name>/` holds only `protocol.md` (and `assets/`). Install writes each protocol to `.coding-crew/agents/<name>/protocol.md` plus the shared fragments under `.coding-crew/skills/_shared/fragments/`, writes nothing under `.claude/agents`, `.github/agents`, `.pi/agents` or `.codex/agents`, and `install.sh --update` removes the shims an older install wrote there (those exact files only). The crew-afk launchers no longer name an agent file or `--agent`. CLAUDE.md's `crew-coder` layer row reads protocol + report wire.
- `crew-afk`: the `fixFindings` level → severities list is resolved only in `orchestrator/lib/report.mjs` and passed to `promote-findings.sh` as `--severities` (now required by `guard` and `defer`, exit 2 naming it when missing); the script keeps no level table, its `policy` subcommand is gone (`crew-summary.sh` takes `--promoted <list>`), and the legacy `CREW_PROMOTE` is no longer read.
- `solve-issue`, `crew-afk`: under `CREW_DEFER_FULL_CHECKS=1` a coder runs tests through `run-checks.sh --targeted` — only the test files changed on the branch since its merge-base, reported `test: pass|fail (targeted)`, or `test: deferred` when none changed; the full suite stays the verify gate's. crew-afk logs `[DEVIATION]` when a coder's trace shows the `dev-commands.json` `test` command run in full and names it under `## Deviations` in the summary; the issue is not failed.
- `crew-afk`: on pi and codex every role is dispatched through `orchestrator/lib/adapters/` (`pi.mjs`, `codex.mjs`) from the rendered protocol, like claude and copilot; no `.pi/agents/` or `.codex/agents/` file is read. pi gets the protocol via `--append-system-prompt` and the role's `--tools`; codex gets it prepended to the prompt, the role's `-c model_reasoning_effort=…` and sandbox (read-only roles run workspace-write rooted at their result file's directory). A missing `pi`/`codex` CLI fails the dispatch with exit 127 naming it. `dispatch-agent.sh` and `dispatch-codex-agent.sh` are deleted from source and registry, and `install.sh --update` removes them from installs; preflight no longer looks for a dispatcher or an agent file.
- `crew-afk`: on claude and copilot every role is dispatched through `orchestrator/lib/adapters/` with its prompt rendered from `agents/<role>/protocol.md` (`{{FRAGMENT:…}}` expanded, a missing one fails the dispatch before spawning); no `.claude/agents/` or `.github/agents/` file is read, and copilot's committed-agent preflight check is gone. claude gets the protocol via `--append-system-prompt-file` and the coder `--disallowedTools Agent`; an argv prompt over 128 KiB fails instead of being truncated.
- `crew-reviewer`, `crew-afk`: every review finding carries `issue` (what is wrong) beside `criterion` (what the fix must achieve). Findings triage sees both, `issue` first, and `post-findings.sh` posts `issue` before `criterion` with triage's verdict and rationale; the PR's separate "Dismissed by triage" section is gone. A finding already posted under the old format is not posted again.
- `crew-triage`, `crew-afk`: crew-afk's findings triage answers only `actionable` or `debatable` — auto has no human to confirm a dismissal, so a doubted finding goes to the coder's premise check. A `dismiss` returned anyway is recorded as `actionable` (rationale notes the remap); the ADR / protected-path rules still force Debatable. `/crew-address-findings` keeps all three verdicts.
- `crew-afk`: `--poll-interval <seconds>` (default 30, `0` = off) — idle slots poll the tracker for issues made ready mid-run (one listing per interval), lint them first and block a bad one for the run only.
- `crew-afk`: a resumed feature branch that lacks `origin/<default>` (its earlier work was squash-merged) gets it merged in once per run, before the baseline, by `sync-feature-branch.sh`. Registry version / CHANGELOG-append conflicts are auto-resolved; any other conflict aborts the merge and stops the run. No `origin` or no fetch skips silently; `--no-sync-main` opts out and `--dry-run` only reports.
- `to-issues`: step 4 states the per-slice overhead and a first-match-wins edge rule (consumes / same meaning → `Blocked by`; same small file within 8 criteria → merge; else parallel); step 3 applies it, and the quiz lists each edge/merge with its reason and asks about >2 distinct seams.
- `to-issues`, `upgrade-deps`: a shared `human-issue` fragment defines the `## For a human` block, inlined where each writes a `ready-for-human` issue (Kind A / Kind B, `Check:` / `Undo:` per step).
- `to-issues` lint: `lint-issues.sh` warns when a `Status: ready-for-human` issue lacks the `## For a human` block or any of its five `###` parts, and no longer asks such issues for `## What to build` / `## Implements`. Adds the rewritten #106 as the `human/` fixture.
- `write-pr` (new skill): writes a PR title (what the change does, not a slug) and body for a human reviewer, adapted from mattpocock/skills' `pr`. It has three
  sections: Summary (the smallest pseudocode, call tree, file tree, Mermaid diagram or diff-sketch that makes the
  change clear), Evidence (before/after) and Merge Danger (one-way or two-way door, blast radius). Run it by hand as
  `/write-pr`.
- `crew-afk`: with `--open-pr`, a new `prWriter` role (plain dispatch; default timeout 10 min) follows `write-pr` over
  `base..feature` with the PRD and the review report. Its body goes at the top of crew-afk's block in the PR, above a
  checks line taken from the integration check's own record and the `Closes` lines. The PR takes the writer's title
  (else the PRD's, else the slug as before); an open PR still titled with the slug is renamed, a title a human set is kept.
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
