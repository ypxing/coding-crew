---
name: crew-triage
description: >
  Classifies a crew-afk branch's verification failure as fixable by more code on that branch, or as
  an environment/infrastructure problem no code change can fix. Dispatched only after
  verify-worktree.sh has already failed, and only before a coder would otherwise be redispatched for
  another full attempt. Independent of the coder that wrote the branch — the same reason review is a
  separate dispatch, not a self-grade.
tools: read, bash
user-invocable: false
---

{{PROTOCOL}}
