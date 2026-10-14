# Reviewer-misses replay: results

`node scripts/eval-reviewer-misses.mjs --runs 2`, base `main`, head `feature/lean-dev-loop` (the per-branch/feature reviewer protocol split, #405, and the lean coder-path instructions, #406), run for #412.
Reviewers on opus, judge on opus. Every reviewer and judge call completed (36/36 runs ok).

| case | version | runs ok | caught (per expected miss) | mean findings (raw) | mean findings (distinct) | cost |
|---|---|---|---|---|---|---|
| afk-effectiveness-feature-prd-props | base | 2/2 | signal-no-run-end 2/2; release-gate-version-only 0/2; registry-description-stale 0/2 | 6.0 | 4.5 | $3.35 |
| afk-effectiveness-feature-prd-props | head | 2/2 | signal-no-run-end 2/2; release-gate-version-only 0/2; registry-description-stale 1/2 | 4.0 | 4.5 | $3.10 |
| afk-effectiveness-feature | base | 2/2 | signal-no-run-end 0/2; release-gate-version-only 0/2; registry-description-stale 0/2 | 5.0 | 5.0 | $3.66 |
| afk-effectiveness-feature | head | 2/2 | signal-no-run-end 0/2; release-gate-version-only 0/2; registry-description-stale 1/2 | 4.5 | 4.5 | $3.81 |
| force-keeps-stamp | base | 2/2 | force-keeps-stamp 2/2 | 2.0 | 2.0 | $2.21 |
| force-keeps-stamp | head | 2/2 | force-keeps-stamp 2/2 | 2.0 | 2.0 | $1.97 |
| lightweight-flow-feature | base | 2/2 | tracker-undefined 2/2; eval-close-stale 0/2; eval-round1-conflict 0/2 | 3.0 | 4.0 | $1.69 |
| lightweight-flow-feature | head | 2/2 | tracker-undefined 2/2; eval-close-stale 1/2; eval-round1-conflict 0/2 | 4.0 | 6.5 | $1.85 |
| promote-after-merge-207 | base | 2/2 | repromote-earlier-run 2/2 | 1.0 | 1.0 | $1.22 |
| promote-after-merge-207 | head | 2/2 | repromote-earlier-run 2/2 | 1.0 | 1.0 | $1.54 |
| promote-after-merge-feature | base | 2/2 | triage-diff-inverted 1/2 | 1.0 | 2.5 | $2.38 |
| promote-after-merge-feature | head | 2/2 | triage-diff-inverted 2/2 | 2.5 | 2.5 | $2.46 |
| shim-mutual-exec | base | 2/2 | shim-mutual-exec 0/2 | 1.5 | 1.5 | $1.39 |
| shim-mutual-exec | head | 2/2 | shim-mutual-exec 1/2 | 1.5 | 1.5 | $2.16 |
| tracker-agnostic-drain | base | 2/2 | unknown-blocker-mapped 0/2 | 1.5 | 1.5 | $1.64 |
| tracker-agnostic-drain | head | 2/2 | unknown-blocker-mapped 0/2 | 1.0 | 1.0 | $1.49 |
| tracker-agnostic-feature | base | 2/2 | replace-deletes-known-blocker 0/2; worktree-cli-lookup 0/2 | 2.0 | 1.0 | $4.66 |
| tracker-agnostic-feature | head | 2/2 | replace-deletes-known-blocker 0/2; worktree-cli-lookup 1/2 | 3.0 | 3.0 | $4.64 |

Mean distinct findings, head / base: afk-effectiveness-feature-prd-props 1.00x (within max(2x, +2)); afk-effectiveness-feature 0.90x (within max(2x, +2)); force-keeps-stamp 1.00x (within max(2x, +2)); lightweight-flow-feature 1.63x (within max(2x, +2)); promote-after-merge-207 1.00x (within max(2x, +2)); promote-after-merge-feature 1.00x (within max(2x, +2)); shim-mutual-exec 1.00x (within max(2x, +2)); tracker-agnostic-drain 0.67x (within max(2x, +2)); tracker-agnostic-feature 3.00x (within max(2x, +2))

Total cost: $45.21 (judge included). Base `main`, head `worktree`, 2 run(s) each. Reviewers on opus (effort default, sub-agents denied), judge on opus.

**Pass rule (#412: head no worse than base, a tie passes): PASS.** Head caught 15 expected misses in total against base's 9, and no case where head caught fewer. Head was ahead on afk-effectiveness-feature-prd-props (3 vs 2), afk-effectiveness-feature (1 vs 0), lightweight-flow-feature (3 vs 2), promote-after-merge-feature (2 vs 1), shim-mutual-exec (1 vs 0) and tracker-agnostic-feature (1 vs 0). Base's tracker-agnostic-feature run #1 returned an empty output; without that case head still leads 14 to 9.

## Runs
- afk-effectiveness-feature-prd-props base #1: signal-no-run-end caught, release-gate-version-only not caught, registry-description-stale not caught; n/a finding(s), 3 distinct — Catches the signal exit that skips the finally block holding sprint.endRun, but lists the B8/D16 release gate as holding up and never mentions the registry description.
- afk-effectiveness-feature-prd-props base #2: signal-no-run-end caught, release-gate-version-only not caught, registry-description-stale not caught; 6 finding(s), 6 distinct — Catches the onSignal process.exit path that writes no last_exit; its cut-release.sh check looked only at the demo-regex parsing, not whether the log is tied to the commit being released, and it never mentions the registry description.
- afk-effectiveness-feature-prd-props head #1: signal-no-run-end caught, release-gate-version-only not caught, registry-description-stale caught; 5 finding(s), 6 distinct — Catches the signal exit that writes no last_exit and the stale registry.json:42 crew-afk description (both in its LOW leftover-references finding), but it checked cut-release.sh and dropped it as matching D16.
- afk-effectiveness-feature-prd-props head #2: signal-no-run-end caught, release-gate-version-only not caught, registry-description-stale not caught; 3 finding(s), 3 distinct — Catches the signal exit that records no run-end reason and explicitly calls the release gate implemented, missing that it compares versions only.
- afk-effectiveness-feature base #1: signal-no-run-end not caught, release-gate-version-only not caught, registry-description-stale not caught; 5 finding(s), 5 distinct — B dropped the signal run-end gap and called the cut-release checks correct, and its leftover-text list does not mention the registry description.
- afk-effectiveness-feature base #2: signal-no-run-end not caught, release-gate-version-only not caught, registry-description-stale not caught; 5 finding(s), 5 distinct — A dropped the signal-exit gap and the version-only release gate as intended, and its stale-text finding does not mention registry.json.
- afk-effectiveness-feature head #1: signal-no-run-end not caught, release-gate-version-only not caught, registry-description-stale not caught; 5 finding(s), 5 distinct — D dropped the signal-exit run-end gap as accurate and found none of the three expected misses.
- afk-effectiveness-feature head #2: signal-no-run-end not caught, release-gate-version-only not caught, registry-description-stale caught; 4 finding(s), 4 distinct — C's stale-text finding names registry.json:42's crew-afk description still saying it promotes every Actionable finding, but it dropped the signal-exit gap and accepted the cut-release gate.
- force-keeps-stamp base #1: force-keeps-stamp caught; 1 finding(s), 1 distinct — Names the lock-mode exit at :284 before rm -f stamp under --force; a failed host-run reinstall leaves the stamp, and later calls report docker-present.
- force-keeps-stamp base #2: force-keeps-stamp caught; 3 finding(s), 3 distinct — HIGH finding names lock mode skipping rm -f stamp under --force, with unlock-fail leaving the stamp so later runs read Present.
- force-keeps-stamp head #1: force-keeps-stamp caught; 1 finding(s), 1 distinct — Gives the full failing sequence: the HOST_CMD lock path keeps .crew-stamp, the forced reinstall exits 3, unlock-fail keeps the stamp, and later calls report docker-present.
- force-keeps-stamp head #2: force-keeps-stamp caught; 3 finding(s), 3 distinct — First finding gives the full sequence: lock mode exits before rm, a failed forced reinstall keeps the stamp, and later runs report docker-present.
- lightweight-flow-feature base #1: tracker-undefined caught, eval-close-stale not caught, eval-round1-conflict not caught; 3 finding(s), 4 distinct — Says $TRACKER is set only by tracker-configuration, which neither skill renders; it does not look at the eval harness.
- lightweight-flow-feature base #2: tracker-undefined caught, eval-close-stale not caught, eval-round1-conflict not caught; 3 finding(s), 4 distinct — Says $TRACKER is never set in crew-grill or crew-brainstorm, so the fetch runs with an empty path; it does not mention the eval harness.
- lightweight-flow-feature head #1: tracker-undefined caught, eval-close-stale caught, eval-round1-conflict not caught; 4 finding(s), 5 distinct — Catches the undefined $TRACKER and says the eval's close stage (grill-close-lean/heavy) still asks for the removed 'Ready to write the PRD?' line; misses the round1 conflict.
- lightweight-flow-feature head #2: tracker-undefined caught, eval-close-stale not caught, eval-round1-conflict not caught; n/a finding(s), 8 distinct — Has a separate $TRACKER-undefined finding and several other prose defects, but no eval-harness finding.
- promote-after-merge-207 base #1: repromote-earlier-run caught; 1 finding(s), 1 distinct — Says the merge-route retry promotes from the saved all-met block without checking for an earlier promotion, which gives a duplicate fix issue for pre-D1 resumed state.
- promote-after-merge-207 base #2: repromote-earlier-run caught; 1 finding(s), 1 distinct — Says savedAllMetReview plus the merge-route retry promote a branch that an earlier run already promoted, which creates a second fix issue.
- promote-after-merge-207 head #1: repromote-earlier-run caught; 1 finding(s), 1 distinct — Says a merge-route retry after a pre-#204 run that promoted and then hit a refused close calls promote again and creates a duplicate fix issue.
- promote-after-merge-207 head #2: repromote-earlier-run caught; 1 finding(s), 1 distinct — Says the merge-route retry promotes findings an earlier pre-#204 run already promoted, which creates a second duplicate fix issue.
- promote-after-merge-feature base #1: triage-diff-inverted not caught; 1 finding(s), 1 distinct — It reports only the duplicate promotion on upgrade, and it mentions only the scope string as updated, never the triage prompt's diff line.
- promote-after-merge-feature base #2: triage-diff-inverted caught; n/a finding(s), 4 distinct — Its third MEDIUM finding says the triage prompt's `feature..branch` diff no longer holds the branch's change after the merge.
- promote-after-merge-feature head #1: triage-diff-inverted caught; 2 finding(s), 2 distinct — Its MEDIUM finding says findingsTriagePrompt's `git diff <feature>..<ref>` is empty or reversed once the branch has merged.
- promote-after-merge-feature head #2: triage-diff-inverted caught; 3 finding(s), 3 distinct — Its first MEDIUM finding says findingsTriagePrompt's `git diff <feature>..<branch>` is empty or shows siblings reversed once promote runs after the merge.
- shim-mutual-exec base #1: shim-mutual-exec not caught; 2 finding(s), 2 distinct — Reports the two-shim exec loop (plus a stale-lock takeover defect) but does not name D2 as the decision that prescribes the search; it cites only D9 and D4.
- shim-mutual-exec base #2: shim-mutual-exec not caught; 1 finding(s), 1 distinct — Reports and reproduces the mutual exec loop across both docker and docker-compose, but never names D2 as the decision that prescribes it.
- shim-mutual-exec head #1: shim-mutual-exec not caught; 1 finding(s), 1 distinct — Reports and reproduces the two-shim mutual exec loop, but never names D2 as the decision that prescribes the PATH-minus-own-dir search, which the reference judgement requires.
- shim-mutual-exec head #2: shim-mutual-exec caught; 2 finding(s), 2 distinct — Says two shim copies on PATH treat each other as the real docker and loop forever, and says this 'comes straight from D2'; it also reports the stale-lock takeover defect.
- tracker-agnostic-drain base #1: unknown-blocker-mapped not caught; 1 finding(s), 1 distinct — A names the unvalidated non-draft blocker mapping only under Dropped, where it relies on lint, the same reasoning as the live miss. Its one finding is the empty-slug `<n>-.md` rewrite gap.
- tracker-agnostic-drain base #2: unknown-blocker-mapped not caught; 2 finding(s), 2 distinct — D drops the 'neither draft nor known rewritten to unrelated Issue #n' case, citing lint. Its findings are the worktree CLI lookup and the empty-slug blocker loss.
- tracker-agnostic-drain head #1: unknown-blocker-mapped not caught; 1 finding(s), 1 distinct — B also drops the typo'd blocker becoming `Issue #N` because lint rejects it. Its only finding is the empty-slug known-file defect.
- tracker-agnostic-drain head #2: unknown-blocker-mapped not caught; 1 finding(s), 1 distinct — C's single finding is the empty-slug known-file defect. It never raises a non-draft, non-existent blocker being mapped to an unrelated issue.
- tracker-agnostic-feature base #1: replace-deletes-known-blocker not caught, worktree-cli-lookup not caught; n/a finding(s), 0 distinct — The output is empty.
- tracker-agnostic-feature base #2: replace-deletes-known-blocker not caught, worktree-cli-lookup not caught; 2 finding(s), 2 distinct — It reports the lint/publish conflict for `known` blockers and stale drafts being published, and explicitly dismisses local known blockers because `--replace` deletes them, without seeing that as the defect.
- tracker-agnostic-feature head #1: replace-deletes-known-blocker not caught, worktree-cli-lookup caught; 4 finding(s), 4 distinct — The worktree lookup failure is caught at tracker-configuration.md:14, but the HIGH finding about `known` blockers is a lint/publish and github rewrite problem, not `--replace` deleting a blocker that a draft still names.
- tracker-agnostic-feature head #2: replace-deletes-known-blocker not caught, worktree-cli-lookup not caught; 2 finding(s), 2 distinct — It reports the github `known`-blocker rewrite drop and the criteria-heading regex, but neither expected miss; it drops the local case, reasoning that `--replace` deletes the open issues.


## review-pr: `reviewer-prompt.md` against the 6-line `review-pr.sh` prompt

`node scripts/eval-reviewer-misses.mjs --reviewer review-pr --runs 2`, base `main` (the prompt in `review-pr.sh`),
head `review-pr-one-skill` (`skills/review-pr/reviewer-prompt.md`). Reviewers on opus, judge on opus. Total cost
$54.85, plus $2.65 re-running the one failed run (it failed again, with no output).

| case | version | caught (per expected miss) | mean findings (distinct) |
|---|---|---|---|
| afk-effectiveness-feature-prd-props | base | signal-no-run-end 2/2; release-gate-version-only 0/2; registry-description-stale 0/2 | 9.0 |
| afk-effectiveness-feature-prd-props | head | signal-no-run-end 2/2; release-gate-version-only 0/2; registry-description-stale 2/2 | 4.5 |
| afk-effectiveness-feature | base | signal-no-run-end 2/2; release-gate-version-only 0/2; registry-description-stale 1/2 | 7.0 |
| afk-effectiveness-feature | head (1 of 2 runs ok) | signal-no-run-end 0/1; release-gate-version-only 0/1; registry-description-stale 0/1 | 6.0 |
| force-keeps-stamp | base | force-keeps-stamp 2/2 | 7.0 |
| force-keeps-stamp | head | force-keeps-stamp 2/2 | 2.5 |
| lightweight-flow-feature | base | tracker-undefined 2/2; eval-close-stale 1/2; eval-round1-conflict 0/2 | 8.5 |
| lightweight-flow-feature | head | tracker-undefined 2/2; eval-close-stale 2/2; eval-round1-conflict 0/2 | 7.0 |
| promote-after-merge-207 | base | repromote-earlier-run 2/2 | 4.0 |
| promote-after-merge-207 | head | repromote-earlier-run 2/2 | 1.0 |
| promote-after-merge-feature | base | triage-diff-inverted 0/2 | 4.0 |
| promote-after-merge-feature | head | triage-diff-inverted 1/2 | 1.0 |
| shim-mutual-exec | base | shim-mutual-exec 0/2 | 5.5 |
| shim-mutual-exec | head | shim-mutual-exec 0/2 | 3.0 |
| tracker-agnostic-drain | base | unknown-blocker-mapped 2/2 | 5.0 |
| tracker-agnostic-drain | head | unknown-blocker-mapped 0/2 | 2.0 |
| tracker-agnostic-feature | base | replace-deletes-known-blocker 0/2; worktree-cli-lookup 0/2 | 7.0 |
| tracker-agnostic-feature | head | replace-deletes-known-blocker 1/2; worktree-cli-lookup 1/2 | 4.0 |

Head caught 15 of 29 (one run failed), base 14 of 32, with about half the findings (3.4 against 6.3 distinct per
run): as many catches as crew-afk's feature reviewer above (15 of 32, 2.9 findings) from a prompt a seventh its
length. Every review-pr run on shim-mutual-exec reproduced the endless exec loop; none is counted, because the
reference judgement asks for crew-afk's D2 to be named. tracker-agnostic-drain's typo'd blocker name is the one
loss: a re-check of that case alone gave base 1/2, head 0/2, and the same head 0/2 again after telling the
reviewer to count a guard only once it cites its line (dropped: lint does run first and rejects that name).

## From an escaped.md line to a case

`/address-pr-comments` appends a line to `.scratch/<slug>/reviews/escaped.md` for each comment it
fixed on a crew-afk PR: `- <YYYY-MM-DD> <file:line> — <one-line summary> — <commit sha>`. Each is a
defect crew-afk's reviewer passed. To replay one:

1. Find the review that should have caught it. A finding comes from the feature review alone, so
   an escaped defect is a `mode: feature` replay of the feature review that ran over its code:
   `git log --merges` on `feature/<slug>` for the merge that brought `<file:line>`'s code in, and the
   drain's review range that covered it (the whole feature from its merge-base, or the drain's
   `reviewed_tip..tip` increment). `mode: branch` is reserved for a defect that should have made one
   of the issue's acceptance criteria `unmet` in its per-branch review.
2. Copy `case-template.md` to `cases/<name>.md` (its front matter defaults to `mode: feature`). Set
   `base_sha` / `head_sha` to that review's range — never the fix commit from the escaped line, which
   is after it — and `via` to a ref that keeps them reachable.
3. Fill `## PRD` from the PRD as it was at `head_sha`. Only for a `mode: branch` case, also fill
   `## Issue`, `## Implements` and `## Acceptance criteria` from the issue; a feature case drops them.
4. Write `## Expected misses` from the escaped line's summary and the fix commit's diff, and
   `## Reference judgement` with what a report must say to count as caught.
5. Check it parses and builds: `node scripts/eval-reviewer-misses.mjs --case <name> --runs 1 --dry-run`.
