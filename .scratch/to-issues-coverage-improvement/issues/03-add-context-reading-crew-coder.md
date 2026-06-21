Status: ready-for-agent

## What to build

Add a "Read Context Documents" step to the crew-coder agent, positioned after environment setup and before solve-issue invocation. This step extracts the feature slug from the issue path, checks for design.md and PRD.md in `$MAIN_ROOT/.scratch/<slug>/`, and reads whichever documents exist. The agent keeps these docs in context during the entire implementation.

Modify the structured output to ensure the acceptance_criteria field includes both feature acceptance criteria AND cross-cutting requirements (if present) with [x]/[ ] markers for each item.

## Acceptance criteria

- [ ] New step "Read Context Documents" added to claude.agent.md after environment setup
- [ ] Logic extracts feature slug from issue path using sed pattern: `echo "$ISSUE_PATH" | sed 's|.*\.scratch/||' | sed 's|/.*||'`
- [ ] Checks for design.md at `$MAIN_ROOT/.scratch/$FEATURE_SLUG/design.md`
- [ ] Checks for PRD.md at `$MAIN_ROOT/.scratch/$FEATURE_SLUG/PRD.md`
- [ ] Reads design.md if it exists, logs "Reading design.md for architectural context..."
- [ ] Reads PRD.md if it exists, logs "Reading PRD.md for requirements context..."
- [ ] If neither exists, continues normally without error (graceful degradation)
- [ ] Structured output acceptance_criteria field includes both feature criteria and cross-cutting requirements sections
- [ ] Test with issue referencing design.md/PRD.md - verify both are read and kept in context

## Blocked by

- 02-add-context-validation-solve-issue.md (needs solve-issue context validation working first)

## Interfaces

### Consumes:

From solve-issue (#02):
- Context validation behavior that reads design.md/PRD.md from MAIN_ROOT
- Validation of both acceptance criteria and cross-cutting requirements

### Exposes:

For crew-afk (#04):
- Structured output with acceptance_criteria field containing both sections:
```json
{
  "acceptance_criteria": "## Acceptance criteria\n- [x] Feature criterion\n\n## Cross-cutting Requirements\n- [x] Error handling requirement",
  ...
}
```
