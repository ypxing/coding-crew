2. **Per-branch code review (after verification passes, before the merge):** dispatch
   `crew-code-reviewer` the same way — `task(agent_type="crew-code-reviewer", prompt=...)`. It cannot
   edit, reads the diff itself, and returns the acceptance-criteria verdict together with its
   advisory findings.

   Pass to the reviewer:
   ```
   Review this branch before it merges.
   Branch: <branch>
   Slug: <slug>
   Issue file: <issue-file-path>
   Acceptance criteria:
   <criteria verbatim from the issue>

   Gather the diff: git diff $(git merge-base <feature-branch> <branch>)..<branch>
   ```

   The verdict arrives in the `AC:` line of the block the call returns — read it there, do not infer
   it. No block back, or a block with no `AC:` line, is `AC: unmet`.
