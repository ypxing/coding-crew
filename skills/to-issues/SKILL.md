---
name: to-issues
description: Break a plan, spec, or PRD into independently-grabbable issues on the project issue tracker using tracer-bullet vertical slices. Use when user wants to convert a plan into issues, create implementation tickets, or break down work into issues.
---

# To Issues

Break a plan into independently-grabbable issues using vertical slices (tracer bullets).

## Tracker Configuration

Before any tracker operation, locate `issue-tracker.md` using this lookup chain:

1. `$(git rev-parse --show-toplevel)/docs/agents/issue-tracker.md` (project-level)

If it does not exist, stop: "No issue tracker config found. Re-run `./install.sh`."

All tracker operations in this skill use the operation definitions in that file.

## Process

### 1. Gather context and determine feature slug

Work from whatever is already in the conversation context. If the user passes an issue reference as an argument, it must be a local file path (e.g. `.scratch/feature/issues/01-slug.md`) or an issue number within `.scratch/`. Do NOT fetch from external URLs or remote issue trackers — only read local files.

Determine the **feature slug** (the directory name under `.scratch/`):

1. If the user provided a path argument, extract the slug from it (e.g. `.scratch/auth-flow/...` → `auth-flow`).
2. Otherwise, list existing directories under `.scratch/` and check if one clearly matches the topic being discussed.
3. If no match is found, ask the user: "What feature slug should I use? (This becomes the `.scratch/<slug>/` directory name.)"

Never guess the slug silently — confirm with the user if there's any ambiguity.

### 2. Check for a PRD

Check whether a PRD exists at `.scratch/<feature-slug>/PRD.md`. If one exists, read it and use it as the primary source material for decomposition.

If no PRD exists, ask the user:

> "I don't see a PRD at `.scratch/<feature-slug>/PRD.md`. Would you like me to run `/to-prd` first to formalize the spec, or should I work from the current conversation context?"

If the user chooses to run `/to-prd`, invoke it (using the same feature slug), then continue with the resulting PRD. If the user declines, proceed with conversation context as before.

### 2.5. Check for a design doc

After the PRD check, look for a design doc at `.scratch/<feature-slug>/design.md`. If it exists, read it and use it as supplementary context when drafting vertical slices and writing acceptance criteria. The design doc provides technical depth (interfaces, data flows, architecture decisions) that enriches the issue breakdown beyond what the PRD contains.

If no design doc exists, continue with whatever context is available from the PRD or conversation.

### 3. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Issue titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

### 4. Draft vertical slices

Break the plan into **tracer bullet** issues. Each issue is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
</vertical-slice-rules>

### 5. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **User stories covered**: which user stories this addresses (if the source material has them)

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the dependency relationships correct?
- Should any slices be merged or split further?
- Are the correct slices marked as HITL and AFK?

Iterate until the user approves the breakdown.

### 5.5. Extract cross-cutting requirements

After the user approves the breakdown and before writing issues, extract cross-cutting requirements from design.md or PRD.md (if they exist) to include in issue checklists.

**Cross-cutting requirement categories** (10 total):

1. Error Handling — how errors are caught, logged, propagated
2. Logging — what to log, format, levels
3. Security — auth checks, input validation, sensitive data handling
4. Performance — response time targets, resource limits
5. Testing — test coverage requirements, types of tests needed
6. Architecture Constraints — patterns to follow, libraries to use, interfaces to respect
7. Data Validation — schema constraints, input sanitization rules
8. Observability — metrics, tracing, monitoring hooks
9. Interfaces & Contracts — API contracts, function signatures, data structures shared across components
10. Multi-Issue Flows — end-to-end operations spanning multiple vertical slices

**Extraction from design.md (preferred):**

Check if `.scratch/<feature-slug>/design.md` exists. If it does, scan for:

- Explicit section headings: `## Error Handling`, `## Security`, `## Performance`, etc.
- Decision statements with "must", "should", "all", "every" (signals cross-cutting rules)
  - Example: "All API endpoints must validate input using..."
  - Example: "Every database call must include retry logic..."
- Architecture rules: "Follow the repository pattern", "Use dependency injection for..."
- Interface definitions: component interaction diagrams, API contracts, shared data structures
- Flow descriptions: end-to-end operations, multi-step processes spanning components

