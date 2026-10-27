---
name: to-prd
description: >
  Turns the current conversation context into a PRD and publishes it to the project issue tracker. Use when
  the user wants to create a PRD from the current context.
---

Synthesize the current conversation context into a PRD. Do not ask discovery questions — if
something is unclear, state your assumption. Do confirm technical choices (seams, contracts) with
the user before writing the final document, except those already settled (step 4).

**Non-interactive run.** A run whose prompt, or whose caller, says it is non-interactive asks nothing: step 4
confirms no seam with the user, and the seams you chose go into the PRD's `## Assumptions`, one line each. On such a
run, invoked by `to-issues`, step 6 writes the draft and does not publish it: the caller publishes it once its
own checks leave no open question, so a run that stops on one publishes nothing.

<!-- fragment:missing-library -->
**Shared scripts.** The scripts this skill runs live in the `coding-crew-lib` skill, installed beside it at
`<skill-dir>/../coding-crew-lib` (`<skill-dir>` being the directory you read this file from). Before the first
command that runs one, check that directory exists. If it does not, stop and tell the user to install it at this
skill's scope, `npx skills add ypxing/coding-crew -s coding-crew-lib` (adding `-g` when this skill is installed at
user level), or to re-run coding-crew's `install.sh`.
<!-- /fragment:missing-library -->

<!-- fragment:tracker-configuration -->
## Tracker Configuration

Every tracker op runs through the tracker CLI, `TRACKER=<skill-dir>/../coding-crew-lib/scripts/tracker/cli.mjs` (`<skill-dir>` being the
directory you read this file from), as `node "$TRACKER" <op> …`; nothing else reads or writes the tracker. Before the
first op run `node "$TRACKER" config` (prints `tracker=<kind>` and `configured=yes|no`). On `configured=no` on an
interactive run, invoke the `configure-tracker` skill, then continue; on a non-interactive run (a headless/`-p`
invocation or a subagent) never ask: proceed as `local`. The tracker's refs, statuses and labels are in
`<skill-dir>/../coding-crew-lib/scripts/tracker/docs/<kind>.md`.

Exit codes, every op: 0 ok; 3 not found; on 1 (the op failed) or 2 (a usage error or an invalid ref), report the
stderr verbatim, fix its cause (an input, auth, the network) and re-run the op, never performing it with the tracker's
own tool. `publish-issues` adds 4 and 5, which the skill that publishes handles.
<!-- /fragment:tracker-configuration -->

## Process

1. **Determine the feature slug** before anything else:
   - If the user provided a slug or path argument, or a calling skill handed you the slug, extract it from there.
   - Otherwise, run `node "$TRACKER" features` — one `<slug>\t<open|closed>\t<ready-count>` line per feature, open and closed — and pick the slug that clearly matches the topic.
   - If no match is found, ask: "What feature slug should I use?"

   Never guess the slug silently — confirm with the user if there's any ambiguity. **Before reusing a slug `features` lists, ask the user** whether to extend that feature (its PRD is updated in place) or choose a new slug; a closed feature is still a taken slug. Skip that question when a calling skill (`to-issues`) handed you the slug: it already confirmed it with the user.

2. **Check for an existing PRD.** Run `node "$TRACKER" prd --feature-slug <feature-slug>`: exit 0 prints it — read it: its `## Decisions` are settled. Preserve and expand them rather than replacing them. An opening `<!-- PRD issue #<n>: … -->` line is the CLI naming the PRD's ref, not part of the PRD: leave it out of what step 6 publishes. Exit 3 means there is none.

3. Explore the repo to understand the current state of the codebase, if you haven't already. Use the project's domain glossary vocabulary throughout, and respect any ADRs in the area you're touching. Decisions already settled are in the conversation (a `crew-grill` or `crew-brainstorm` summary) or in the existing PRD.

4. Sketch the seams at which the feature will be tested. Prefer existing seams over new ones; prefer the highest seam possible; the fewer seams across the codebase the better, and the ideal number is one. **Skip re-confirming seams and decisions settled earlier in the conversation (a `crew-grill` or `crew-brainstorm` summary) or in an existing PRD — only present genuinely open questions.**

5. Write the PRD using the template below.

<!-- fragment:verification-pass -->
**Verification pass.** Before the design goes back to the user, re-check what it rests on against its source, never against memory. Necessity is not re-checked here.

