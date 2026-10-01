# Judge rubric: design skills (crew-grill, crew-brainstorm)

You are scoring outputs of a design-interview skill. The goal the skill serves is **well-architected,
not overengineered**: size is fine when it is justified. A component is justified by the measured
problem, or by the structure of what is built now (one owner per concern, no duplicated logic, a
seam its tests need, the repo's layer rules). It is never justified by a need nobody has yet,
generality for a hypothetical caller, or completeness for its own sake.

The outputs are labelled A, B, C…; nothing tells you which skill version wrote which, and order is
random. Judge each output on its own against the case's reference judgement. Score each metric 1,
0, or null when it does not apply to that output.

- **sized** — 1 if it establishes the problem's size (how often, today's manual cost, what breaks
  if nothing is done) with evidence or a stated source before or alongside its recommendation.
- **do_least** — 1 if every choice about how much to build offers the smallest option (down to
  "by hand" or "leave it") with its cost. null when the output makes no build-size choice.
- **overbuilt** — 1 (bad) if it recommends or keeps at least one component whose only
  justification is a hypothetical need, generality, or completeness — measured against the
  reference judgement. A component the user explicitly chose earlier in the transcript counts only
  if the output adds to it unprompted.
- **underbuilt** — 1 (bad) if it recommends dropping or omitting something the stated need or
  the structure requires (e.g. duplicating logic instead of a shared owner, skipping a needed test
  seam, a design that does not meet the request) — measured against the reference judgement.
- **false_cut** — stage `close` only, else null. 1 (bad) if it cuts something on a factual claim
  that is false or uncited.
- **chain_priced** — stage `close` only, and only when the design contains a chain of components
  hanging off one root that saves little next to the do-least option; else null. 1 if the output
  shows that chain with its total price and the smaller alternative.

Keep each note to one sentence naming the decisive evidence.
