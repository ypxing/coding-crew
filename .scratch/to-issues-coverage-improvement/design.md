# Design: to-issues → crew-afk Coverage Improvement

## Problem

The current "to-issues → crew-afk" workflow has coverage gaps:

1. **Vertical slices miss technical details** — when breaking down design.md/PRD.md into issues, important cross-cutting concerns (error handling, security, logging, performance) can get lost
2. **Agents lack visibility** — crew-coder agents implement from issue content alone, without consulting design.md or PRD.md for architectural context
3. **No verification** — after all issues complete, there's no check that the merged code actually covers all design.md/PRD.md requirements

This leads to incomplete implementations where cross-cutting concerns, interface contracts, and multi-issue flows are missed or ignored.

## Solution

A three-phase hybrid approach that ensures requirements flow from design → issues → implementation → verification:

**Phase 1: Enhanced Issue Creation (to-issues)**
- Extract cross-cutting requirements from design.md/PRD.md
- Add `## Context Documents`, `## Cross-cutting Requirements`, and `## Part of Flow` sections to issues
- Map requirements to specific vertical slices

**Phase 2: Context-Aware Implementation (crew-coder)**
- Automatically read design.md and PRD.md before implementing
- Validate both feature criteria AND cross-cutting requirements
- Return structured output with all checklists marked

**Phase 3: Coverage Validation (crew-afk exit)**
- Extract all requirements from design.md/PRD.md after sprint completes
- Compare against completed issues and merged code
- Generate coverage report: ✓ covered / ⚠ partial / ✗ missing

Workflow degrades gracefully when design.md doesn't exist (crew-grill flow produces only PRD.md).

## Architecture

### Components Modified

1. **skills/to-issues/SKILL.md**
   - Enhanced issue template with new optional sections
   - Cross-cutting requirements extraction logic
   - Multi-issue flow detection and annotation

2. **agents/crew-coder/claude.agent.md**
   - New step: read context documents from MAIN_ROOT before implementation
   - Pass context to solve-issue skill

3. **skills/solve-issue/SKILL.md**
   - Step 1.5: validate issue has context documents
   - Read design.md/PRD.md if referenced
   - Verify cross-cutting requirements before marking complete

4. **skills/crew-afk/SKILL.md**
   - New exit step: coverage validation (between code review and summary)
   - Spawn validation agent to compare requirements against merged code
   - Print coverage report before final summary

### Data Flow

```
design.md + PRD.md
    ↓
to-issues extracts requirements
    ↓
Issues created with:
  - Context Documents section (references)
  - Cross-cutting Requirements checklist
  - Part of Flow annotation
    ↓
crew-afk spawns crew-coder agents
    ↓
crew-coder reads design.md + PRD.md from MAIN_ROOT
    ↓
solve-issue implements with full context
    ↓
crew-coder validates all checklists
    ↓
crew-afk merges completed issues
    ↓
crew-afk validates coverage against design.md + PRD.md
    ↓
Coverage report: ✓ ⚠ ✗
```

## Cross-cutting Requirements Categories

Ten categories of requirements that apply across multiple issues:

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

## Issue Template Changes

New optional sections added to the template in `skills/to-issues/SKILL.md`:

```markdown
Status: ready-for-agent

## Context Documents

[Only if design.md or PRD.md exist]

- Design: `.scratch/<slug>/design.md`
- PRD: `.scratch/<slug>/PRD.md`

Read these documents before implementing. They contain architecture decisions, integration constraints, and technical context essential for this issue.

## What to build

[Existing: concise description of vertical slice]

## Acceptance criteria

[Existing: feature-specific checklist]

## Cross-cutting Requirements

[Only if extracted requirements apply to this issue]

Requirements from design.md/PRD.md that apply to this implementation:

- [ ] [Error handling requirement]
- [ ] [Security requirement]
- [ ] [Performance requirement]
- [ ] [etc.]

## Part of Flow

[Only if this issue is part of a multi-issue flow]

This issue implements [step description] of the [flow name] flow.

**Full flow:** [brief description or reference to design.md section]
**Upstream:** [previous step/issue]
**Downstream:** [next step/issue]

## Blocked by

[Existing: blocking issues or "None"]

## Interfaces

[Existing: only for issues with dependencies]
```

All new sections are optional — only included when relevant data exists.

## Cross-cutting Requirements Extraction

### Extraction from design.md (preferred)

Look for these patterns:

**Explicit sections:**
- `## Error Handling`, `## Security`, `## Performance`, etc.

**Decision statements:**
- Sentences with "must", "should", "all", "every" signal cross-cutting rules
- "All API endpoints must validate input using..."
- "Every database call must include retry logic..."

**Architecture rules:**
- "Follow the repository pattern"
- "Use dependency injection for..."

