# Design-skill A/B: results

## crew-grill, crew-brainstorm, to-issues — #697 (multi-repo design, PR #698)

`node scripts/eval-design-skills.mjs --skill all --runs 2 --base origin/main`, base `origin/main` (`d1aeb7a2`), head the PR #698 worktree. crew-grill and crew-brainstorm below are from that run (head `c725df7a`, $11.00 for all three skills). Its to-issues tables showed one single-repo run keeping two slices apart for a "repo boundary-like scope" (slice-crew-afk-review head #1), so the repo-boundary reason was narrowed to features spanning several repos (`fb1424d2`) and to-issues was re-run alone (`--skill to-issues`, $4.08); its tables below replace the first run's. Subjects on sonnet, judge on opus; every run ok.

| case | version | n | sized | do_least | asked_well | overbuilt | underbuilt | false_cut | chain_priced | cost |
|---|---|---|---|---|---|---|---|---|---|---|
| brainstorm-gitlab | base | 2 | 2/2 | 2/2 | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.30 |
| brainstorm-gitlab | head | 2 | 2/2 | 2/2 | 2/2 | 1/2 | 0/2 | n/a | n/a | $0.30 |
| brainstorm-merge-conflicts | base | 2 | 0/2 | 0/2 | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.26 |
| brainstorm-merge-conflicts | head | 2 | 0/2 | 1/2 | 1/2 | 0/2 | 0/2 | n/a | n/a | $0.16 |
| brainstorm-new-platform | base | 2 | 2/2 | 2/2 | 1/2 | 0/2 | 0/2 | n/a | n/a | $0.19 |
| brainstorm-new-platform | head | 2 | 2/2 | 2/2 | 0/2 | 0/2 | 0/2 | n/a | n/a | $0.17 |
| brainstorm-scratch-cleanup | head | 2 | 2/2 | 2/2 | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.20 |
| brainstorm-scratch-cleanup | base | 2 | 2/2 | 2/2 | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.16 |
| brainstorm-vague-ask | base | 2 | 2/2 | 1/2 | 1/2 | 0/2 | 0/2 | n/a | n/a | $0.23 |
| brainstorm-vague-ask | head | 2 | 1/2 | 2/2 | 1/2 | 0/2 | 0/2 | n/a | n/a | $0.14 |

Higher is better: sized, do_least, asked_well, chain_priced. Lower is better: overbuilt, underbuilt, false_cut. n/a = not applicable to that output.

| case | version | n | sized | do_least | asked_well | overbuilt | underbuilt | false_cut | chain_priced | cost |
|---|---|---|---|---|---|---|---|---|---|---|
| grill-close-heavy | base | 2 | 1/2 | 1/2 | n/a | 0/2 | 0/2 | 0/2 | 1/2 | $0.26 |
| grill-close-heavy | head | 2 | 2/2 | 0/2 | n/a | 0/2 | 0/2 | 0/2 | 0/2 | $0.18 |
| grill-close-lean | base | 2 | 2/2 | 2/2 | n/a | 0/2 | 0/2 | 0/2 | n/a | $0.16 |
| grill-close-lean | head | 2 | 2/2 | 2/2 | n/a | 0/2 | 0/2 | 0/2 | n/a | $0.16 |
| grill-gitlab | base | 2 | 2/2 | 2/2 | 2/2 | 1/2 | 0/2 | n/a | n/a | $0.23 |
| grill-gitlab | head | 2 | 2/2 | 1/2 | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.24 |
| grill-light-issue | head | 2 | 2/2 | n/a | 1/2 | 0/2 | 0/2 | n/a | n/a | $0.21 |
| grill-light-issue | base | 2 | 2/2 | n/a | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.19 |
| grill-merge-conflicts | head | 2 | 0/2 | 2/2 | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.21 |
| grill-merge-conflicts | base | 2 | 0/2 | 2/2 | 1/2 | 2/2 | 0/2 | n/a | n/a | $0.20 |
| grill-new-platform | base | 2 | 2/2 | 1/2 | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.23 |
| grill-new-platform | head | 2 | 2/2 | 2/2 | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.24 |
| grill-scratch-cleanup | head | 2 | 2/2 | 2/2 | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.19 |
| grill-scratch-cleanup | base | 2 | 2/2 | 2/2 | 2/2 | 0/2 | 0/2 | n/a | n/a | $0.19 |

