## Problem Statement

The current "to-issues → crew-afk" workflow suffers from coverage gaps that cause incomplete implementations. When design.md and PRD.md are broken down into vertical slice issues, important cross-cutting concerns (error handling, security, logging, performance targets) get lost. crew-coder agents implement from issue content alone without consulting design.md or PRD.md for architectural context. After all issues complete, there's no verification that merged code actually covers all design.md/PRD.md requirements. This results in implementations that miss interface contracts, multi-issue flows, and cross-cutting requirements.

## Solution

Implement a three-phase hybrid approach that ensures requirements flow from design → issues → implementation → verification:

1. **Enhanced Issue Creation** — to-issues extracts cross-cutting requirements from design.md/PRD.md and adds them as explicit checklists in each issue. Issues also get Context Documents references and Part of Flow annotations for multi-issue operations.

2. **Context-Aware Implementation** — crew-coder automatically reads design.md and PRD.md from MAIN_ROOT before implementing. solve-issue validates both feature acceptance criteria AND cross-cutting requirements before marking complete.

3. **Coverage Validation** — crew-afk adds a validation step at exit that extracts all requirements from design.md/PRD.md, compares against completed issues and merged code, and generates a coverage report (✓ covered / ⚠ partial / ✗ missing).

The workflow degrades gracefully when design.md doesn't exist (crew-grill flow produces only PRD.md).

## Key User Stories

1. As a developer using to-issues, I want cross-cutting requirements from design.md automatically extracted into issue checklists, so that error handling, security, and performance concerns aren't forgotten during implementation.

2. As a crew-coder agent, I want to automatically read design.md and PRD.md before implementing an issue, so that I have full architectural context and don't make decisions that conflict with the overall design.

3. As a developer running crew-afk, I want a coverage report at sprint exit that shows which design.md/PRD.md requirements are covered, partially covered, or missing, so that I can verify completeness before considering the feature done.

4. As a developer using crew-grill (no design.md), I want the workflow to still extract requirements from PRD.md and provide basic coverage validation, so that I get some protection even without a full design document.

5. As a crew-coder agent implementing part of a multi-issue flow, I want the issue to tell me which upstream and downstream steps exist, so that I implement interfaces compatible with adjacent issues being built in parallel.

## Decisions

### Modified Components

**skills/to-issues/SKILL.md** (version 1.2.0 → 1.3.0)
- Enhanced issue template with three new optional sections:
  - `## Context Documents` — references to design.md and PRD.md (included only if they exist)
  - `## Cross-cutting Requirements` — checklist extracted from design.md/PRD.md (included only if requirements apply to this issue)
  - `## Part of Flow` — multi-issue flow annotation (included only if issue is part of end-to-end operation)
- Cross-cutting requirements extraction logic that scans design.md for 10 categories: error handling, logging, security, performance, testing, architecture constraints, data validation, observability, interfaces & contracts, multi-issue flows
- Fallback extraction from PRD.md `## Decisions` section when design.md doesn't exist
- Mapping logic to determine which cross-cutting requirements apply to each vertical slice based on what layers/components it touches

**agents/crew-coder/claude.agent.md** (version 1.0.0 → 1.1.0)
- New step after environment setup: "Read Context Documents"
- Extracts feature slug from issue path, checks for design.md and PRD.md in `$MAIN_ROOT/.scratch/<slug>/`
- Reads whichever docs exist and keeps in context during implementation

**skills/solve-issue/SKILL.md** (version 1.0.0 → 1.1.0)
- New Step 1.5: "Validate Issue Context" (after "Read the issue", before "Explore the codebase")
- Checks for `## Context Documents` section in issue
- Reads referenced design.md/PRD.md from MAIN_ROOT if present
- Before marking complete, verifies both feature acceptance criteria AND cross-cutting requirements (if section exists)
- Structured output `acceptance_criteria` field now includes both sections with [x]/[ ] markers

**skills/crew-afk/SKILL.md** (version 1.0.0 → 1.1.0)
- New exit step: "Coverage validation" inserted between "Code review" and "Branch cleanup"
- Extracts feature slug from current branch, checks for design.md/PRD.md
- Skips validation if neither doc exists (prints: "Coverage validation: skipped")
- Spawns haiku validation agent with prompt to extract all requirements and compare against completed issues/merged code
- Validation agent generates report with three categories: ✓ covered / ⚠ partial / ✗ missing
- Summary format updated to include coverage report section before per-issue details

### Cross-cutting Requirements Categories

Ten categories extracted from design.md (or PRD.md as fallback):

1. **Error Handling** — how errors are caught, logged, propagated
2. **Logging** — what to log, format, levels  
3. **Security** — auth checks, input validation, sensitive data handling
4. **Performance** — response time targets, resource limits
5. **Testing** — test coverage requirements, types of tests needed
6. **Architecture Constraints** — patterns to follow, libraries to use, interfaces to respect
7. **Data Validation** — schema constraints, input sanitization rules
8. **Observability** — metrics, tracing, monitoring hooks
9. **Interfaces & Contracts** — API contracts, function signatures, data structures, event schemas that multiple issues must agree on
10. **Multi-Issue Flows** — end-to-end operations spanning multiple vertical slices (auth flows, data pipelines, request/response cycles)

### Extraction Strategy

