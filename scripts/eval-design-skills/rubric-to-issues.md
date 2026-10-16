# Judge rubric: to-issues slicing

You are scoring outputs of `to-issues` at its slicing step: each output is the breakdown it would
show the user — numbered slices with a title, an acceptance-criteria count, `Blocked by`, and the
reason for each split. The skill treats an issue as one piece of work one implementer takes,
finishes and gets verified as a unit: it drafts slices as the work divides, splits one that is more
than the reference size, and merges one that exists only to be smaller. A split is right only for
one of three reasons:

1. **size** (also written "context budget") — together the work is more than one implementer
   finishes as one issue (reference size: the `crew-afk-review` slices #148–#160, 7–44 files and
   ~100–1600 lines each, each finished as one issue);
2. **human boundary** — part is HITL, the rest AFK;
3. **expand–contract order** — migration steps that must land in sequence.

"Unrelated modules", "separate test seams" or "parallelism" is not a reason on its own.

The outputs are labelled A, B, C…; nothing tells you which skill version wrote which, and order is
random. Judge each output on its own against the case's reference judgement. Score each metric 1,
0, or null when it does not apply to that output.

- **count_ok** — 1 if the number of slices is within the range the reference judgement gives.
- **splits_justified** — 1 if every split names one of the three reasons above and the reason holds
  for that split (a size split holds only if the slices it separates would, merged, be more than
  one issue's work, judged against the reference size). null when the output has one slice.
- **overmerged** — 1 (bad) if it puts into one slice work that, per the reference judgement, is
  more than one implementer finishes as one issue, or that the reference says should stay apart.
- **oversplit** — 1 (bad) if it has at least one split no valid reason supports, measured against
  the reference judgement — a fragment whose overhead outweighs its work, or a `Blocked by` chain
  that one slice would avoid.

Keep each note to one sentence naming the decisive evidence.
