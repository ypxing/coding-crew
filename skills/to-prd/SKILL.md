---
name: to-prd
description: Turn the current conversation context into a PRD and publish it to the project issue tracker. Use when user wants to create a PRD from the current context.
---

Synthesize the current conversation context into a PRD. Do not ask discovery questions — if
something is unclear, state your assumption. Do confirm technical choices (seams, contracts) with
the user before writing the final document.

{{FRAGMENT:tracker-configuration}}

## Process

1. **Determine the feature slug** before anything else:
   - If the user provided a slug or path argument, extract it from there.
   - Otherwise, list existing directories under `.scratch/` and pick the one that clearly matches the topic.
   - If no match is found, ask: "What feature slug should I use? (This becomes the `.scratch/<slug>/` directory.)"

   Never guess the slug silently — confirm with the user if there's any ambiguity.

2. **Check for an existing PRD.** Run `node "$TRACKER" prd --feature-slug <feature-slug>`: exit 0 prints it — read it, it may contain a `## Decisions` section pre-seeded by `crew-grill`. Preserve and expand those decisions rather than replacing them. An opening `<!-- PRD issue #<n>: … -->` line is the CLI naming the PRD's ref, not part of the PRD: leave it out of what step 6 publishes. Exit 3 means there is none.

3. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary throughout, and respect any ADRs in the area you're touching. The decisions from the grilling session should be captured in the conversation context or in the existing PRD.

4. Sketch the seams at which the feature will be tested. Prefer existing seams over new ones; prefer the highest seam possible. **If decisions are already captured in the existing PRD (e.g. after `crew-grill`), skip re-confirming seams that were already settled — only present genuinely open questions.**

5. Write the PRD using the template below.

{{FRAGMENT:verification-pass}}

6. Then write the PRD to `.scratch/<feature-slug>/.prd-draft.md` and publish it, with that path as `<file>`:

   ```bash
   node "$TRACKER" publish-prd --feature-slug <feature-slug> --title "<feature title>" --body-file <file>
   ```

   It creates the feature's PRD, or updates it when one exists, and prints its ref; delete the draft file once it exits 0. The PRD is titled `PRD: <feature title>` and filed under the feature's milestone where the tracker has one; a tracker that pins it treats a pin failure as a warning, never a failed publish.

**Security**: Only write to paths under `.scratch/` within the current repo, and reach the tracker only through the tracker CLI's `publish-prd`, which acts on the tracker `issue-tracker.md` configures. Never publish to arbitrary external APIs, an unconfigured remote tracker, or paths outside the repository root.

> **Never commit `PRD.md`.** (Local tracker only — on a remote tracker the PRD is an issue, with no local file to accidentally commit.) This file lives under `.scratch/` which is gitignored. Do not run `git add -f`, `git add .scratch/`, or any command that stages files under `.scratch/`.

<prd-template>

## Problem Statement

The problem from the user's perspective. Open with one actor line: `Actor: <who has the problem>`. If the design started from tracker issues, put `Origin: #<n>[, #<n>…]` on the next line (column 0); otherwise omit it. Those issues close together with this PRD.

## Solution

The solution from the user's perspective.

## Behaviours

3–8 items that capture the most important observable behaviours. Format, one per line:

- **B<n>** — given <state>, <what happens>, at <seam>

`<seam>` is where a test observes it (a command, a function, an endpoint, a rendered file).
Example:

- **B1** — given three ready issues, `/crew-afk` runs, all three are implemented in parallel worktrees, at the crew-afk CLI

Do not list every edge case — acceptance criteria on individual issues cover those.

## Decisions

Architectural and technical decisions made during design. One per line:

- **D<n>** — <the decision, and the reason when it is not obvious>

End the line with `(no slice)` when no issue needs to implement the decision — it is already true
of the code, or only constrains how other work is done. `to-issues` then gives it no slice, and its
linter does not warn that no issue's `## Implements` names it.

May include:

- Modules to build/modify and their interfaces
- Schema changes and API contracts
- Key technical tradeoffs and their rationale
- Relevant file paths and existing signatures that implementing agents should know about
- Existing utilities, helpers, or conventions in this codebase that implementation should reuse
  rather than reinvent — the exploration this skill already does once, so each issue's implementer
  does not have to re-grep for it

For each decision that changes existing behaviour, record what relies on the thing it changes, as
facts with `path:line`: its callers, what it calls, the state it reads or writes, and state older
versions left behind (saved files, records, config an earlier release wrote). How you find them is
up to you; the implementer and the reviewer read these instead of rediscovering them. A claim about
existing behaviour without a `path:line` is not a fact: cite it or leave it out.

A decision that says "every", "always", "only" or "never" names the cases easy to miss for it
(signals, thrown errors, early returns, retries, concurrent runs) and says whether each is
included or excluded, e.g. "on every exit path, including a signal; only SIGKILL leaves no record". A
reviewer checks the code against the cases you name and reads an unnamed one as by design. Do this
for pre-seeded decisions too when you expand them. One clause, not a list on every line; a decision
without such a word needs none.

Module design: prefer deep modules (a small interface over substantial behaviour), give each module
one owner, and state the dependency direction (which module depends on which, never the reverse).

Include file paths and short code snippets where they make the intent unambiguous — this PRD is
consumed immediately by agents, not read months later. Keep snippets trimmed to decision-rich
parts (a type shape, schema, signature) — not full implementations. Keep the whole PRD lean:
every coder and reviewer dispatch reads all of it.

## Trust Boundaries & Risks

Write this section only when the feature handles untrusted input, secrets, auth, shell/exec or
network; otherwise omit the heading entirely. For each boundary, name what crosses it and the
failure behaviour — what happens when the input is malformed, the credential is missing or the
call fails.

## Compatibility & Migration

Write this section only when the feature changes a shipped contract (a CLI flag, config key, file
format, API, install path); otherwise omit the heading entirely. State what breaks, what migrates
and how, and whether the change is expand–contract (old and new both work first, the old is removed
later). When the feature adds a reader, validator or gate for data the repo already holds (issue
files, configs, fixtures, records), name where that data lives — `to-issues` turns it into a
criterion that the new code accepts it.

## Testing Decisions

- What makes a good test for this feature (test external behavior, not implementation details)
- Which modules or seams will be tested
- Prior art in the codebase (similar tests to follow as a pattern)

## Assumptions

Write this section only when you filled a gap yourself instead of taking it from a grilling session
or the conversation; otherwise omit the heading entirely. List them one line per assumption.

## Out of Scope

What this feature explicitly does not cover.

## Further Notes

Any additional context, open questions, or constraints that don't fit the above sections.

</prd-template>
