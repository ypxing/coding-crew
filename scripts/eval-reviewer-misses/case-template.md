---
mode: feature
base_sha: <sha the reviewed range starts at — the feature review's base (merge-base, or the drain's reviewed_tip)>
head_sha: <sha the reviewed range ends at — the feature branch tip that review saw>
slug: <feature slug>
via: <ref the SHAs are reachable through, e.g. origin/feature/<slug>>
---
Replay of <the feature review that ran over the escaped code>, range `<base_sha>..<head_sha>`.
Escaped: `<the escaped.md line, verbatim>`.

Copy this file to `cases/<name>.md` (outside `cases/` it is never run). An escaped defect is a
`mode: feature` case: findings come from the feature review alone, so drop `## Issue`,
`## Implements` and `## Acceptance criteria`. Use `mode: branch` (the per-branch review of #<n>, its
range the feature branch before the issue's merge to the branch tip the reviewer passed) only for a
defect that should have made one of the issue's acceptance criteria `unmet`, and fill those three
sections from the issue.

## Issue`, `## Implements` and `## Acceptance criteria`.

## Issue

<issue slug or number>

## Implements

<D/B IDs from the issue's ## Implements, or empty>

## Acceptance criteria

- [ ] <the issue's criteria, verbatim>

## Expected misses

- miss-id: <the defect, stated so a judge can tell a report that names it from one that does not>

## Reference judgement

<Why it is a bug, which code (in or outside the diff) shows it, and what a report must say to count as
caught — and what does not count.>

## PRD

<A frozen copy of the PRD as it was at head_sha: decisions, behaviours, ### Compatibility & Migration.>
