Status: ready-for-agent

## What to build

Add Step 1.5 "Validate Issue Context" to the solve-issue skill, inserted after "Read the issue" and before "Explore the codebase". This step checks if the issue has a Context Documents section, reads referenced design.md and PRD.md files from MAIN_ROOT, and keeps them in memory during implementation. Before marking an issue complete, verify both feature acceptance criteria AND cross-cutting requirements (if that section exists) are addressed.

Modify the validation logic to check all checklist items in both sections. If cross-cutting requirements exist but are unchecked, prevent completion and report which requirements are unmet.

## Acceptance criteria

- [ ] Step 1.5 added to SKILL.md after "Read the issue" step
- [ ] Logic checks for Context Documents section in issue content
- [ ] If Context Documents section exists, extract design.md and PRD.md paths
- [ ] Read design.md from MAIN_ROOT if path references it
- [ ] Read PRD.md from MAIN_ROOT if path references it
- [ ] If neither doc exists or Context Documents section missing, continue normally (graceful degradation)
- [ ] Before marking complete, validate feature acceptance criteria [x]/[ ]
- [ ] Before marking complete, validate cross-cutting requirements [x]/[ ] if that section exists
- [ ] If cross-cutting requirements unchecked, prevent completion and log which are unmet
- [ ] Test with issue containing Context Documents - verify docs are read and kept in context

## Blocked by

- 01-enhance-to-issues-extraction.md (needs new issue template structure with Context Documents and Cross-cutting Requirements sections)

## Interfaces

### Consumes:

Issue files with optional sections from to-issues:
```markdown
## Context Documents
- Design: `.scratch/<slug>/design.md`
- PRD: `.scratch/<slug>/PRD.md`

## Cross-cutting Requirements
- [ ] Requirement 1
- [ ] Requirement 2
```

### Exposes:

Validation behavior that crew-coder can rely on:
- Reads design.md/PRD.md from MAIN_ROOT when referenced
- Validates all checklist sections before completion
- Returns structured output with all acceptance criteria marked
