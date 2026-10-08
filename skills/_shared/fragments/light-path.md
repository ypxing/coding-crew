### Light path: is the source already one complete change?

Before any question, judge the source — the issue (`node "$TRACKER" fetch <ref> --comments`) or the user's message. Four checks; answer each with evidence, a quote from the source or a `file:line`:

1. **Problem** — the source states the problem with its cost or evidence.
2. **One slice** — one vertical slice looks likely.
3. **Criteria** — acceptance criteria are testable, or derivable from the code.
4. **No fork** — no open fork in Gate 2's "annoyed" lane remains.

All four hold: print one line, `Light path: <reason per check>`, then invoke `to-issues` with the ref (if any) and the facts gathered. Ask no question, write no summary, run no verification pass: `to-issues` grounds every assumption.

Any check fails: print one line naming it, then continue with the Q&A below. Never ask the user whether to take the light path.
