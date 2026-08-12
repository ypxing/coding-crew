3. **Per-branch code review (after both verification gates pass, before merge):** dispatch
   `crew-code-reviewer` the same way — `task(agent_type="crew-code-reviewer", prompt=...)` — to review
   this branch's diff before it merges. The reviewer cannot edit and does not block the merge:
   findings are advisory.

   Pass to the reviewer:
   ```
   Review this branch before it merges.
   Branch: <branch>
   Slug: <slug>
   Acceptance criteria:
   <criteria verbatim from the issue>

   Gather the diff: git diff $(git merge-base <feature-branch> <branch>)..<branch>
   ```