Higher is better: sized, do_least, asked_well, chain_priced. Lower is better: overbuilt, underbuilt, false_cut. n/a = not applicable to that output.

| case | version | n | gap_raised | noise | cost |
|---|---|---|---|---|---|
| prepublish-tracker-wrappers | head | 2 | 1/2 | 2/2 | $0.35 |
| prepublish-tracker-wrappers | base | 2 | 0/2 | 2/2 | $0.33 |

Higher is better: gap_raised. Lower is better: noise. n/a = not applicable to that output.

| case | version | n | count_ok | splits_justified | overmerged | oversplit | hitl_placed | cost |
|---|---|---|---|---|---|---|---|---|
| slice-agent-agnostic-install | head | 2 | 2/2 | 2/2 | 1/2 | 0/2 | 2/2 | $0.20 |
| slice-agent-agnostic-install | base | 2 | 2/2 | 1/2 | 2/2 | 1/2 | 2/2 | $0.22 |
| slice-crew-afk-review | base | 2 | 2/2 | 1/2 | 2/2 | 0/2 | n/a | $0.31 |
| slice-crew-afk-review | head | 2 | 2/2 | 1/2 | 1/2 | 1/2 | n/a | $0.22 |
| slice-promote-after-merge | base | 2 | 1/2 | 0/2 | 0/2 | 1/2 | n/a | $0.21 |
| slice-promote-after-merge | head | 2 | 2/2 | 0/1 | 0/2 | 0/2 | n/a | $0.36 |
| slice-review-catches | head | 2 | 2/2 | 2/2 | 0/2 | 1/2 | 2/2 | $0.39 |
| slice-review-catches | base | 2 | 2/2 | 2/2 | 0/2 | 0/2 | 2/2 | $0.37 |

Higher is better: count_ok, splits_justified, hitl_placed. Lower is better: overmerged, oversplit. n/a = not applicable to that output.

**Totals.** brainstorm: base sized 8/10, do_least 7/10, asked_well 8/10, overbuilt 0/10; head 7/10, 9/10, 6/10, 1/10. grill: base sized 11/14, do_least 10/12, asked_well 9/10, overbuilt 3/14; head 12/14, 9/12, 9/10, 0/14. to-issues slicing (re-run): base count_ok 7/8, splits_justified 4/8, overmerged 4/8, oversplit 2/8; head 8/8, 5/7, 2/8, 2/8. No judge note names the repo boundary in the re-run.

**Where head fell below base:** brainstorm asked_well 6/10 vs 8/10 (brainstorm-new-platform 0/2 vs 1/2, both head runs re-asking a stated requirement; brainstorm-merge-conflicts 1/2 vs 2/2), and grill-close-heavy chain_priced 0/2 vs 1/2. None of these outputs involves another repo, and the multi-repo text applies only when one is named.

