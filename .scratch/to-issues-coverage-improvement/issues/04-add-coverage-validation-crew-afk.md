Status: ready-for-agent

## What to build

Add a "Coverage validation" step to crew-afk's exit flow, positioned between "Code review" and "Branch cleanup". This step extracts the feature slug from the current branch, checks for design.md and PRD.md in `.scratch/<slug>/`, and skips validation if neither exists (prints: "Coverage validation: skipped (no design.md or PRD.md found)").

When docs exist, spawn a haiku validation agent that extracts all requirements from design.md/PRD.md, compares them against completed issue acceptance criteria in `.scratch/<slug>/issues/done/` and merged code, then generates a coverage report with three categories: ✓ covered / ⚠ partial / ✗ missing. Update the summary format to include the coverage report section before per-issue details.

## Acceptance criteria

- [ ] New exit step "Coverage validation" added to SKILL.md between "Code review" and "Branch cleanup"
- [ ] Logic extracts feature slug from branch using: `git rev-parse --abbrev-ref HEAD | sed 's|.*/||' | sed 's|-[0-9][0-9]-.*||'`
- [ ] Checks for design.md at `.scratch/$FEATURE_SLUG/design.md`
- [ ] Checks for PRD.md at `.scratch/$FEATURE_SLUG/PRD.md`
- [ ] If neither exists, prints "Coverage validation: skipped" and continues to branch cleanup
- [ ] If docs exist, spawns haiku validation agent with prompt to extract requirements and compare against issues/code
- [ ] Validation agent prompt includes: extract Key User Stories, Technical decisions, Cross-cutting concerns, Interface contracts, Multi-issue flows
- [ ] Validation agent checks each requirement against completed issue acceptance criteria in done/ directory
- [ ] Validation agent checks for evidence in merged code (heuristic validation)
- [ ] Coverage report format: `✓ N covered / ⚠ N partial / ✗ N missing` with detailed breakdown
- [ ] Summary format updated to include coverage report section before per-issue details
- [ ] Test with sprint run containing design.md/PRD.md - verify coverage report appears in final output

## Blocked by

- 01-enhance-to-issues-extraction.md (needs issues with context sections)
- 02-add-context-validation-solve-issue.md (needs solve-issue validation)
- 03-add-context-reading-crew-coder.md (needs crew-coder context reading)

## Interfaces

### Consumes:

From to-issues (#01):
- Issues with Context Documents sections referencing design.md/PRD.md
- Issues with Cross-cutting Requirements checklists

From solve-issue (#02):
- Validation that marks both feature criteria and cross-cutting requirements

From crew-coder (#03):
- Structured output with acceptance_criteria containing both sections

### Exposes:

Coverage report format for final summary:
```
## Coverage Report
✓ N requirements fully covered
⚠ N requirements partially covered  
✗ N requirements missing

### Details
✓ Error handling: API endpoints validate input (verified in issues 01, 03)
⚠ Performance: Response time target mentioned but no tests (issue 02)
✗ Logging: No structured logging implementation found
```
