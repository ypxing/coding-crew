2. **Verify acceptance criteria (after checks pass, before review and merge):** spawn a regular
   (non-cheap) agent — or do it yourself in this session if no agent is available — to read the
   issue file and the branch diff and confirm every criterion in `## Acceptance criteria` (and
   `## Cross-cutting Requirements`, if present) is genuinely met. Treat a criterion as **unmet**
   unless you can point at the file and line that satisfies it; the worker's own `[x]` is a claim,
   not evidence. This is a correctness gate and must not run on a cheap tier — run it here, before
   the merge, so a falsely-reported `complete` never lands on the feature branch.
