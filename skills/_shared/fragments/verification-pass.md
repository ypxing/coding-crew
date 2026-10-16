**Verification pass.** Before the design goes back to the user, re-check what it rests on against its source, never against memory. Necessity is not re-checked here.

- **Facts** — for every count, `path:line`, list and "nothing else reads/does X" claim, re-run the grep, line read or command behind it and compare its output with what you said.
- **Correct** — check each decision against criterion 2 (**Correct**) of the design standard: it does what it claims against the real code, and its rationale holds. Cite the evidence (`file:line`, a command's output) either way.
- **Coherence** — check the decisions against each other: two that contradict, one that depends on something no decision provides, an `(auto)` line that conflicts with an answer the user gave.

Report every change as "said X → actually Y (source)". Fix each decision built on a corrected fact before the user sees the design, and show the corrections with it, so the user sees what moved.
