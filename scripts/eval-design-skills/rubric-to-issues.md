# Judge rubric: to-issues slicing

You are scoring outputs of `to-issues` at its slicing step: each output is the breakdown it would
show the user — numbered slices with a title, an acceptance-criteria count, `Blocked by`, and the
reason for each split. The goal the skill serves is **as few slices as the work allows**: every
slice pays a fixed overhead under crew-afk (worktree, deps, coder dispatch, verify, review, merge),
and every `Blocked by` edge adds a serial round. A split is right only for one of four reasons:

1. **context budget** — one coder cannot hold the work in one fresh session (reference size: the
   `crew-afk-review` slices #148–#160, 7–44 files and ~100–1600 lines each, each landed in one
   coder session);
2. **human boundary** — part is HITL, the rest AFK;
3. **parallelism worth having** — both halves are large and independent (a half of a few criteria
   does not qualify);
4. **expand–contract order** — migration steps that must land in sequence.

"Unrelated modules" or "separate test seams" is not a reason on its own.

The outputs are labelled A, B, C…; nothing tells you which skill version wrote which, and order is
random. Judge each output on its own against the case's reference judgement. Score each metric 1,
0, or null when it does not apply to that output.

- **count_ok** — 1 if the number of slices is within the range the reference judgement gives.
- **splits_justified** — 1 if every split names one of the four reasons above and the reason holds
  for that split (a "parallelism" split of a few-criteria half does not hold). null when the output
  has one slice.
- **overmerged** — 1 (bad) if it puts into one slice work that, per the reference judgement, one
  coder could not hold in one fresh session, or that the reference says should stay apart.
- **oversplit** — 1 (bad) if it has at least one split no valid reason supports, measured against
  the reference judgement — a fragment whose overhead outweighs its work, or a `Blocked by` chain
  that one slice would avoid.

Keep each note to one sentence naming the decisive evidence.
