---
mode: branch
base_sha: <sha the reviewed range starts at — the feature branch before the issue's merge>
head_sha: <sha the reviewed range ends at — the branch tip the reviewer passed>
slug: <feature slug>
via: <ref the SHAs are reachable through, e.g. origin/feature/<slug>>
---
Replay of <the review that missed it: the per-branch review of #<n>, or the feature review>, range
`<base_sha>..<head_sha>`. Escaped: `<the escaped.md line, verbatim>`.

Copy this file to `cases/<name>.md` (outside `cases/` it is never run). For `mode: feature` drop
`## Issue`, `## Implements` and `## Acceptance criteria`.

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