**Extraction from PRD.md (fallback when no design.md):**

If design.md doesn't exist, check `.scratch/<feature-slug>/PRD.md`. If it exists, scan the `## Decisions` section for:

- Statements with "must", "should", "all", "every"
- Security, performance, testing mentions
- Technical constraints that apply broadly
- Integration requirements between components

**Mapping requirements to issues:**

For each vertical slice, determine which cross-cutting requirements apply based on what layers/components the issue touches:

- **API layer issues** → apply API-related requirements, input validation, security
- **User input handling** → apply security, validation, error handling
- **Database access** → apply performance, error handling, retry logic
- **Multi-component flows** → apply interface contracts, flow sequence requirements

**Multi-issue flow detection:**

Look in design.md or PRD.md for descriptions of end-to-end operations that span multiple vertical slices (e.g., auth flows, data pipelines, request/response cycles). For each issue that's part of such a flow, note:

- Which upstream issues must complete first (dependencies)
- Which downstream issues depend on this one
- A brief description of this issue's role in the overall flow

### 6. Write the issues to local markdown

**Re-run handling**: Before writing, check if `.scratch/<feature-slug>/issues/` already contains issue files.

- If it does and a `done/` subdirectory exists with files in it, **stop** — tell the user: "Some issues are already completed. Please reconcile manually (delete or archive the old issues directory) before re-running."
- If it does but no issues are done (no `done/` subdirectory or it's empty), list the existing files, warn the user they'll be overwritten, and ask for confirmation before proceeding.
- If the directory doesn't exist or is empty, proceed normally.

For each approved slice, execute the `publish` operation from `issue-tracker.md` to create a new issue file. Use the issue body template below. Add `Status: ready-for-agent` unless the user specifies otherwise.

Write issues in dependency order (blockers first) so you can reference earlier issue numbers in the "Blocked by" field.

<issue-template>
Status: ready-for-agent

## Context Documents

> **Optional — only include this section if design.md or PRD.md exist for this feature. Omit entirely if neither document exists.**

- Design: `.scratch/<feature-slug>/design.md`
- PRD: `.scratch/<feature-slug>/PRD.md`

Read these documents before implementing. They contain architecture decisions, integration constraints, and technical context essential for this issue.

## Parent

A reference to the parent issue on the issue tracker (if the source was an existing issue, otherwise omit this section).

## What to build

A concise description of this vertical slice. Describe the end-to-end behavior, not layer-by-layer implementation.

Avoid specific file paths or code snippets — they go stale fast. Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it here and note briefly that it came from a prototype. Trim to the decision-rich parts — not the working demo, just the important bits.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Cross-cutting Requirements

> **Optional — only include this section if cross-cutting requirements from design.md or PRD.md apply to this issue. Omit entirely if no applicable requirements exist.**

Requirements from design.md/PRD.md that apply to this implementation:

- [ ] [Error handling requirement]
- [ ] [Security requirement]
- [ ] [Performance requirement]
- [ ] [etc.]

## Part of Flow

> **Optional — only include this section if this issue is part of a multi-issue flow (an end-to-end operation spanning multiple vertical slices). Omit entirely for standalone issues.**

This issue implements [step description] of the [flow name] flow.

**Full flow:** [brief description or reference to design.md section]
**Upstream:** [previous step/issue or "none"]
**Downstream:** [next step/issue or "none"]

## Blocked by

- A reference to the blocking ticket (if any)

Or "None - can start immediately" if no blockers.

## Interfaces

> **Optional — only include this section if `## Blocked by` is non-empty (i.e. this issue has upstream dependencies). Omit entirely for issues with no blockers.**

### Consumes:

Exact signatures, types, or contracts expected from the blocking issues listed above. Be precise enough that a parallel agent implementing a blocker knows what shape to expose.

### Exposes:

Exact signatures, types, or contracts this issue produces for any downstream issues that depend on it.

</issue-template>

Do NOT close or modify any parent issue.

**Security**: Only read from and write to paths under `.scratch/` within the current repo. Never fetch from external URLs, remote APIs, or paths outside the repository root.
