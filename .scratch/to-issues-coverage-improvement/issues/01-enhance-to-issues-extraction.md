Status: ready-for-agent

## What to build

Enhance the to-issues skill to extract cross-cutting requirements from design.md and PRD.md, then embed them as explicit checklists in generated issues. Add three new optional sections to the issue template: Context Documents (references to design.md/PRD.md), Cross-cutting Requirements (extracted checklists), and Part of Flow (multi-issue flow annotations).

Implement extraction logic that scans design.md for 10 categories of cross-cutting requirements (error handling, logging, security, performance, testing, architecture constraints, data validation, observability, interfaces & contracts, multi-issue flows). Fall back to PRD.md's Decisions section when design.md doesn't exist. Map extracted requirements to vertical slices based on what layers/components each issue touches.

## Acceptance criteria

- [ ] Issue template in SKILL.md includes Context Documents section (only when design.md or PRD.md exist)
- [ ] Issue template includes Cross-cutting Requirements section with checklist format (only when requirements apply)
- [ ] Issue template includes Part of Flow section with upstream/downstream annotations (only for multi-issue flows)
- [ ] Extraction logic scans design.md for all 10 requirement categories
- [ ] Extraction logic falls back to PRD.md Decisions section when design.md missing
- [ ] Mapping logic determines which requirements apply to each issue based on layers touched (API, database, user input, etc.)
- [ ] Generated issues omit optional sections when no relevant data exists
- [ ] Test with sample design.md containing cross-cutting sections - verify extraction produces correct checklists

## Blocked by

None - can start immediately
