description: >
  Implements all ready-for-agent issues in the current repo by dispatching each one to the crew-coder
  subagent via the `task` tool, then housekeeping the result. Loops until no issues remain or all are
  stalled. Reviews every branch before it merges. Use when asked to run an AFK sprint or implement
  all open issues.
allowed-tools: shell, task
