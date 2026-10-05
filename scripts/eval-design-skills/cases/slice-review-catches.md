---
skill: to-issues
stage: slice
repo_ref: 4ff2dda
---
<!-- repo_ref 4ff2dda is on main, before PRD #211's work merged. The PRD body below is frozen as published. -->
## Request
PRD #211 (below) is approved; the feature slug is `review-catches`, under `tracker: github`. Break it into issues. The PRD body, as published:

## Problem Statement

Actor: a maintainer who runs crew-afk on a PRD and wants to merge the result without running their own review first.
Origin: #210

crew-afk runs a review on each branch, an area-split feature review and a PRD audit. Even so, a plain manual review on the same model ("review the changes 1. fulfill prd 2. no bugs") still finds real bugs after the sprint. This is the second sprint in a row. #185 found 7 bugs after `crew-afk-review`. Its fix, PRD #187, added decision checks, area-split feature review and defect classes. Then `promote-after-merge` (PR #208) shipped with 2 bugs that were fixed by hand in 86c3777:

1. Promotion moved after the merge, but `findingsTriagePrompt` (`orchestrator/lib/prompts.mjs`) still showed triage `git diff <feature>..<branch>`. After the merge, that diff shows the other branches' work inverted and none of the branch's own change. The PRD changed the scope string in `promote()` and missed the diff command a few lines away. Its D9 even said `prompts.mjs` would not change. No reviewer opened the file: it was not in the diff, the planner drops paths that are not in the diff (`feature-areas.mjs:43`), and `reviewer.md:134-136` tells reviewers to skip unchanged code unless it triggers a CRITICAL.
2. Phase 2 fix issue #207 (`3a4d772`) added promotion on the merge-route retry. That retry re-promoted a branch an earlier run had already promoted before merge. The PRD's Compatibility section described exactly that state. #207 was reviewed only against its own criteria, and the feature review never runs after Phase 2 (`loop.mjs:338`).

Every crew-afk reviewer ran `claude-opus-5-5`, the same model as the manual check. The gap is what the reviewers are told to look at, and when they look. It is not model capability.

## Solution

Every change here is generic. None is tied to one repo, PRD or bug class.

- The reviewer is goal-first. It asks whether the change does what the issue and PRD intend, and what it breaks. The diff is where it starts, not where it stops.
- A PRD names, for each decision, what relies on the thing that decision changes, with citations.
- A feature review runs at every drain, not just the first, so code from Phase 2 is reviewed as part of the feature too. Findings from the post-Phase-2 review feed one more fix phase. After that, reviews only report and make the PR a draft.
- A maintainer replay eval checks that the reviewers now catch the two known misses.

## Behaviours

- **B1** — given a run whose Phase 2 merged a fix issue, a feature review runs at the Phase 2 drain over `featureReviewRange`'s increment (`reviewed_tip..tip`), at `runLoop` (`orchestrator/lib/loop.mjs`) with fake effects
- **B2** — given promotable findings from the feature review at the second drain, they become one fix issue that the next phase implements. Given promotable findings from a review at a later drain, no fix issue is created: the findings appear in the summary's `## Feature Review`, and the PR is a draft whose not-green reason names them. At `runLoop` with fake effects.
- **B3** — given an increment feature review and a PRD with `## Decisions` and `## Compatibility & Migration`, the reviewer prompt contains every decision line and the Compatibility section verbatim, at `runFeatureReview` / `featureReviewPrompt`
- **B4** — given the installed reviewer role, its protocol opens with the goal-first question and says that unchanged code whose correctness the change affects is in scope at any severity. It contains no rule limiting unchanged code to CRITICAL classes and does not present triage as a filter for the reviewer's findings. At the rendered `.coding-crew/crew-afk/roles/reviewer.md` (`tests/helpers/render.bash`).
- **B5** — given the rendered `to-prd` SKILL.md, it requires each decision that changes existing behaviour to have cited facts naming what relies on what it changes, at the rendered skill
- **B6** — given `scripts/eval-reviewer-misses.mjs --dry-run`, it lists both cases and writes each case's base and head prompts without invoking any model CLI, at the script

## Decisions

