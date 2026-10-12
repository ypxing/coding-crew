Feature review: review the feature diff across its issues before it ships.
Review assets: <review-assets>
Feature branch: <feature-branch>
Base: <base>
Branch: feature
Slug: feature
PRD (read it whole; the feature's intent): <prd>
<notes>

Gather the diff: git diff <base>..HEAD

Every issue's branch was already reviewed on its own diff, and the checks passed on the
branch. Look first for what only the whole diff shows, but report a defect inside one
issue's diff too, at any severity (crew-reviewer's Feature Mode). There is no issue and no acceptance
criteria: give no AC verdict, only findings.

Write your structured result to <report> as your last action. This file is the only thing
counted — nothing you print in your final message is parsed:

```json
{
  "branch": "feature",
  "slug": "feature",
  "verdict": "all-met",
  "detail": "",
  "findings": [
    {
      "severity": "CRITICAL | HIGH | MEDIUM | LOW",
      "location": "<file:line>",
      "issue": "<what is wrong, one sentence; a design-only finding starts Design standard (criterion <n>):>",
      "criterion": "<one verifiable fix criterion>"
    }
  ]
}
```

`findings` is `[]` when there are none — never omit the block itself. After writing the file, explain
each finding in your reply, anchored on a code snippet, for the human reading the report.
