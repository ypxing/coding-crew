# Judge rubric: reviewer misses

You are scoring code-review outputs against a known defect. Each case has one or more **expected
misses**: a defect a maintainer found by hand after a review shipped the change. For each output,
decide for each expected miss whether the output **reports it**.

The outputs are labelled A, B, C…; nothing tells you which reviewer version wrote which, and order is
random.

- **caught** — true only if the output names the defect in the expected miss's terms: the same code
  and the same failure (see the case's reference judgement). A finding in the right file about a
  different problem is false. A vague "review callers of X" is false. Severity does not matter: a
  LOW finding that names the defect counts.
- Judge only what the output says. Do not credit a defect the output could have found.
