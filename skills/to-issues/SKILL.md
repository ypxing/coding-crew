---
name: to-issues
description: Break a plan, spec, or PRD into independently-grabbable issues on the project issue tracker using tracer-bullet vertical slices. Use when user wants to convert a plan into issues, create implementation tickets, or break down work into issues.
---

# To Issues

Break a plan into independently-grabbable issues using vertical slices (tracer bullets).

## Tracker Configuration

Before any tracker operation, locate `issue-tracker.md` using this lookup chain:

1. `$(git rev-parse --show-toplevel)/.coding-crew/docs/issue-tracker.md` (project-level)

If it does not exist, invoke the `configure-tracker` skill now to set it up, then continue.

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


### 3. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code. Issue titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

While exploring, look for **prefactoring opportunities** — changes that would make the feature implementation significantly easier. "Make the change easy, then make the easy change." Prefactoring issues must be sliced and sequenced first so downstream feature issues can build on a clean foundation.

Also note any **shared surfaces**: a schema/table, a shared type, or an existing function/module that more than one slice would need to modify. This is a narrower thing than "touches the same file" — two slices adding independent, non-overlapping code to the same file is the normal shape of vertical slicing and merges cleanly; a shared surface is where two slices would plausibly change the *same specific behavior*. Carry any you find into the quiz step below; don't turn them into blocking edges yourself — whether a shared surface needs sequencing or is safe to leave parallel is a judgment call for the quiz, not something to guess silently here.

### 4. Draft vertical slices

Break the plan into **tracer bullet** issues. Each issue is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Each slice is sized to fit in a single fresh context window — if a slice requires multiple agent sessions it must be split further
- Prefer many thin slices over few thick ones
- Any prefactoring should be sequenced first
</vertical-slice-rules>

**Wide refactors are the exception to vertical slicing.** A wide refactor is one mechanical change — rename a column, retype a shared symbol — whose blast radius fans across the whole codebase so no vertical slice can land green on its own. Don't force it into a tracer bullet; sequence it as **expand–contract**:

1. **Expand** — add the new form beside the old so nothing breaks
2. **Migrate** — move call sites over in batches (per package, per directory), each batch its own issue blocked by the expand, keeping CI green batch to batch because the old form still exists
3. **Contract** — delete the old form once no caller remains, blocked by every migrate batch

When even the batches can't stay green independently, let them share an integration branch and block a final integrate-and-verify issue — green is promised only there.

### 5. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **What it delivers**: the end-to-end behaviour this slice makes work, from the user's perspective

If step 3 turned up any shared surfaces, list them separately — one line per surface, naming the slices that touch it — and ask about each one explicitly: is the overlap additive (safe to leave parallel), or does it need a `Blocked by` edge (or a merge)? Don't add the edge yourself; this is exactly the call a file-overlap heuristic gets wrong, because it can't tell "two slices editing the same file in unrelated ways" from "two slices that will conflict."

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the blocking edges correct — does each issue only depend on issues that genuinely gate it?
- Should any slices be merged or split further?
- Are the correct slices marked as HITL and AFK?
- For any shared surface listed above: sequence it, merge the slices, or leave it parallel?

Iterate until the user approves the breakdown.

### 5.5. Extract cross-cutting requirements

After the user approves the breakdown and before writing issues, extract cross-cutting requirements from `PRD.md` (if it exists) to include in issue checklists.

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

**Extraction from PRD.md:**

Read `.scratch/<feature-slug>/PRD.md` if it exists. Scan for cross-cutting requirements across all sections — especially `## Decisions`, `## Testing Decisions`, and `## Further Notes`:

- Explicit headings for any of the 10 categories above
- Decision statements with "must", "should", "all", "every" (signals cross-cutting rules)
  - Example: "All API endpoints must validate input using..."
  - Example: "Every database call must include retry logic..."
- Architecture rules: "Follow the repository pattern", "Use dependency injection for..."
- Interface definitions: API contracts, function signatures, shared data structures
- Flow descriptions: end-to-end operations spanning multiple components

**Mapping requirements to issues:**

For each vertical slice, determine which cross-cutting requirements apply based on what layers/components the issue touches:

- **API layer issues** → apply API-related requirements, input validation, security
- **User input handling** → apply security, validation, error handling
- **Database access** → apply performance, error handling, retry logic
- **Multi-component flows** → apply interface contracts, flow sequence requirements

**Multi-issue flow detection:**

Look in `PRD.md` for descriptions of end-to-end operations that span multiple vertical slices (e.g., auth flows, data pipelines, request/response cycles). For each issue that's part of such a flow, note:

- Which upstream issues must complete first (dependencies)
- Which downstream issues depend on this one
- A brief description of this issue's role in the overall flow

### 6. Write the issues to local markdown

**Re-run handling**: Before writing, check if `.scratch/<feature-slug>/issues/` already contains issue files.

- If it does and a `done/` subdirectory exists with files in it, **stop** — tell the user: "Some issues are already completed. Please reconcile manually (delete or archive the old issues directory) before re-running."
- If it does but no issues are done (no `done/` subdirectory or it's empty), list the existing files, warn the user they'll be overwritten, and ask for confirmation before proceeding.
- If the directory doesn't exist or is empty, proceed normally.

For each approved slice, execute the `publish` operation from `issue-tracker.md` to create a new issue file. Use the issue body template below. Add `Status: ready-for-agent` unless the user specifies otherwise.

Write issues in dependency order (blockers first) so you can reference earlier issue numbers in the "Blocked by" field. Work the **frontier**: any issue whose blockers are all done. For a linear chain that means top-to-bottom; for a DAG with multiple independent roots, publish all currently unblocked issues before their dependents.

<issue-template>
Status: ready-for-agent

## Context Documents

> **Optional — only include this section if a PRD exists for this feature. Omit entirely if no PRD exists.**

- PRD: `.scratch/<feature-slug>/PRD.md`

Read this document before implementing. It contains architecture decisions, integration constraints, and technical context essential for this issue.

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

> **Optional — only include this section if cross-cutting requirements from `PRD.md` apply to this issue. Omit entirely if no applicable requirements exist.**

Requirements from `PRD.md` that apply to this implementation:

- [ ] [Error handling requirement]
- [ ] [Security requirement]
- [ ] [Performance requirement]

## Part of Flow

> **Optional — only include this section if this issue is part of a multi-issue flow (an end-to-end operation spanning multiple vertical slices). Omit entirely for standalone issues.**

This issue implements [step description] of the [flow name] flow.

**Full flow:** [brief description or reference to PRD.md section]
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

### 7. Write the machine-readable dependency map

After publishing all issues, write `.scratch/<feature-slug>/issues/issues-deps.json` — a flat map from each issue's filename to the filenames of its blockers, e.g.:

```json
{
  "01-first.md": [],
  "02-second.md": ["01-first.md"],
  "03-third.md": ["01-first.md", "02-second.md"]
}
```

Source it from the same blocking edges the user confirmed in the quiz step — do not re-derive it from the `## Blocked by` prose. This file, not the prose, is what the orchestrator uses to decide whether an issue is ready to dispatch; the `## Blocked by` section stays in each issue purely for a human reading that file. Include every issue you just published, even ones with no blockers (`[]`), so the map is authoritative for the whole feature rather than partial.

Do NOT close or modify any parent issue.

**Security**: Only read from and write to paths under `.scratch/` within the current repo. Never fetch from external URLs, remote APIs, or paths outside the repository root.
