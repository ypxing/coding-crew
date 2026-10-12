Verify this branch before it merges.
Review assets: <review-assets>
Branch: <branch>
Slug: <slug>
Issue file: <issue-file>
PRD: <prd>
Acceptance criteria:
---
<criteria>
---

Gather the diff: git diff <before>..HEAD

Checks already run by the pipeline in this branch's worktree: <checks>.
Treat that as the evidence for any criterion whose only outstanding part is that a
check passes — do not report a criterion unmet because you could not execute it
yourself. A check reported `not_run` is not evidence of anything. Everything else is
still judged from the diff: no file and line, no evidence, `unmet`. A criterion about a
figure a check produces (a coverage percentage) is judged from that check's full output
file, when one is given — read it; `pass` alone does not prove the figure. The coder's
progress notes, commit messages and the issue's `## Progress` section are claims, not
evidence, however specific.

On `unmet`, `cause` is `environment` only when the diff would meet the criterion but the
run lacked a precondition (a service unreachable, a credential absent, so its tests
skipped): that stops the issue for a human, since no code change can help. Else `code`.

A per-branch review writes `findings: []`: it is the criteria gate, and nothing more. A defect you
notice outside the criteria goes in `notes`, never in prose: solve-feature posts it in the PR review's body
and hands it to the whole-feature verify.
Each note is `{"location": "<path>:<line>", "concern": "<input or state → bad outcome>"}`.

Write your structured verdict to <report> as your last action. This file is the
only thing that gates the merge, so get it exactly right:

```json
{
  "branch": "<branch-name>",
  "slug": "<slug>",
  "verdict": "all-met | unmet",
  "detail": "<which criterion, and why — required on unmet>",
  "cause": "code | environment — on unmet only",
  "findings": [],
  "notes": []
}
```

Start your final message with `## Branch: <branch-name>`, for the human reading the transcript.
Nothing in it is parsed, so do not repeat the object there.