**Two-repo runs (#697 step 3):** run by the maintainer on two real repos (field-repo-a, field-repo-b), installed from the branch. Both passed: inside field-repo-a naming the other by folder name, and from their parent folder naming both.

**Verdict (#697):** ship.

## to-issues — #546

`node scripts/eval-design-skills.mjs --skill to-issues --runs 2`, base `main` (`8585b9dc`), head `crew-afk/pr-body-for-humans` (`9a1dc66d`, PR #619: each HITL slice placed first or last, last ones numbered after the AFK slices, #545).
Subjects on sonnet, judge on opus. Every subject and judge call completed (20/20 runs ok). New case `slice-agent-agnostic-install` and the `hitl_placed` metric come from #545; base and head get the same slice-stage instruction.

| case | version | n | gap_raised | noise | cost |
|---|---|---|---|---|---|
| prepublish-tracker-wrappers | head | 2 | 1/2 | 2/2 | $0.39 |
| prepublish-tracker-wrappers | base | 2 | 1/2 | 2/2 | $0.39 |

Higher is better: gap_raised. Lower is better: noise. n/a = not applicable to that output.

| case | version | n | count_ok | splits_justified | overmerged | oversplit | hitl_placed | cost |
|---|---|---|---|---|---|---|---|---|
| slice-agent-agnostic-install | base | 2 | 2/2 | 0/2 | 2/2 | 0/2 | 0/2 | $0.22 |
| slice-agent-agnostic-install | head | 2 | 1/2 | 1/2 | 0/2 | 1/2 | 2/2 | $0.33 |
| slice-crew-afk-review | base | 2 | 2/2 | 2/2 | 0/2 | 0/2 | 1/1 | $0.46 |
| slice-crew-afk-review | head | 2 | 2/2 | 2/2 | 0/2 | 0/2 | 1/1 | $0.29 |
| slice-promote-after-merge | head | 2 | 2/2 | 0/2 | 0/2 | 2/2 | n/a | $0.21 |
| slice-promote-after-merge | base | 2 | 2/2 | 0/1 | 0/2 | 1/2 | n/a | $0.20 |
| slice-review-catches | head | 2 | 0/2 | 0/2 | 0/2 | 2/2 | n/a | $0.21 |
| slice-review-catches | base | 2 | 1/2 | 1/2 | 0/2 | 1/2 | 1/1 | $0.21 |

Higher is better: count_ok, splits_justified, hitl_placed. Lower is better: overmerged, oversplit. n/a = not applicable to that output.

Total cost: $4.10 (judge included)

**hitl_placed:** head 2/2 on `slice-agent-agnostic-install` (the smoke run last, no AFK slice waiting on it), base 0/2 (both block the README slice on the smoke run).

**Where head fell below base:** count_ok 1/2 vs 2/2 and oversplit 1/2 vs 0/2 on slice-agent-agnostic-install (head #1 gave the smoke `--via npx` switch its own slice; base's 2/2 count came with 2/2 overmerged); oversplit 2/2 vs 1/2 on slice-promote-after-merge and slice-review-catches, and count_ok 0/2 vs 1/2 and splits_justified 0/2 vs 1/2 on slice-review-catches. Not plausibly caused by #545: every oversplit head run on those two cases is all-AFK, where the placement rule does not apply, and base oversplits there too (1/2 each, 0/2 in #412), so sonnet splits more than in #412 on both refs; at 2 runs a one-run gap is within noise.

**Verdict (#546): accepted as noise by the maintainer.**

## to-issues — #412

`node scripts/eval-design-skills.mjs --skill to-issues --runs 2`, base `main`, head `feature/lean-dev-loop` (the lean coder-path and planning instructions, #406).
Subjects on sonnet, judge on opus. Every subject and judge call completed (16/16 runs ok).

| case | version | n | gap_raised | noise | cost |
|---|---|---|---|---|---|
| prepublish-tracker-wrappers | head | 2 | 1/2 | 2/2 | $0.50 |
| prepublish-tracker-wrappers | base | 2 | 1/2 | 1/2 | $0.45 |

Higher is better: gap_raised. Lower is better: noise. n/a = not applicable to that output.

| case | version | n | count_ok | splits_justified | overmerged | oversplit | cost |
|---|---|---|---|---|---|---|---|
| slice-crew-afk-review | base | 2 | 1/2 | 2/2 | 1/2 | 0/2 | $0.44 |
| slice-crew-afk-review | head | 2 | 1/2 | 1/2 | 1/2 | 0/2 | $0.28 |
| slice-promote-after-merge | base | 2 | 2/2 | n/a | 0/2 | 0/2 | $0.21 |
| slice-promote-after-merge | head | 2 | 2/2 | n/a | 0/2 | 0/2 | $0.24 |
| slice-review-catches | head | 2 | 2/2 | 1/1 | 0/2 | 0/2 | $0.25 |
| slice-review-catches | base | 2 | 2/2 | n/a | 0/2 | 0/2 | $0.26 |

Higher is better: count_ok, splits_justified. Lower is better: overmerged, oversplit. n/a = not applicable to that output.

Total cost: $3.50 (judge included)

**Verdict (#412: the blind judge does not prefer base over head, a tie passes): accepted as a tie by the maintainer.** Every case ties except head being one run worse on two cells: prepublish-tracker-wrappers noise 2/2 vs 1/2 (head proposed splitting the slice) and slice-crew-afk-review splits_justified 1/2 vs 2/2 (head #1 bundled a ~200k-token slice; base #2 bundled a similar one). Neither is plausibly caused by #406, whose to-issues edit only tightened the highest-seam bullet and added one on checking prose slices; it touches neither slice sizing nor prepublish questions. At 2 runs a one-run gap is within noise.

## Notes

### #697
- brainstorm-gitlab base #1: It sizes the work from about 25 gh-calling files and six earlier GitHub leak-fix commits, prices the stay-local floor, and recommends GitLab behind the existing tracker module, asking only the hierarchy and tier question.
- brainstorm-gitlab base #2: It takes the dated need as given, prices a mirror floor, and recommends a two-slice gitlab backend behind the existing getTracker factory with a fake glab, cuts the generic forge option, and asks only about tier and the CI host.
- brainstorm-gitlab head #1: It counts 153 gh call lines across 20 files, recommends trackers/gitlab.mjs behind the existing interface in vertical slices, cuts the generic forge, and fairly challenges whether local suffices without making that the answer.
- brainstorm-gitlab head #2: Its recommendation first extracts a new forge interface and refactors 12 scripts onto it in a 'seam with GitHub parity' slice, which is the generic forge layer rewriting the working GitHub path that the reference calls overbuilt.
- brainstorm-merge-conflicts base #1: Names candidate commits but says outright that it has not measured how often conflicts happen. Its smallest option is still an automated sync before openPr, with no priced by-hand option. It adds the max-then-bump rule and asks whether conflicts appear at open time or after, recommending (1).
- brainstorm-merge-conflicts base #2: Gives no count or cost for the problem. It mentions running sync-pr-with-main.sh by hand only inside its question and never prices it. It does ask the fork only the user owns: whether stale PRs may be fixed by hand. It keeps the re-bump rule and cuts the Action.
- brainstorm-merge-conflicts head #1: Offers running the sync by hand at about 1 minute per PR as the baseline, but never measures frequency. Its one question, whether conflicts include real code, is something git history would answer.
- brainstorm-merge-conflicts head #2: Says it could not find a conflict count, and offers no by-hand or leave-it option. It does name the silent-version-loss risk, recommends a sync before openPr plus the re-bump rule, and asks a timing question with options (a)/(b)/(c) and a recommendation.
- brainstorm-new-platform base #2: Says plainly that no need is on record and prices codex as about 50 files; recommends following the seam end to end (PLATFORMS, registry, `{{PROTOCOL}}` agent files, dispatch, bats); asks only user-owned forks (auth/model default, CI scope) and defers the table refactor.
- brainstorm-new-platform head #2: Sizes the cost well from codex's six follow-up fixes, but its first question asks whether the stated requirement is needed at all, and it leaves the Gemini CLI facts unverified when it could have checked the docs.
- brainstorm-new-platform base #1: Maps the seam well and prices both the thin and dispatcher variants, but its only question (direct dispatch or bash dispatcher) is a technical fact the Gemini CLI docs could answer, not a choice the user owns.
- brainstorm-new-platform head #1: Recommends the full codex-shaped seam and puts the refactor behind a condition, but its single question asks again whether the user needs what they stated, and it skips real user forks such as auth/model and CI scope.
- brainstorm-scratch-cleanup head #1: Pins the leak to killed runs that skip the after() hooks at :52/:190 and keeps the dirs under the repo because of ensure-deps depth. It recommends an age-guarded test-scripts-* sweep in the helper, costed at about 5 lines plus one test, and asks the user-owned questions: whether that is enough and what cutoff to use.
- brainstorm-scratch-cleanup base #2: Gives the cause and the evidence (the user's 23, gitignored), rejects os.tmpdir() citing sprint.mjs:38-43, and recommends a roughly 5-line age-guarded sweep. It asks what "automatically" means and whether 1 hour is a safe threshold.
- brainstorm-scratch-cleanup head #2: Offers deleting by hand as the baseline and recommends an age-guarded sweep of only test-scripts-* in sprint.mjs. It cuts a generic .scratch pruner and a config knob, and asks about the cutoff and whether the leak is limited to tests.
- brainstorm-scratch-cleanup base #1: Sizes the problem as disk clutter from killed runs and recommends a roughly 5-line age-guarded sweep limited to the test-scripts- prefix. It prices signal handlers and a standalone script as larger options and asks whether option 1 is enough.
- brainstorm-vague-ask base #2: It sizes the problem from git history and a cited bug, but it never checks the tracker, its smallest option is a bug fix rather than leaving the installer alone, and it prints a line about the light path, which the reference counts as a miss.
- brainstorm-vague-ask head #1: It sizes the problem from commit counts and a tracker search that found no open installer issue, leads with a change-nothing option, keeps quiet about the light path, and asks one question with options and a recommendation.
- brainstorm-vague-ask head #2: It announces that the light path doesn't apply, admits it skipped the tracker, and asks the user to size the problem in Q&A instead of offering approaches with stated assumptions.
- brainstorm-vague-ask base #1: It sizes the problem from git history and the tracker (#514, #536, nothing open naming a defect), states its assumptions, offers change-nothing as option 1, and asks a single question with options and a recommendation.
- grill-close-heavy base #1: A cites 4 of 4 hand-merges as its rationale but never states their few-minutes cost. It keeps the whole Action chain without pricing it against the CI check plus re-bump plus hand-run script.
- grill-close-heavy head #2: B states four hand-merges of a few minutes each and keeps the re-bump, CI check and shared helper. Its subtraction pass only folds the dedup into the label skip and never prices the Action chain against the do-least option.
- grill-close-heavy base #2: C's subtraction pass names the do-least option (hand-merge or a script-only sync), lists the Action chain's parts priced once, and keeps the chain because the user chose it, which matches the reference.
- grill-close-heavy head #1: D sizes the problem as a few minutes per merge over four merges and keeps every required invariant, but has no subtraction pass pricing the Action chain against the smaller alternative.
- grill-close-lean base #1: It keeps all four justified pieces and states the size (one open PR, four past merges of a few minutes each); its only flaw is minor: the cut list includes alternatives nobody proposed, such as the PAT and the merge queue.
- grill-close-lean head #2: It keeps the check, re-bump, shared helper and hand-run script, prices the one real cut (workflow/bot) against the few-minute cost, and lists the rest under Out of Scope.
- grill-close-lean base #2: It is lean and sized (four hand merges at a few minutes each), keeps all justified pieces, and correctly lists labels and automation under Out of Scope, not as cuts.
- grill-close-lean head #1: It cuts only the automated sync, with its cited cost, and gives a reason for keeping each remaining piece (check, helper, script), so nothing is overbuilt or underbuilt.
- grill-gitlab base #1: Says there is no usage data, so the user's stated move sets the size. Offers 'stay local, MR only' with its cost but recommends the full backend. Moves the host calls behind the existing tracker seam instead of adding a new layer.
- grill-gitlab head #2: Takes the dated GitLab move as the cost. Offers do-least options on scope and on the seam, with costs. Routes the gh calls through the existing tracker CLI and leaves address-pr-comments and CI out of scope.
- grill-gitlab head #1: Measures the gh call sites and keeps the named scope, but declares a per-host seam for every script 'justified' without offering the smaller option or its cost.
- grill-gitlab base #2: Recommends a new 'code host' seam that refactors gh behind it, and puts porting address-pr-comments into the slice plan although nobody asked for it.
- grill-light-issue head #1: It asks nothing and shows with code and test citations (install.sh:324/486, tests/install.bats:151) that #347 already prunes unshipped files, so there is nothing to grill or build; its plain to-dos are re-run, report or close.
- grill-light-issue base #1: It checks that both acceptance criteria already hold through #347 (prune_unwritten, tests :151–216) and asks only the user's decision (close as fixed?), with options and a recommendation; it does not reopen minimal vs structural.
- grill-light-issue base #2: It asks no questions, cites the missing retired_files and prune_unwritten with the L151 test, and says why it does not hand off to to-issues; it adds the caveat that --update needs a version bump.
- grill-light-issue head #2: It correctly finds the issue already fixed by #346/#347, but then adds a question about deleting files users added, which it admits nothing in the issue asks for, so it pads a round that should have no questions.
- grill-merge-conflicts head #1: It asks the user to size the problem without citing any count of past conflicts, but it offers the manual script as the do-least option with its cost and recommends the cross-milestone re-bump plus a pre-open sync, deferring the Action.
- grill-merge-conflicts base #1: It catches the silent version loss correctly, but in Q3 it recommends the coder conflict-fix route plus re-verify on every sync with no evidence that it is needed.
- grill-merge-conflicts head #2: It promises a `gh` count but never runs it, so the problem is unsized; still, it asks the version rule directly, recommends aborting rather than a coder route, and keeps the Action conditional on evidence.
- grill-merge-conflicts base #2: It guesses the user's answer to the frequency question ("several per week") to justify automation, and it recommends routing unresolved conflicts to a coder.
- grill-new-platform base #2: It sizes the problem from the repo (no issue, commit or request mentions Gemini) and follows the platform seam end to end, but none of its build-size choices offers leaving it or doing it by hand.
- grill-new-platform base #1: Q1 prices docs-only, install-only and full support against the roughly 10-file codex precedent without relitigating the request, and the sandbox question is one the user owns.
- grill-new-platform head #1: It offers do nothing, skills-only and full platform with the codex footprint of about 730 lines, treats the request as given, and asks the user-owned sandbox question.
- grill-new-platform head #2: It cites the missing demand data, offers do nothing via orca, a plain CLI branch or full codex parity with their costs, and asks the user-owned auth and release-gate questions while leaving Gemini's flags to research.
- grill-scratch-cleanup head #2: It finds the two mkdtemp creators and their after() hooks, rules out os.tmpdir via the ensure-deps comment, and relies on the user's count of 23. It offers deleting by hand with its cost and recommends an age-guarded sweep of test-scripts-* only, with its own threshold question.
- grill-scratch-cleanup head #1: It ties the leaks to runs killed before after() fires, gives the cost of deleting by hand, keeps the sweep to test-scripts-* inside the helper, and asks only about the threshold, which the user owns.
- grill-scratch-cleanup base #1: It lists options smallest first, from doing nothing to a general pruner, and rejects os.tmpdir and the generic GC with reasons. It asks the user how runs usually die and recommends against adding a SIGINT handler.
- grill-scratch-cleanup base #2: It calls the problem dev-only clutter from aborted runs and offers doing nothing as option (d). It recommends a 5-line age-gated sweep limited to test-scripts-*, which is safe for parallel shards, and asks only about the threshold.
- prepublish-tracker-wrappers head #1: A only suggests splitting the refusal tests out of criterion 11 and never says its list misses the frozen replay files, and it asks the user to confirm the slice stays one issue, which the approved breakdown already settled.
- prepublish-tracker-wrappers head #2: B says criterion 11's closed list cannot be met, names scripts/eval-reviewer-misses/cases/tracker-agnostic-feature.md among the omitted files and asks for the real set to be listed (a borderline 1, since it misses the drain case and never says the replays are frozen), but it also asks whether session-init should hard-fail, which criterion 5 already answers.
- prepublish-tracker-wrappers base #1: C names tracker-agnostic-drain.md only for the leftover environment variables under criterion 10, not for criterion 11's file list, and its one question asks the user to confirm the already-approved single slice.
- prepublish-tracker-wrappers base #2: D proposes an expand–contract split with a Blocked-by edge, which counts as noise, and for criterion 11 it only says to drop the file list, never naming the omitted replay files.
- slice-agent-agnostic-install head #2: Four slices match the published split (render first, then install.sh Blocked by it, docs, and a last smoke run Blocked by the npx switch); each split gives size or human boundary, and no AFK slice waits on the smoke run.
- slice-agent-agnostic-install head #1: Three slices is in range, but slice 1 puts the renderer with its lib copies together with the install.sh rewrite and its goldens, which the reference says is well past one issue's size.
- slice-agent-agnostic-install base #2: Slice 1 merges the render, the lib copies, the install.sh rewrite, the migration and the goldens into one issue (D2–D7), which the reference counts as overmerged, even though the smoke slice is placed correctly last.
- slice-agent-agnostic-install base #1: Slice 1 merges the render with the install.sh rewrite, while the roughly 60-line smoke-script switch is split into its own slice on a weak size claim and a 'different test seam', so the output is both overmerged and oversplit.
- slice-crew-afk-review base #2: Slice 1 puts the draft rule, integration skipped, the wall-clock cap, process groups and config-dir env vars into one 12-criteria issue, where the reference expects three separate slices, though the other splits are reasonable size splits.
- slice-crew-afk-review head #2: Its 12 slices closely match the reference shape: separate fix/cut and speed slices, the cap, and adapters and guard blocked by the fix/cut work, with every split given a size reason that holds.
- slice-crew-afk-review base #1: Slice 1 merges the draft rule, cap, process groups and env vars into one 10-criteria issue, and the claim that D10 plus D19 would exceed the reference size does not hold for roughly 9 files and 150 lines.
- slice-crew-afk-review head #1: S7 puts all four adapters together with the removal of agent files, dispatchers and shims in one slice, which the reference calls overmerged; S4/S5 cite expand–contract for what is not a migration, and S1/S2/S3 are kept apart even though the output itself says they should merge.
- slice-promote-after-merge base #2: Three slices separated only by an 'edge rule', which is not one of the four reasons, plus a Blocked by chain the reference calls unjustified; the output itself says each merged pair stays within the reference size.
- slice-promote-after-merge head #2: Two unblocked slices match the reference cut, but the size split rests on an estimate of over 500 merged lines, and the reference says the combined work is well inside one issue.
- slice-promote-after-merge head #1: One slice with 12 criteria and no split, which is the answer the reference prefers because the merged work is well inside the reference size.
- slice-promote-after-merge base #1: The two-slice cut with no edges matches the reference, but the size split cites about 420 merged lines, which by its own figure is below the 500-line largest issue and so is not a valid size reason.
- slice-review-catches head #2: Three slices, with no Blocked-by edge between the AFK pair; the size split holds because the whole is near the upper end, though the cut separates the eval from the protocol it measures, where the reference keeps them together; the HITL eval run is last and blocks nothing.
- slice-review-catches base #1: Three slices: D1–D6 and D9 in one, the eval split off on size with no edge (it uses each ref's own modules), and a final HITL slice that no AFK slice depends on.
- slice-review-catches head #1: Slice 2 (eval) is Blocked by slice 1 because of a featureReviewPrompt signature change, but the eval builds prompts from each ref's own modules, so the edge is an unjustified chain.
- slice-review-catches base #2: Three slices: the eval is split off on size with no edge, the HITL validation comes last and nothing depends on it, and every ID is covered.

### #546
- prepublish-tracker-wrappers head #2: It raises only `tracker-agnostic-feature.md`, and only in the context of the `CREW_GITHUB_TRACKER_CLI` env-var criterion; it leaves out the drain replay and never says the files must be listed or left unedited for criterion 11, and it asks the user to confirm the issue stays one slice.
- prepublish-tracker-wrappers base #1: Its list of files missing from the allow-list never names the `scripts/eval-reviewer-misses/cases/*` replays, and it proposes splitting the issue with a `Blocked by` edge.
- prepublish-tracker-wrappers base #2: It names both `tracker-agnostic-{feature,drain}.md` replays as missing from criterion 11's list and says they probably should keep the name, but it also asks to split along the install/caller boundary with a `Blocked by` edge.
- prepublish-tracker-wrappers head #1: It names both replay case files as absent from criterion 11's allowed list and asks whether they must stay verbatim or be added, but it also questions the lookup order, which criterion 3 already settles, and asks whether the issue stays one slice.
- slice-agent-agnostic-install base #1: Slice 1 puts the render with its lib copies and the install.sh rewrite with its goldens into one issue, and the README slice is Blocked by the HITL smoke slice and justified by a 'human boundary' that sits between two AFK slices.
- slice-agent-agnostic-install head #2: After its in-line revisions, the final breakdown has four slices (render; install.sh with the --via npx switch; wording and README; smoke run as the last HITL slice, Blocked by 2), and no AFK slice waits on the smoke run.
- slice-agent-agnostic-install head #1: Five slices: the ~60-line smoke --via npx switch is its own slice with no valid reason (the output itself says it could merge into slice 2), though the HITL smoke slice is correctly last.
- slice-agent-agnostic-install base #2: Slice 1 merges the render and the install.sh rewrite (about 45 files), and the README slice is Blocked by the HITL smoke run and justified by a human boundary that does not hold.
- slice-crew-afk-review base #2: It has 8 slices, and each split gives merged-size arithmetic above the reference; the largest slice, #7 (pi and codex adapters plus agent-file and shim removal, about 500 lines), stays inside one issue and does not carry all four adapters plus the guard.
- slice-crew-afk-review head #2: It has 9 slices with size splits and an expand–contract contract step (slice 8 is blocked by the adapters and the guard), and the HITL real-CLI smoke slice comes last, blocked by 8, with no AFK slice waiting on it.
- slice-crew-afk-review head #1: It has 10 slices: the adapters are split claude / copilot+pi / codex on size, and slice 10 removes agent files after all adapters; slice 2 bundles the launchers with every fix/cut item (12 criteria, about 450 lines, mostly deletions) but stays near the reference size.
- slice-crew-afk-review base #1: It has 11 slices, splitting each adapter on size with a contract step blocked by 5–9, and the real-CLI HITL slice is last with nothing blocked by it; the 1→2→3 Blocked-by chain is debatable but rests on consumed statuses, and merging the three would exceed one issue.
- slice-promote-after-merge head #1: It splits on size, saying the merge would be "well past the reference size", but its own estimates (<100 + 250–350 lines, ~14 files) sit inside it, and it also says "Split reason: none", contradicting itself.
- slice-promote-after-merge head #2: Its size split rests on an inflated merged total of ~17 files and 750 lines, while the reference puts the combined ~14 criteria over a handful of files, well inside one issue.
- slice-promote-after-merge base #1: A single slice of about 15 files and 450 lines, with no edge, which matches the reference's preferred answer that the two parts fit in one issue.
- slice-promote-after-merge base #2: It keeps the slices apart "on size" while putting the merged total at ~290 lines, which the reference size does not reach, though it does offer to merge them.
- slice-review-catches head #2: Four slices: it admits D6 has no valid reason to be apart from D4/D5 yet keeps them split with an unjustified Blocked-by edge, and it splits the eval from the protocol it measures.
- slice-review-catches head #1: Four slices: to-prd's D3 is split out as a 3-criteria slice with an admitted non-size reason, and the eval is Blocked by the protocol slice through an edge the reference calls unjustified.
- slice-review-catches base #2: Three slices: the size split holds because the whole is near the upper end, though it cuts the eval away from the protocol rather than at the reference cut, and the HITL-last paid eval run comes after both AFK slices and blocks neither.
- slice-review-catches base #1: Four slices: D6 is split from D4/D5 on a reason it calls weak, and the protocol slice has 'none' as its split reason; even the revised 3-slice proposal keeps D6 apart from the drain work.

### #412
- prepublish-tracker-wrappers head #2: Item 1 names the eval-reviewer-misses cases as missing from the allowlist and says to extend the list, but item 6 proposes splitting the slice, which the reference counts as noise.
- prepublish-tracker-wrappers base #2: Item 1 names both tracker-agnostic eval case files, asks whether they are frozen snapshots and proposes whitelisting the cases directory, but item 2 raises the retired-scripts shape, which the reference calls minor.
- prepublish-tracker-wrappers base #1: The allowlist finding names only the tracker-config fixtures and platform-golden install files, never the eval-reviewer-misses replays, and its questions avoid the minor points the reference lists.
- prepublish-tracker-wrappers head #1: The allowlist finding omits the eval-reviewer-misses cases, and the output raises the cli.mjs lookup order and a slice split, both of which the reference calls noise.
- slice-crew-afk-review base #2: A has only 6 slices, and its slice 5 puts all four adapters, prompt assembly and the agent-file, dispatcher and shim removal into one coder session, which the reference says no coder can hold.
- slice-crew-afk-review head #2: B's 11 slices follow the expected shape: the read-only guard and the agent-file removal are separate slices, and the cap, tree cache, concurrent baseline and suite parallelisation each have their own slice.
- slice-crew-afk-review base #1: C has 10 slices that closely match the reference: adapters are split into claude/copilot then pi/codex, the guard and launchers are separate, and agent-file removal is blocked by the migration it depends on.
- slice-crew-afk-review head #1: D has 7 slices, and its slice 7 bundles all adapters, the guard, agent-file and shim removal and the launchers at about 200k tokens; it also gives 'none' or a few-criteria 'parallelism' as split reasons for slices 1 and 3.
- slice-promote-after-merge base #1: One slice with 11 criteria covering D1–D10/B1–B6, and it correctly says the ordering half is too small for a parallelism split, which matches the reference's preferred merge.
- slice-promote-after-merge base #2: One slice with 10 criteria, grounded in a ~50k-token context estimate that is well inside the reference size, and no Blocked-by edges.
- slice-promote-after-merge head #2: One slice with 9 criteria; it says outright that the ordering and carry halves are each too small to justify their own worktree/verify/merge overhead.
- slice-promote-after-merge head #1: One slice with 9 criteria, an estimate of ~70–90k peak context, no edges, and a note that the overhead of extra slices outweighs any parallelism gain.
- slice-review-catches head #2: A uses 1 slice and backs it with a ~90–110k-token estimate showing the work fits one coder session, which the reference accepts, though it undersizes the eval half at ~20k tokens.
- slice-review-catches base #2: B uses 1 slice with a ~110k-token fit argument and no edges, which the reference allows, though the alternative split it weighs (eval alone, 3 criteria) is not the natural cut.
- slice-review-catches head #1: C has 2 independent slices with no Blocked-by edge, and the parallelism reason holds because the eval is a large standalone script, but it groups the protocol with the drain work instead of with the eval that measures it.
- slice-review-catches base #1: D uses 1 slice with 11 criteria and a ~95k-token estimate checked against the #148–#160 reference size, which the reference accepts as a single-session argument.
