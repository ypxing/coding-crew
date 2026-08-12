2. **Verify acceptance criteria (after checks pass, before review and merge):** dispatch
   `task(agent_type="general-purpose", prompt=...)` — not the cheap `explore` or `task` built-ins —
   to read the issue file and the branch diff and confirm every criterion in `## Acceptance criteria`
   (and `## Cross-cutting Requirements`, if present) is genuinely met; do it yourself only if that
   dispatch is rejected. A criterion is **unmet** unless you can point at the file and line that
   satisfies it: the worker's own `[x]` is a claim, not evidence. This is the gate that keeps a
   falsely-reported `complete` off the feature branch.
