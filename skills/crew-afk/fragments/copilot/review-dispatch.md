3. **Per-branch code review (after both verification gates pass, before merge):** invoke `crew-code-reviewer`
   (`@crew-code-reviewer` in Copilot, or `.github/agents/crew-code-reviewer.agent.md`) to review
   this branch's diff before it merges. The reviewer has no edit capability and does not block the
   merge — findings are advisory.

   Pass to the reviewer:
   ```
   Review this branch before it merges.
   Branch: <branch>
   Slug: <slug>
   Acceptance criteria:
   <criteria verbatim from the issue>

   Gather the diff: git diff $(git merge-base <feature-branch> <branch>)..<branch>
   ```