- **D1** — **Reviewer protocol, goal-first** (`orchestrator/roles/reviewer.md`).
  - A short opening sets the goal for both per-branch mode and feature mode: does the change do what the issue and PRD intend, and what does it break, wherever that code lives. The diff is where the reviewer starts, not where it stops.
  - In Precision, `:134-136` "Report … only when you are >80% confident … and unchanged code unless the new code directly triggers a CRITICAL class" becomes: report a finding that is real and locatable (`file:line`, snippet, concrete failure). Unchanged code whose correctness the change affects is in scope at any severity.
  - Step 2 item 3 (`:79-81`) widens from "call sites" to the code the change relies on or affects: its callers, what it calls, and the state it reads or writes.
  - The Pre-Report Gate, snippet rule, Common False Positives, checklists and output contract stay.
  - Why: the reviewer's attention is narrowed today, and that narrowing is the measured cause. Under the default `fixFindings: actionable`, findings triage already judges every finding.
- **D2** — **The protocol does not present triage as a safety net.** It stays silent about findings triage, apart from the existing `:234` line about the json. A reviewer that counts on a downstream filter loosens its own judgement.
- **D3** — **`to-prd`: what relies on each decision** (`skills/to-prd/SKILL.md`, the Decisions guidance).
  - For each decision that changes existing behaviour, the PRD names, as facts with `path:line`, what relies on the thing it changes: callers, callees, the state it reads or writes, and state older versions left behind.
  - The model decides how to find them.
  - A claim about existing behaviour without a citation is not a fact. This also covers #203's uncited, wrong "the retry re-reviews".
  - Why to-prd: crew-grill, crew-brainstorm and a direct `/to-prd` all write their PRD through it, so it is the one owner. Stated as a principle, not a procedure, so the model is not limited to one bug class.
- **D4** — **Feature review at every drain** (`orchestrator/lib/loop.mjs`).
  - The once-only `featureReviewed` guard (`:338-350`) becomes: at every drain where something has merged, run `runFeatureReview`.
  - `featureReviewRange` (`orchestrator/lib/pipeline/feature-review.mjs:32`) already returns `increment` from `reviewed_tip`, and returns "nothing new" when the tip equals it.
  - The existing skip rules hold at each drain: integration red, wall cap, dry run, nothing merged.
  - `state.sh feature-reviewed` keeps recording `reviewed_tip` after every review that wrote a report.
- **D5** — **Promotion cap.**
  - Feature-review findings are promoted, under the `fixFindings` rule as today, at most at the first two drains whose feature review ran. Those are the whole-feature review and the increment after Phase 2.
  - Later reviews call `runFeatureReview` with promotion off. Their findings are still written to the review report, so `post-findings.sh`, `remind` and the summary see them.
  - A finding that the `fixFindings` rule would have promoted adds a not-green reason ("feature review findings not promoted: …"). The reasons list is at `loop.mjs:626`, and `--draft` already follows from it.
  - The integration-fix cap (two per run) is unchanged and independent.
  - The loop ends when a drain flushes nothing, as it does today.
- **D6** — **The feature-review prompt carries PRD context in every mode.**
  - An increment review gets every PRD decision line. Today it gets none: `feature-review.mjs:103` passes decisions only with an `Area:`.
  - Every feature review gets the PRD's `## Compatibility & Migration` section verbatim when it exists, in its own block in `featureReviewPrompt` (`orchestrator/lib/prompts.mjs`).
  - Reading the section belongs to `orchestrator/lib/prd-decisions.mjs`, which already locates and parses the PRD (`loadPrdDecisions`). Add a sibling there (e.g. `loadPrdSection(ctx, heading)`), not a second PRD reader.
  - Per-branch reviews are unchanged.
