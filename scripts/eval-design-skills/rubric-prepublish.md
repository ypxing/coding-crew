# Judge rubric: to-issues before publishing

You are scoring outputs of `to-issues` at step 6, after the drafts passed the linter and before
`publish-issues`: each output is what the skill would ask the user or change in the drafts before
publishing. The goal the skill serves is **an issue a coder can build from without guessing**. The
coder dispatched later reads the issue and the code but cannot ask the writer, so an omission or
ambiguity that changes what gets built, or how a criterion is checked, is a gap worth raising now.
Asking about anything else costs the user's attention for nothing: wording, what the issue rightly
leaves to the coder, and what a sensible coder could decide without changing what gets built.

The outputs are labelled A, B, C…; nothing tells you which skill version wrote which, and order is
random. Judge each output on its own against the case's reference judgement, which names the gap
the drafts contain and what is minor or already answered. Score each metric 1, 0, or null when it
does not apply to that output.

- **gap_raised** — 1 if the output raises the gap the reference judgement names, as a question to
  the user or as a change to a draft that closes it, specific enough that acting on it fixes the
  draft. 0 if it does not, or only gestures at it ("check the criteria are complete").
- **noise** — 1 (bad) if the output asks the user something the reference judgement calls minor or
  already answered, or asks about wording or something the draft rightly leaves to the coder. A
  minor point the output settles itself, without asking, is not noise.

Keep each note to one sentence naming the decisive evidence.
