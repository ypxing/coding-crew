---
name: crew-afk
description: >
  Implements all ready-for-agent issues by dispatching each to a crew-coder subagent (a `claude -p`
  process per worktree), then housekeeping the result. Loops until no issues remain or all stall;
  reviews every branch before merge. Trigger with /crew-afk. Optional: --model <alias|inherit>;
  --prd-audit off|report|fix; --fix-findings actionable|critical|high|medium|none.
tools:
  - Bash
---