- **D7** — **Replay eval for reviewers** (`scripts/eval-reviewer-misses.mjs`, plus `scripts/eval-reviewer-misses/cases/*.md` and `rubric.md`).
  - It is maintainer-only and ships to no consumer. It is modelled on `scripts/eval-design-skills.mjs`: `--base <ref>`, `--head <ref>|worktree`, `--case`, `--runs`, `--model`, `--judge-model`, `--parallel`, `--dry-run`. Results go to `.scratch/eval-reviewer-misses/<timestamp>/`, and it prints each run's cost.
  - For each ref it builds prompts with that ref's own modules (`featureReviewPrompt`, `reviewPrompt`, `feature-areas.mjs`, the rendered role), from a temporary worktree of the ref. It reviews the case's tree read-only.
  - A blind judge scores each output against the case's reference judgement: whether each expected miss was reported (yes/no) and how many findings there were (a noise measure).
  - Case `promote-after-merge-feature`: a feature review over `485c6b9..b221314`, replaying the planner split and one reviewer per area. It is caught if any area reports the `findingsTriagePrompt` diff.
  - Case `promote-after-merge-207`: the per-branch review of `4bcc149..3a4d772` (#207). It is caught if it reports the re-promotion of a branch that an earlier run promoted before merge.
  - Each case embeds a frozen copy of PRD #203's text.
- **D8** — `(auto)` The cases pin commit SHAs. `origin/feature/promote-after-merge` keeps them reachable, and each case file says so.
- **D9** — `(auto)` `CLAUDE.md`'s feature-review paragraph ("Not re-run after Phase 2 …") and the `loop.mjs:41-43` header comment are updated to describe D4/D5.
- **D10** — `crew-afk`'s version in `registry.json` is above origin/main's, and so is `to-prd`'s.

## Testing Decisions

- Test observable behaviour at existing seams:
  - `runLoop` with fake effects for D4/D5 (B1, B2). Prior art: `tests/orchestrator/sprint-findings-triage.test.mjs`, `sprint-integration.test.mjs`.
  - `runFeatureReview` / `featureReviewPrompt` for D6 (B3). Prior art: `sprint-feature-areas.test.mjs`, `prd-decisions.test.mjs`.
  - Rendered or installed text for D1–D3 (B4, B5) via `tests/helpers/render.bash`, never the source variants.
  - `--dry-run` for D7 (B6).
- Existing tests that assert "feature review runs once" or "not re-run after Phase 2" are updated, not deleted.
- The protocol change (D1) is measured by running D7 by hand: base `main` vs the worktree. It is never run in CI.

## Out of Scope

- A separate order/timing checklist item (#210's proposal): D1's principle covers it, and adding a class for each miss is the pattern that left these gaps.
- The planner adding files outside the diff to an area: D1 sends reviewers into the code they need to read. If D7 shows it falls short, this comes back.
- Fix issues inheriting the decision IDs their findings cite: the post-Phase-2 review sees every decision anyway (D4, D6).
- The Compatibility section in per-branch reviews: to-issues already turns it into criteria, and feature reviews get it (D6).
- A crew-grill/to-prd eval case for D3: the user chose the reviewer replay only.
- PRD audit changes: no measured miss traces to the audit alone.
- Rewriting the reviewer from a three-line prompt (dropping the checklists and false-positive guidance): thresholds other than `actionable` have no triage step, so noise would become fix issues.
- #209 (Promoted Findings shows GitHub refs as missing): an unrelated bug.

## Further Notes

- Triage is not why the bugs were missed: no reviewer raised either one. Across the `findings-triage.report.json` files under `.scratch/`, 25 of 29 findings were Actionable, 3 Debatable and 1 dismissed.
- A feature-area review cost about $0.34 in this sprint. D4 adds at most about two increment reviews per run.

## Reference judgement
~2 slices is right (the slices actually published, #212 and #213, landed as 2, both with no `Blocked by`, 11 and 7 criteria). One natural cut: (a) the reviewer protocol, the `to-prd` rule and the replay eval `scripts/eval-reviewer-misses.mjs` (D1–D3, D7, D8) — the eval exists to measure the protocol change, so they belong together; (b) the feature review at every drain, the promotion cap and the PRD context in the feature-review prompt (D4–D6, D9) in `loop.mjs`, `feature-review.mjs`, `prompts.mjs` and `prd-decisions.mjs`. Parallelism between those two halves is worth having: both are large and independent, and they need no `Blocked by` edge. 1 slice is acceptable only if it argues the whole fits one coder session — it is near the reference size's upper end, so 1–3 slices count as `count_ok`. 4 or more (for example D4, D5 and D6 each split out, or `to-prd`'s D3 alone as a few-criteria slice) is oversplit; a `Blocked by` edge between the protocol and the drain work is unjustified (neither consumes the other).
