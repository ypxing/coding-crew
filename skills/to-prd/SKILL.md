---
name: to-prd
description: Turn the current conversation context into a PRD and publish it to the project issue tracker. Use when user wants to create a PRD from the current context.
---

Synthesize the current conversation context into a PRD. Do not ask discovery questions — if
something is unclear, state your assumption. Do confirm technical choices (seams, contracts) with
the user before writing the final document.

## Tracker Configuration

Before any tracker operation, locate `issue-tracker.md` using this lookup chain:

1. `$(git rev-parse --show-toplevel)/.coding-crew/docs/issue-tracker.md` (project-level)

If it does not exist, invoke the `configure-tracker` skill now to set it up, then continue.

All tracker operations in this skill use the operation definitions in that file.

## Process

1. **Determine the feature slug** before anything else:
   - If the user provided a slug or path argument, extract it from there.
   - Otherwise, list existing directories under `.scratch/` and pick the one that clearly matches the topic.
   - If no match is found, ask: "What feature slug should I use? (This becomes the `.scratch/<slug>/` directory.)"

   Never guess the slug silently — confirm with the user if there's any ambiguity.

2. **Check for an existing PRD.** If `.scratch/<feature-slug>/PRD.md` already exists, read it — it may contain a `## Decisions` section pre-seeded by `crew-grill`. Preserve and expand those decisions rather than replacing them.

3. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary throughout, and respect any ADRs in the area you're touching. The decisions from the grilling session should be captured in the conversation context or in the existing PRD.

4. Sketch the seams at which the feature will be tested. Prefer existing seams over new ones; prefer the highest seam possible. **If decisions are already captured in the existing PRD (e.g. after `crew-grill`), skip re-confirming seams that were already settled — only present genuinely open questions.**

5. Write the PRD using the template below, then execute the `publish` operation from `issue-tracker.md` to save it to `.scratch/<feature-slug>/PRD.md` (creating the directory if needed).

**Security**: Only write to paths under `.scratch/` within the current repo. Never publish to external APIs, remote issue trackers, or paths outside the repository root.

> **Never commit `PRD.md`.** This file lives under `.scratch/` which is gitignored. Do not run `git add -f`, `git add .scratch/`, or any command that stages files under `.scratch/`.

<prd-template>

## Problem Statement

The problem from the user's perspective.

## Solution

The solution from the user's perspective.

## Key User Stories

3–5 user stories that capture the most important behaviors. Format:

1. As an <actor>, I want <feature>, so that <benefit>

Example:
1. As a developer, I want to run a single command to implement all open issues in parallel, so that I can go AFK while the sprint completes.

Do not exhaustively list every edge case — acceptance criteria on individual issues will cover those.

## Decisions

Architectural and technical decisions made during design. May include:

- Modules to build/modify and their interfaces
- Schema changes and API contracts
- Key technical tradeoffs and their rationale
- Relevant file paths and existing signatures that implementing agents should know about
- Existing utilities, helpers, or conventions in this codebase that implementation should reuse
  rather than reinvent — the exploration this skill already does once, so each issue's implementer
  does not have to re-grep for it

Include file paths and short code snippets where they make the intent unambiguous — this PRD is
consumed immediately by agents, not read months later. Keep snippets trimmed to decision-rich
parts (a type shape, schema, signature) — not full implementations.

## Testing Decisions

- What makes a good test for this feature (test external behavior, not implementation details)
- Which modules or seams will be tested
- Prior art in the codebase (similar tests to follow as a pattern)

## Out of Scope

What this feature explicitly does not cover.

## Further Notes

Any additional context, open questions, or constraints that don't fit the above sections.

</prd-template>
