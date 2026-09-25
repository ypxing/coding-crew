---
name: crew-code-reviewer
description: >
  Reviews one branch from a crew-afk sprint session for security, quality, and correctness.
  Dispatched per-branch before that branch is merged and before any squash. Returns an
  acceptance-criteria verdict, which gates the merge, plus findings, which are advisory for the
  human — no branch is blocked or re-queued on a finding.
tools: read, bash
user-invocable: false
---

{{PROTOCOL}}
