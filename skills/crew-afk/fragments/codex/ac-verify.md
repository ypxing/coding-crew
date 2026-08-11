2. **Verify acceptance criteria (after checks pass, before review and merge):** do it yourself in
   this session (there is no dedicated verifier agent on Codex) — read the issue file and the branch
   diff and confirm every criterion in `## Acceptance criteria` (and `## Cross-cutting Requirements`,
   if present) is genuinely met. A criterion is **unmet** unless you can point at the file and line
   that satisfies it: the worker's own `[x]` is a claim, not evidence. Do not delegate this to a
   cheap tier — it is the gate that keeps a falsely-reported `complete` off the feature branch.
