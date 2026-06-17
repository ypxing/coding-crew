---
name: to-issues
description: Break a plan, spec, or PRD into independently-grabbable issues on the project issue tracker using tracer-bullet vertical slices. Use when user wants to convert a plan into issues, create implementation tickets, or break down work into issues.
---

# To Issues

Break a plan into independently-grabbable issues using vertical slices (tracer bullets).

## Issue Tracker Conventions

Issues live as local markdown files in `.scratch/<feature-slug>/issues/<NN>-<slug>.md`:

- One feature per directory: `.scratch/<feature-slug>/`
- The PRD is `.scratch/<feature-slug>/PRD.md`
- Implementation issues are `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`
- Triage state is recorded as a `Status:` line near the top of each issue file
- Comments and conversation history append to the bottom under a `## Comments` heading
- Done issues are moved to `.scratch/<feature-slug>/issues/done/`

### Triage Labels

| Label             | Meaning                                  |
| ----------------- | ---------------------------------------- |
| `needs-triage`    | Maintainer needs to evaluate this issue  |
| `needs-info`      | Waiting on reporter for more information |
| `ready-for-agent` | Fully specified, ready for an AFK agent  |
| `ready-for-human` | Requires human implementation            |
| `wontfix`         | Will not be actioned                     |
| `done`            | Issue is complete and closed             |

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

### 6. Write the issues to local markdown

**Re-run handling**: Before writing, check if `.scratch/<feature-slug>/issues/` already contains issue files.

- If it does and a `done/` subdirectory exists with files in it, **stop** — tell the user: "Some issues are already completed. Please reconcile manually (delete or archive the old issues directory) before re-running."
- If it does but no issues are done (no `done/` subdirectory or it's empty), list the existing files, warn the user they'll be overwritten, and ask for confirmation before proceeding.
- If the directory doesn't exist or is empty, proceed normally.

For each approved slice, create a new markdown file under `.scratch/<feature-slug>/issues/<NN>-<slug>.md`. Use the issue body template below. Add `Status: ready-for-agent` unless the user specifies otherwise.

Write issues in dependency order (blockers first) so you can reference earlier issue numbers in the "Blocked by" field.

<issue-template>
Status: ready-for-agent

## Parent

A reference to the parent issue on the issue tracker (if the source was an existing issue, otherwise omit this section).

## What to build

A concise description of this vertical slice. Describe the end-to-end behavior, not layer-by-layer implementation.

Avoid specific file paths or code snippets — they go stale fast. Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it here and note briefly that it came from a prototype. Trim to the decision-rich parts — not the working demo, just the important bits.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Blocked by

- A reference to the blocking ticket (if any)

Or "None - can start immediately" if no blockers.

</issue-template>

Do NOT close or modify any parent issue.

**Security**: Only read from and write to paths under `.scratch/` within the current repo. Never fetch from external URLs, remote APIs, or paths outside the repository root.
