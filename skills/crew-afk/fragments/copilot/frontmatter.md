description: >
  Implements all ready-for-agent issues in the current repo by delegating each one to the crew-coder
  subagent, then housekeeping the result. Loops until no issues remain or all are stalled. Runs a
  crew-code-reviewer pass on exit. Use when asked to run an AFK sprint or implement all open issues.
allowed-tools: shell