**Interface definitions:**
- Component interaction diagrams
- API contract specifications
- Data structure definitions shared across components

**Flow descriptions:**
- End-to-end operation sequences
- Multi-step processes that span components

### Extraction from PRD.md (fallback when no design.md)

Look in `## Decisions` section for:
- Statements with "must", "should", "all", "every"
- Security, performance, testing mentions
- Technical constraints that apply broadly
- Integration requirements between components

### Mapping to issues

For each vertical slice, determine which cross-cutting requirements apply:

- **API layer issues** → apply API-related requirements, input validation, security
- **User input handling** → apply security, validation, error handling requirements
- **Database access** → apply performance, error handling, retry logic requirements
- **Multi-component flows** → apply interface contracts, flow sequence requirements

## crew-coder Context Reading

### New Step: Read Context Documents

Added after environment setup, before solve-issue invocation:

```bash
# Extract feature slug from issue path
ISSUE_PATH="[provided by caller]"
FEATURE_SLUG=$(echo "$ISSUE_PATH" | sed 's|.*\.scratch/||' | sed 's|/.*||')

# Check for context documents
DESIGN_DOC="$MAIN_ROOT/.scratch/$FEATURE_SLUG/design.md"
PRD_DOC="$MAIN_ROOT/.scratch/$FEATURE_SLUG/PRD.md"

if [ -f "$DESIGN_DOC" ]; then
  echo "Reading design.md for architectural context..."
  # Read and keep in context
fi

if [ -f "$PRD_DOC" ]; then
  echo "Reading PRD.md for requirements context..."
  # Read and keep in context
fi
```

### solve-issue Modification

Add **Step 1.5: Validate Issue Context** after "Read the issue":

1. Check if issue has `## Context Documents` section
2. If yes, read all referenced documents from MAIN_ROOT
3. Keep context in memory during implementation
4. When writing tests, consider cross-cutting requirements
5. Before marking complete, verify:
   - Feature acceptance criteria [x] or [ ]
   - Cross-cutting requirements [x] or [ ] (if section exists)

### Structured Output

The `acceptance_criteria` field now includes both sections:

```json
{
  "acceptance_criteria": "## Acceptance criteria\n- [x] Feature criterion 1\n- [x] Feature criterion 2\n\n## Cross-cutting Requirements\n- [x] Error handling requirement\n- [x] Security requirement",
  ...
}
```

## crew-afk Coverage Validation

### New Exit Step

Insert between "Code review" and "Branch cleanup":

1. Squash commits (existing)
2. Code review (existing)
3. **Coverage validation (NEW)**
4. Branch cleanup (existing)
5. Summary (existing)

### Implementation

```bash
# After code review, before branch cleanup
FEATURE_SLUG=$(git rev-parse --abbrev-ref HEAD | sed 's|.*/||' | sed 's|-[0-9][0-9]-.*||')
DESIGN_DOC=".scratch/$FEATURE_SLUG/design.md"
PRD_DOC=".scratch/$FEATURE_SLUG/PRD.md"

# Skip if no context docs exist
if [ ! -f "$DESIGN_DOC" ] && [ ! -f "$PRD_DOC" ]; then
  echo "Coverage validation: skipped (no design.md or PRD.md found)"
  # Continue to branch cleanup
else
  # Spawn validation agent (haiku, fast validation task)
fi
```

### Validation Agent Prompt

```
Read design.md and/or PRD.md from .scratch/<slug>/ and extract all requirements:
- Key User Stories from PRD
- Technical decisions from PRD and design
- Cross-cutting concerns (error handling, security, performance, logging, testing, architecture constraints, data validation, observability)
- Interface contracts between components
- Multi-issue flows

For each requirement, check:
1. Is it covered by completed issue acceptance criteria in .scratch/<slug>/issues/done/?
2. Is there evidence in merged code? (validation can be heuristic - check for relevant files, functions, tests)

Generate coverage report with three categories:
✓ Covered — requirement addressed in issues and code
⚠ Partial — mentioned in issues but implementation unclear or incomplete
✗ Missing — no evidence in issues or code

Report format:
## Coverage Report
✓ N requirements fully covered
⚠ N requirements partially covered
✗ N requirements missing

### Details
[One line per requirement with status and brief explanation]
✓ Error handling: API endpoints validate input (verified in issues 01, 03)
⚠ Performance: Response time target mentioned but no tests (issue 02)
✗ Logging: No structured logging implementation found
```

### Summary Modification

Add coverage report section before existing per-issue details:

```
Rounds: 2
Merged  (3): auth-login, auth-validate, auth-session
Partial (0): none
Blocked (0): none

## Coverage Report
✓ 15 requirements fully covered
⚠ 2 requirements partially covered
✗ 1 requirement missing

[Detailed breakdown from validation agent]

### Per-issue
[Existing per-issue output]

## Code Review
[Existing code review report]
```

