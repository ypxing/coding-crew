# Design-skill A/B: results

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
