---
name: crew-afk
description: >
  Implements all ready-for-agent issues by dispatching each to a crew-coder subagent (a separate
  `codex exec` process per worktree), then housekeeping the result. Loops until no issues remain or
  all stall; reviews every branch before merge. Optional: --model <alias|inherit>; --prd-audit
  off|report|fix; --fix-findings actionable|critical|high|medium|none.
---