## Error Handling & Edge Cases

### 1. Malformed context documents
- **Scenario:** design.md or PRD.md exists but is empty/corrupted
- **Handling:** to-issues logs warning, continues without cross-cutting requirements. crew-coder logs warning, implements from issue only.

### 2. Conflicting requirements
- **Scenario:** design.md says "use library X", PRD.md says "use library Y"
- **Handling:** design.md takes precedence (more technical detail). crew-coder logs conflict in notes.

### 3. No applicable cross-cutting requirements
- **Scenario:** Issue is too narrow (e.g., "fix typo in docs")
- **Handling:** Omit `## Cross-cutting Requirements` section. Issue proceeds normally.

### 4. Coverage validation finds missing requirements
- **Scenario:** Validation reports ✗ Missing items
- **Handling:** Report is advisory only. crew-afk completes normally, prints coverage report, does NOT block or fail. Human reviews and decides next steps.

### 5. Partial issues with cross-cutting requirements
- **Scenario:** crew-coder returns "partial" status, some cross-cutting requirements unchecked
- **Handling:** Existing flow handles this - notes go into `## Progress`, issue stays open for retry.

### 6. Very large design.md/PRD.md files
- **Scenario:** Documents exceed token limits for crew-coder context
- **Handling:** crew-coder reads first N tokens, logs truncation warning in notes. to-issues includes brief summary in `## Context Documents` section.

### 7. Missing design.md (crew-grill flow)
- **Scenario:** crew-grill produces only PRD.md, no design.md
- **Handling:** 
  - to-issues extracts from PRD.md only (less technical detail, still useful)
  - crew-coder reads only PRD.md (still better than nothing)
  - crew-afk validates against PRD.md only
- **Graceful degradation:** All components work with 0, 1, or 2 context documents.

## Files Modified

| File | Change | Version |
|------|--------|---------|
| `skills/to-issues/SKILL.md` | Add Context Documents, Cross-cutting Requirements, Part of Flow sections to template. Add extraction logic. | 1.2.0 → 1.3.0 |
| `agents/crew-coder/claude.agent.md` | Add context document reading step before solve-issue. | 1.0.0 → 1.1.0 |
| `skills/solve-issue/SKILL.md` | Add Step 1.5 for context validation. Verify cross-cutting requirements. | 1.0.0 → 1.1.0 |
| `skills/crew-afk/SKILL.md` | Add coverage validation step at exit. Update summary format. | 1.0.0 → 1.1.0 |
| `registry.json` | Bump versions for modified components | - |
| `CHANGELOG.md` | Add entry for v1.7.0 | - |

## Testing Strategy

### Unit Testing (per component)

**to-issues:**
- Given design.md with cross-cutting sections, verify extraction produces correct checklists
- Given PRD.md only, verify extraction still works (degraded)
- Given neither, verify issues created without new sections
- Given multi-issue flow in design.md, verify "Part of Flow" annotations

**crew-coder:**
- Given issue with Context Documents section, verify design.md and PRD.md are read
- Given issue without Context Documents, verify normal flow continues
- Given issue with cross-cutting requirements, verify all checklists validated

**crew-afk:**
- Given design.md with requirements, verify coverage report generated
- Given no design.md or PRD.md, verify validation skipped gracefully
- Given partial coverage, verify ⚠ items reported correctly

### Integration Testing (end-to-end)

1. **Full flow with design.md:**
   - Run crew-brainstorm → to-prd → to-issues → crew-afk
   - Verify issues have all new sections
   - Verify crew-coder reads context docs
   - Verify coverage report at exit

2. **crew-grill flow (no design.md):**
   - Run crew-grill → to-prd → to-issues → crew-afk
   - Verify extraction from PRD.md only
   - Verify workflow completes successfully

3. **Manual flow (no context docs):**
   - Create issues manually (no to-issues)
   - Run crew-afk
   - Verify validation skipped, existing flow unchanged

## Implementation Plan

Implement in dependency order:

1. **to-issues modifications** (no dependencies)
   - Update template
   - Add extraction logic
   - Test with sample design.md/PRD.md

2. **solve-issue modifications** (depends on new issue template)
   - Add Step 1.5
   - Add cross-cutting requirements validation
   - Test with sample issues

3. **crew-coder modifications** (depends on solve-issue)
   - Add context reading step
   - Test integration with solve-issue

4. **crew-afk modifications** (depends on all above)
   - Add coverage validation step
   - Update summary format
   - Test end-to-end

5. **Documentation and versioning**
   - Update CHANGELOG.md
   - Update registry.json versions
   - Update CLAUDE.md if needed
