---
mode: feature
base_sha: fe7022af5425
head_sha: 09aeb800cf31
slug: afk-effectiveness
via: origin/feature/afk-effectiveness
---
Replay of the feature review of #250 (afk-effectiveness): the whole feature diff `fe7022af5425..09aeb800cf31`,
split into areas by the planner, one reviewer per area. The SHAs are reachable through
`origin/feature/afk-effectiveness`; fetch it before running if they do not resolve.
Escaped (`.scratch/afk-effectiveness/reviews/escaped.md`, all three fixed in `7128c49`):
`orchestrator/main.mjs:602` (D14), `scripts/cut-release.sh:101` (D16), `registry.json:42` (D2–D4).

## Expected misses

- signal-no-run-end: A run ended by SIGINT, SIGTERM or SIGHUP after run-start records no run-end reason: `onSignal` in `orchestrator/main.mjs` calls `process.exit` before the `finally` block that writes `last_exit`, so the next run reports the previous one as killed or crashed (D14).
- release-gate-version-only: `scripts/cut-release.sh`'s demo-smoke gate compares only the crew-afk version the log records with HEAD's, so a smoke run on uncommitted or later-changed code at the same version satisfies it (D16).
- registry-description-stale: `registry.json:42`'s crew-afk `description` still says every Actionable review finding is promoted into a second fix phase, though D2–D4 made it one fix issue of at most 8 findings from the feature review.

## Reference judgement

signal-no-run-end: D14 says `state.sh run-end` is "called on every orchestrator exit path". In `orchestrator/main.mjs` the run-end reason is written only in `main()`'s `finally`; `onSignal` (`:601`) kills the process groups, releases the lease and calls `process.exit`, so no `finally` runs. The next `run-start` then logs "previous run ended without an exit (killed or crashed)" for a plain Ctrl-C. Caught only if a finding says a signal exit after run-start writes no run-end / `last_exit` reason; a finding about the summary's wording is not it.

release-gate-version-only: `scripts/cut-release.sh` (`:98-108`) accepts a demo log when its `crew-afk-version:` equals HEAD's `registry.json` version. The version is only bumped per milestone, so a smoke run on a dirty tree, or on a commit that later code changed, still passes the gate and the release ships untested code. Caught only if a finding says the gate does not tie the log to the commit (or tree) being released; a finding about the version comparison's parsing is not it.

registry-description-stale: the leftover-reference class. D2–D4 changed promotion to one findings fix issue per feature, at most 8 findings, from the feature review only; `registry.json:42`, a file the diff does not touch, still describes the old behaviour, and it is what `install.sh` and the README skills table show. Caught only if a finding names the registry's crew-afk description (any severity, in any area).

## PRD

### Problem Statement

Actor: the maintainer who runs crew-afk sprints and reviews the PRs they open.
Origin: #182

