---
name: afk-sprint
description: >
  Spawns coder agents to implement all ready-for-agent issues in the current repo,
  supervises until all are done, and merges work back. Trigger with /afk-sprint.
model: sonnet
tools:
  - Workflow
---

# AFK Issue Sprint — Claude Code

When invoked, call the **Workflow** tool with the following script as the `script` parameter.
Copy it verbatim — do not modify, summarise, or interpret it.

When the workflow completes, print `result.summary` verbatim as your response — do not paraphrase or omit any section, including `## Code Review`.

```javascript
{{PROTOCOL}}
```
