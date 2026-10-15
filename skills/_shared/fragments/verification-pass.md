**Verification pass.** Before the design goes back to the user (`crew-grill`'s summary, `crew-brainstorm`'s final approval, or, in `to-prd`, publishing), re-check what it rests on against its source, never against memory. Necessity is not re-checked here: `crew-grill`'s and `crew-brainstorm`'s subtraction pass owns it, and `to-prd` takes it as settled by the design it was handed.

- **Facts** — for every count, `path:line`, list and "nothing else reads/does X" claim, re-run the grep, line read or command behind it and compare its output with what you said.
- **Correct** — check each decision against criterion 2 (**Correct**) of the design standard: it does what it claims against the real code, and its rationale holds. Cite the evidence (`file:line`, a command's output) either way.
- **Coherence** — check the decisions against each other: two decisions that contradict, a decision that depends on something no decision provides, and, where the skill writes `(auto)` lines (`crew-grill`), one that conflicts with an answer the user gave.

Report every change as "said X → actually Y (source)". Fix each decision built on a corrected fact before the user sees the design, and show the corrections with it, so the user sees what moved; in `to-prd`, revise each such decision in the already-written PRD before publishing it, and report the corrections to the user.

`to-prd` re-checks only what it adds beyond an already-verified summary (one `crew-grill` or `crew-brainstorm` just ran this pass on); a standalone `to-prd` re-checks everything it cites.
