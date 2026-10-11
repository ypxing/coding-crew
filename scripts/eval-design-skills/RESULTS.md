# Design-skill A/B: results

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