**From design.md (preferred):**
- Scan for explicit section headings: `## Error Handling`, `## Security`, `## Performance`, etc.
- Look for decision statements with "must", "should", "all", "every" (signals cross-cutting rules)
- Extract interface definitions from component interaction descriptions
- Identify multi-step flows from flow diagrams or sequence descriptions

**From PRD.md (fallback when no design.md):**
- Scan `## Decisions` section for statements with "must", "should", "all", "every"
- Look for security, performance, testing mentions
- Extract technical constraints that apply broadly

**Mapping to issues:**
- API layer issues → apply API-related requirements, input validation, security
- User input handling → apply security, validation, error handling
- Database access → apply performance, error handling, retry logic
- Multi-component flows → apply interface contracts, flow sequence requirements

### Issue Template Structure

```markdown
Status: ready-for-agent

## Context Documents
[Only if design.md or PRD.md exist]
- Design: `.scratch/<slug>/design.md`
- PRD: `.scratch/<slug>/PRD.md`

## What to build
[Existing: concise description]

## Acceptance criteria
[Existing: feature-specific checklist]

## Cross-cutting Requirements
[Only if extracted requirements apply]
- [ ] [Error handling requirement]
- [ ] [Security requirement]
...

## Part of Flow
[Only if part of multi-issue flow]
This issue implements [step] of the [flow name] flow.
**Upstream:** [previous step]
**Downstream:** [next step]

## Blocked by
[Existing]

## Interfaces
[Existing: only for issues with dependencies]
```

All new sections are optional — only included when relevant data exists.

### crew-coder Context Reading

```bash
# After environment setup, before solve-issue
ISSUE_PATH="[provided by caller]"
FEATURE_SLUG=$(echo "$ISSUE_PATH" | sed 's|.*\.scratch/||' | sed 's|/.*||')

DESIGN_DOC="$MAIN_ROOT/.scratch/$FEATURE_SLUG/design.md"
PRD_DOC="$MAIN_ROOT/.scratch/$FEATURE_SLUG/PRD.md"

if [ -f "$DESIGN_DOC" ]; then
  echo "Reading design.md for architectural context..."
  # Read with cat or Read tool
fi

if [ -f "$PRD_DOC" ]; then
  echo "Reading PRD.md for requirements context..."
  # Read with cat or Read tool
fi
```

### crew-afk Coverage Validation

```bash
# After code review, before branch cleanup
FEATURE_SLUG=$(git rev-parse --abbrev-ref HEAD | sed 's|.*/||' | sed 's|-[0-9][0-9]-.*||')
DESIGN_DOC=".scratch/$FEATURE_SLUG/design.md"
PRD_DOC=".scratch/$FEATURE_SLUG/PRD.md"

if [ ! -f "$DESIGN_DOC" ] && [ ! -f "$PRD_DOC" ]; then
  echo "Coverage validation: skipped (no design.md or PRD.md found)"
else
  # Spawn haiku validation agent
fi
```

**Validation agent prompt:**
```
Read design.md and/or PRD.md from .scratch/<slug>/ and extract all requirements:
- Key User Stories, Technical decisions, Cross-cutting concerns
- Interface contracts, Multi-issue flows

For each requirement, check:
1. Is it covered by completed issue acceptance criteria in .scratch/<slug>/issues/done/?
2. Is there evidence in merged code?

Generate report:
✓ Covered — requirement addressed in issues and code
⚠ Partial — mentioned in issues but implementation unclear
✗ Missing — no evidence in issues or code
```

### Testing Seams

1. **to-issues skill** — Invoke with sample design.md/PRD.md, verify generated issues have expected sections
2. **solve-issue skill** — Invoke with issue containing Context Documents, verify design.md/PRD.md are read
3. **crew-coder agent** — Invoke with issue containing cross-cutting requirements, verify structured output includes all checklists
4. **crew-afk skill** — Full sprint run with design.md/PRD.md, verify coverage report in final summary

### Edge Cases

1. **Malformed context docs** — Log warning, continue without cross-cutting requirements
2. **Conflicting requirements** — design.md takes precedence over PRD.md
3. **No applicable cross-cutting requirements** — Omit section, proceed normally
4. **Coverage validation finds gaps** — Report is advisory only, does not block sprint completion
5. **Partial issues with cross-cutting requirements** — Notes go to `## Progress`, issue stays open
6. **Large design.md/PRD.md** — Read first N tokens, log truncation warning
7. **Missing design.md (crew-grill flow)** — Extract from PRD.md only, graceful degradation

### File Changes

- `skills/to-issues/SKILL.md` — 1.2.0 → 1.3.0
- `agents/crew-coder/claude.agent.md` — 1.0.0 → 1.1.0
- `skills/solve-issue/SKILL.md` — 1.0.0 → 1.1.0
- `skills/crew-afk/SKILL.md` — 1.0.0 → 1.1.0
- `registry.json` — version bumps
- `CHANGELOG.md` — v1.7.0 entry

## Out of Scope

- Changes to to-prd skill (not part of coverage flow)
- Changes to crew-brainstorm or crew-grill skills (they produce design.md/PRD.md, don't consume)
- Copilot platform support for crew-afk (claude-only currently)
- Automatic remediation of coverage gaps (validation is advisory, human decides next steps)
- Visual diagrams or UI for coverage reports (text-only output)
- Coverage tracking across multiple sprints (per-sprint validation only)
- Integration with external issue trackers (local markdown only)