crew-afk lands well-sliced issues, but its review produces more follow-up work than it removes, and nothing measures what it misses. In the last 7 sprints with promotion (`.scratch/*/sprint-state.json`, `dispatch/`), 34 work issues produced 40 auto-promoted findings fix issues: 29 from per-issue reviews, 11 from feature reviews. Review cost $62 against $56 for coding. Per-issue findings never gate a merge (`orchestrator/roles/reviewer.md:9-10`), and the feature review raises them again (#233 and #234 hold the same two findings). Many promoted items are edge cases or polish: CommonMark fence indentation (#220), a log line's grammar spread over three fix issues for one parent (#169, #170, #173), file mode bits (#245).

The per-issue criteria gate does earn its place. 16 `criteria-unmet` verdicts on 10 issues caught about 7 real gaps before merge. The other ~8 were retries on criteria no unattended coder can meet: #154 (measured wall time) and #212 (`RESULTS.md` from a paid eval).

Meanwhile:
- The PRD audit, the only check for a PRD requirement no issue carried, skipped 30 times and ran 13. Most skips were caused by open findings fix issues (`orchestrator/lib/loop.mjs:435-439`).
- 4 of the last 5 multi-issue feature PRs (#196, #208, #219, #235) needed a review pass after crew-afk finished, and nothing recorded what that pass caught.
- crew-afk has been tested almost only by building crew-afk.
- 17 of 66 sessions left no exit record, and restarts aren't counted.

### Solution

- **Review:** per-issue review becomes a criteria-and-PRD-decisions gate with no findings. Findings come only from the feature review, and **one fix issue per feature** carries them: at most 8, ordered by severity. Every other open finding goes to the PR, and the summary points to `/address-pr-comments`. Findings triage judges #239's "Necessary" criterion, so edge-case findings nobody hits stay Debatable.
- **PRD audit:** it stops waiting on findings fix issues.
- **Measurement:**
  - `/address-pr-comments` records what crew-afk missed.
  - Each run records why it ended.
  - A public Python demo repo gives a repeatable sprint outside this repo, required before a release tag, with each release's result logged.

### Behaviours

- **B1** — given a branch whose criteria are all met, the per-issue review writes `findings: []`, and no fix issue is created for that branch, at `orchestrator/lib/pipeline/review.mjs` (sprint lifecycle test).
- **B2** — given a feature whose first feature review has 11 promotable findings, one fix issue is created with the 8 most severe, listed CRITICAL→LOW. The other 3 stay open and are posted to the PR, and a later feature review creates no second fix issue, at the crew-afk run (sprint test) and `promote-findings.sh`.
- **B3** — given a first feature review with no promotable finding, a later review that finds one still creates the feature's one fix issue, at `loop.mjs` drain handling.
- **B4** — given a finding whose failure needs an input no real caller or user produces, findings triage marks it Debatable and it is not promoted, at the rendered findings rubric (`triage.md`, crew-address-findings).
- **B5** — given open findings posted to the feature PR, the summary's Next Step says `Run: /address-pr-comments <PR>`. Given no PR, it says `Run: /crew-address-findings`, at `crew-summary.sh`.
- **B6** — given an open `Source: review` fix issue and no open work issue, the PRD audit runs, at `runPrdAudit`.
- **B7** — given `/address-pr-comments` fixing a comment on a crew-afk PR, the comment is appended to `.scratch/<slug>/reviews/escaped.md`. A comment carrying a `crew-finding:` marker is not, at the address-pr-comments skill text.
- **B8** — given `cut-release.sh` with neither `--demo-smoke <log>` nor `--no-demo-smoke "<reason>"`, it refuses to tag, at `scripts/cut-release.sh --dry-run`.

### Decisions

**Review and findings**

- **D1** — The per-issue review checks acceptance criteria and the PRD decisions the issue implements, and raises no findings. `reviewer.md`'s per-branch mode always writes `findings: []`, and Step 3 (the always-on classes) applies only in Feature Mode. The orchestrator ignores any findings a per-branch report still carries. An `unmet` verdict still retains the branch for its coder (unchanged).
  - Relies on it:
    - The intro promises findings per branch (`reviewer.md:9-10`).
    - On `unmet`, findings return to the worker (`reviewer.md:250-252`).
    - The output schema (`reviewer.md:232-245`, `prompts.mjs:254-273` `reviewPrompt` at `:195`).
    - Earlier branch findings are carried forward in `review.mjs:148-156`.
- **D2** — Findings come only from the feature review (`orchestrator/lib/pipeline/feature-review.mjs`), which keeps every drain, areas and triage unchanged.
- **D3** — One findings fix issue per feature. `FEATURE_REVIEW_PROMOTIONS` goes from 2 to 1 (`loop.mjs:615`). The counter advances only when a fix issue was created (`review.promotedRef`), not when the review had findings (`loop.mjs:353` today: `if (review.findings && promote)`). The `--slug` second-promotion branch (`feature-review.mjs:316-317`) goes away. Integration-check fixes (`integration-fix.mjs`) and PRD-gap fixes (`defer-gaps`) remain separate kinds.
  - Relies on it: `state.sh feature-review-promoted` (`state.sh:316-321`), `promotions` read at `state.sh:373`, and `reportOnlyFeatureFindings` (`feature-review.mjs:192`) feeding the not-green reasons (`loop.mjs:617-619`).
- **D4** — The fix issue holds at most 8 findings. Promotable findings are sorted CRITICAL→LOW (stable), the first 8 go to `criteriaFile` (`prompts.mjs:561`), and the rest are marked `report_only` via `markReportOnly` (`feature-review.mjs:230-235`). They then stay open for `post-findings.sh` and the summary. The sort applies to every `criteriaFile` caller.
- **D5** — `skills/_shared/fragments/findings-rubric.md` gains a hard rule: a finding is Debatable when its failure needs an input or state that no current caller, user or documented contract produces ("Necessary", #239 criterion 1). It's rendered into `orchestrator/roles/triage.md` and `skills/crew-address-findings/SKILL.md`, and `tests/findings-rubric-shared.bats` asserts every line. Placed after #242's design-standard rule.
- **D6** — `crew-summary.sh:370-375`: when findings were posted (`POSTED_TO` set), print `Run: /address-pr-comments <PR url>`. Otherwise keep `Run: /crew-address-findings`. This depends on posting, not on the tracker. `/address-pr-comments` already reads review bodies and inline comments (`skills/address-pr-comments/SKILL.md:81-87`).
- **D7** — to-issues (`skills/to-issues/SKILL.md`, the acceptance-criteria rule near `:135`) gains one sentence: a criterion that needs a paid run, a manual measurement or a person isn't an acceptance criterion. It goes to the PRD's human steps or a `ready-for-human` issue. There's no linter heuristic.
- **D8** — `runPrdAudit` (`loop.mjs:431-439`) excludes issues whose body has `Source: review` from `unfinishedIssues` (`loop.mjs:415`). Integration and PRD-gap fix issues also carry `Source:` lines (`promote-findings.sh:416`, `:511`) and are excluded too, since none of them carries a PRD requirement.
- **D9** — Remove what D1 orphans, checking for remaining callers first:
  - per-branch `promote()` (`review.mjs:210-270`) and its two call sites (`pipeline.mjs:714`, `:918`);
  - `promote-findings.sh guard` (`:160-200`), whose only caller is `review.mjs:213`;
  - carrying branch findings forward (`review.mjs:148-156`);
  - the merge-route "already promoted" lookup (`review.mjs:177-190`).
  - **Kept**, because the feature review uses them: `carryFindings` (`feature-review.mjs:224`), `foldDuplicates` (`findings-triage.mjs:74`), `report_only` (`feature-review.mjs:230-235`), `selectPromotable`.
- **D10** — An existing `feature_review.promotions` of 1 or more reads as capped. Branch findings left open in earlier reports are never promoted: `promote-findings.sh open` still lists them, so they're posted or reminded.
- **D11** — The criteria-only check stays the `reviewer` role. There's no new role, and models are still set per role in `afk.models`.

**Measurement**

- **D12** — Escaped-defect record. In `/address-pr-comments` Step 5/6 (`SKILL.md:139-176`): when the PR body contains `<!-- crew-afk:begin -->` (`open-pr.sh:59`) and the head is `feature/<slug>`, each comment that was accepted and fixed is appended to `.scratch/<slug>/reviews/escaped.md` as one line: `- <date> <file:line> — <comment summary> — <commit sha>`. Comments containing `crew-finding:` (`post-findings.sh:64`) are skipped. Writing the file is best-effort and never fails the skill. The record is local, since `.scratch/` is gitignored (`.gitignore:8`).
- **D13** — Review focus. `scripts/eval-reviewer-misses/` gains a case template, plus a `RESULTS.md` note on turning an `escaped.md` entry into a replay case. Reviewer prompts change only after a case shows a miss.
- **D14** — Run end reasons. A new `state.sh run-end --reason <text> --code <n>` writes `last_exit {run, reason, code, at}` to `sprint-state.json`, called on every orchestrator exit path. At `run-start` (`state.sh:270-278`), a `current_run` with no matching `last_exit` logs `previous run ended without an exit (killed or crashed)`. The summary adds `Run <n> for this feature; previous: <reason>`.
- **D15** — Public demo repo: a new GitHub repo (Python, uv, pytest, ruff, mypy) with a short PRD and 3 issues written by `/crew-grill` in that repo, one issue blocked by another, local tracker. `scripts/smoke-sprint/demo/` holds `repo` (URL), `sha` (pinned) and the `.scratch/<slug>/` copy. `smoke-sprint.sh --demo` (flag parsing at `:38-42`) clones at the SHA, copies the issues in, runs crew-afk and checks:
  - exit 0;
  - every issue done;
  - the project's own checks pass on the feature branch.
- **D16** — Release gate. `cut-release.sh` (preconditions `:14-25`) refuses to tag unless given `--demo-smoke <log>` (a `SMOKE: PASS` log whose recorded crew-afk version equals HEAD's `registry.json` crew-afk version) or `--no-demo-smoke "<reason>"`. A real run appends `| version | date | pass/fail | cost | dispatch-hours | findings |` to `scripts/smoke-sprint/RESULTS.md`.
- **D17** — Stop rule. This repo's `CLAUDE.md` ("Working in this repo") says a crew-afk mechanism change cites how many times its incident happened (logs or tracker).
- **D18** — `MILESTONE-PUSH-SKIPPED` (`log.mjs:37`, emitted at `pipeline/shared.mjs:112`) logs at warn once per run, then at debug.

**Coordination**

- **D19** — #242 (design-only findings at LOW) targets Feature Mode, not per-branch review. This feature's reviewer and rubric issues are blocked by #240 and #242.
- **D20** — The version invariant applies to every entry whose shipped text changes: crew-afk, to-issues, address-pr-comments and crew-address-findings (rubric). Each entry's version must be above origin/main's.

### Compatibility & Migration

The per-branch review report keeps its schema (`findings` is present, always `[]`). Sprint state migrates in place: `feature_review.promotions` of 1 or more reads as capped (D10), and `last_exit` is new and optional. Open branch findings already in `.scratch/<slug>/reviews/sprint-review-*.md` reports are kept and never promoted. `cut-release.sh` gains a required flag, which is maintainer-only and ships to no consumer.

### Testing Decisions

- Test observable behaviour at the highest seam: the orchestrator sprint suites (`tests/orchestrator/sprint-*.test.mjs`) for B1–B3 and B6, and bats against rendered output (`tests/helpers/render.bash`) for B4, B5 and B7. Prior art:
  - `tests/findings-rubric-shared.bats` for the rubric line;
  - the existing promotion-cap tests from #238 for D3;
  - `tests/crew-summary*.bats` for D6.
- D9's removals: the tests asserting per-branch promotion and the depth guard are deleted or rewritten to assert that no promotion happens. `git grep` shows no remaining callers.
- D15/D16: `smoke-sprint.sh --demo --setup-only` and `cut-release.sh --dry-run` are tested without API cost. A paid demo run is the maintainer's job (human step).

### Out of Scope

- **Dropping the later report-only feature reviews:** they're the only findings review Phase 2 code and later commits get.
- **A linter heuristic for criteria a coder can't meet unattended:** it's a judgement call, so a regex would misfire (D7).
- **product-services or any private repo as the demo:** it's internal, and coding-crew is public.
- **A scheduled recurring smoke run:** crew-afk changes only through releases, which the gate already covers.
- **A smoke run of the design skills:** they're interactive, and `eval-design-skills.mjs` covers them.
- **A cheaper model or a separate role for the criteria check:** `afk.models` already allows a cheaper model.
- **Capping runs per feature:** D14 only records them.
- **Removing read-only snapshots or fingerprint restart:** not tied to this design. Filed as a `needs-design` follow-up.
- **Changes to baseline, integration, lint or conflict dispatch:** each changed outcomes in the logs.

### Further Notes

- **Human steps:**
  1. Create the public demo repo.
  2. Run `/crew-grill` in it.
  3. Pin the SHA and copy its `.scratch/<slug>/` into `scripts/smoke-sprint/demo/`.
  4. Run the first paid demo smoke.

  D15's issue lists these under `## Requires`.
- Close #182 when this ships (part 1 is D3/D4; part 2 was covered by #215).
- Facts: the sprint counts come from `../coding-crew/.scratch/*/sprint-state.json` and the orchestrator logs, as of 2026-10-05.