- **Facts** — for every count, `path:line`, list and "nothing else reads/does X" claim, re-run the grep, line read or command behind it and compare its output with what you said.
- **Correct** — check each decision against criterion 2 (**Correct**) of the design standard: it does what it claims against the real code, and its rationale holds. Cite the evidence (`file:line`, a command's output) either way.
- **Coherence** — check the decisions against each other: two that contradict, one that depends on something no decision provides, an `(auto)` line that conflicts with an answer the user gave.

Report every change as "said X → actually Y (source)". Fix each decision built on a corrected fact before the user sees the design, and show the corrections with it, so the user sees what moved.
<!-- /fragment:verification-pass -->

   After a `crew-grill` or `crew-brainstorm` summary, re-check only what the PRD adds beyond it — the summary just went through this pass; a standalone run re-checks everything the PRD cites. Necessity is settled by the design you were handed. Revise each corrected decision in the PRD before publishing it, and report the corrections to the user.

6. Then write the PRD to `.coding-crew/scratch/<feature-slug>/.prd-draft.md` and publish it, with that path as `<file>`:

   ```bash
   node "$TRACKER" publish-prd --feature-slug <feature-slug> --title "<feature title>" --body-file <file>
   ```

   It creates the feature's PRD, or updates it when one exists, and prints its ref; delete the draft file once it exits 0. The title depends on the tracker (`tracker=` from `node "$TRACKER" config`):

   - **local** — the PRD is a file with no other title, so the body you write opens with `# PRD: <feature title>`.
   - **github** — `--title` titles the issue `PRD: <feature title>`, so the body has no such heading. The PRD becomes the feature's root issue, or a sub-issue of the root the feature already has.

**Security**: Only write to paths under `.coding-crew/scratch/` within the current repo, and reach the tracker only through the tracker CLI's `publish-prd`, which acts on the tracker `config.json` configures. Never publish to arbitrary external APIs, an unconfigured remote tracker, or paths outside the repository root.

> **Never commit `PRD.md`.** (Local tracker only — on a remote tracker the PRD is an issue, with no local file to accidentally commit.) This file lives under `.coding-crew/scratch/`, which the tracker CLI gitignores (`.coding-crew/scratch/.gitignore`). Do not run `git add -f`, `git add .coding-crew/scratch/`, or any command that stages files under `.coding-crew/scratch/`.

<prd-template>

## Problem Statement

The problem from the user's perspective. Open with one actor line: `Actor: <who has the problem>`. If the design started from tracker issues, put `Origin: #<n>[, #<n>…]` on the next line (column 0); otherwise omit it. On the github tracker, those issues close together with this PRD; the local tracker closes nothing from it.

## Solution

The solution from the user's perspective.

## Behaviours

3–8 items that capture the most important observable behaviours. Format, one per line:

- **B<n>** — given <state>, <what happens>, at <seam>

`<seam>` is where a test observes it (a command, a function, an endpoint, a rendered file).
Example:

- **B1** — given an expired token, the CLI exits 2 and names the env var to set, at `cli.mjs`

Do not list every edge case — acceptance criteria on individual issues cover those.

## Decisions

Architectural and technical decisions made during design. One per line:

- **D<n>** — <the decision, and the reason when it is not obvious>

A decision a design summary tagged `(auto)` keeps that tag, and a fact it established goes into the
decision it supports with its citation.

End the line with `(no slice)` when no issue needs to implement the decision — it is already true
of the code, or only constrains how other work is done. `to-issues` then gives it no slice and does
not ask about it.

May include:

- Modules to build/modify and their interfaces
- Schema changes and API contracts
- Key technical tradeoffs and their rationale
- Relevant file paths and existing signatures the implementers should know about
- Existing utilities, helpers, or conventions in this codebase that implementation should reuse
  rather than reinvent — the exploration this skill already does once, so each issue's implementer
  does not have to re-grep for it

Rules for the lines:

- **What relies on it.** A decision that changes existing behaviour records what relies on the
  thing it changes, as facts with `path:line`: callers, callees, the state it reads or writes, and
  state older versions left behind (saved files, records, config an earlier release wrote). The
  implementer and the reviewer read these instead of rediscovering them. A claim about existing
  behaviour without a `path:line` is not a fact: cite it or leave it out.
- **"Every", "always", "only", "never".** A decision using such a word names, in one clause, the
  cases easy to miss (signals, thrown errors, early returns, retries, concurrent runs) and whether
  each is in or out, e.g. "on every exit path, including a signal; only SIGKILL leaves no record".
  The reviewer checks the named cases and reads an unnamed one as by design. A decision without
  such a word needs none.
- **Module design.** Prefer deep modules (a small interface over substantial behaviour), one owner
  per module, and a stated dependency direction.
- **Lean.** File paths and short snippets where they make the intent unambiguous, trimmed to the
  decision-rich parts (a type shape, schema, signature), never full implementations. This PRD is
  read immediately, in full, by whoever implements and whoever reviews each issue.

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

What this feature explicitly does not cover, including each item a design summary cut, with why it
was cut.

## Further Notes

Any additional context, open questions, or constraints that don't fit the above sections.

</prd-template>
