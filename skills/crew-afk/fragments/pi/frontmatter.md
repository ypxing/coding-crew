description: >
  Implements all ready-for-agent issues in the current repo by dispatching each one to a crew-coder
  subagent (a separate pi process in an isolated git worktree), then housekeeping the result. Loops
  until no issues remain or all are stalled. Reviews every branch before it merges. Use when asked
  to run an AFK sprint or implement all open issues.
  Optional: --model <alias|inherit> to override the coder's default model; --coverage for a PRD
  coverage report; --promote critical-high to promote HIGH review findings as well as CRITICAL.
