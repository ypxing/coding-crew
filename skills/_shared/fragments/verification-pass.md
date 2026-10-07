**Verification pass.** Before the summary (or, in `to-prd`, before publishing), re-check what the design rests on against its source, never against memory. Necessity is not re-checked here: the subtraction pass owns it.

- **Facts** — for every count, `path:line`, list and "nothing else reads/does X" claim, re-run the grep, line read or command behind it and compare its output with what you said.
- **Correct** — check each decision against criterion 2 (**Correct**) of the design standard: it does what it claims against the real code, and its rationale holds. Cite the evidence (`file:line`, a command's output) either way.
- **Coherence** — check the decisions against each other: two decisions that contradict, a decision that depends on something no decision provides, an `(auto)` line that conflicts with an answer the user gave.

Report every change as "said X → actually Y (source)". Fix each decision built on a corrected fact before the summary, and show the corrections with it, so the user sees what moved; in `to-prd`, revise each such decision in the already-written PRD before publishing it, and report the corrections to the user.

`to-prd` re-checks only what it adds beyond an already-verified summary (one `crew-grill` or `crew-brainstorm` just ran this pass on); a standalone `to-prd` re-checks everything it cites.
