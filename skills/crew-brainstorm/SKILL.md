---
name: crew-brainstorm
description: Use when starting a new feature and you want a thorough design pipeline — capture a feature slug, explore project context, Q&A, propose approaches, build a technical spec section by section, write design.md, then auto-transition to PRD and issues.
---

Run the full brainstorm and design pipeline. Pause for user feedback at each stage, but do not ask the user to manually invoke the next step — transition automatically.

**Hard gate:** Do NOT invoke any implementation skill, write any code, or take any implementation action until the design is approved by the user and this pipeline is complete.

## Step 1 — Capture feature slug

Before asking any questions, capture the feature slug:

- If the user provided a slug or path argument, extract it from there.
- Otherwise, ask: "What feature slug should I use for this design? (Becomes `.scratch/<slug>/` — use kebab-case, e.g. `auth-flow`.)"

Never proceed past this step without a confirmed slug. All `.scratch/<slug>/` paths used throughout this skill derive from the slug captured here.

## Step 2 — Explore project context

Explore the codebase to understand the current state before asking the user anything:

1. Read `CLAUDE.md` if it exists — architecture, conventions, key entry points.
2. List recent commits: `git log --oneline -20` to understand what is in flight.
3. Grep for patterns related to the feature area — find existing utilities, helpers, seams.
4. Note any relevant ADRs or design docs.

Use this context throughout the rest of the session. Do not ask the user for information the codebase can answer.

## Step 3 — Scope check

Before interviewing the user, assess whether the request spans multiple independent subsystems.

If it does, surface this immediately:

> "This request appears to touch [A] and [B] independently. Should we design them together or decompose into two separate brainstorm sessions?"

If the user chooses to decompose, help break it apart and stop — let the user re-invoke for each sub-scope. If the user wants to continue as one, proceed.

## Step 4 — Q&A

Interview the user about every aspect of the design. Walk down each branch of the design tree, resolving dependencies between decisions one at a time:

- Ask **one question at a time**. Wait for the answer before asking the next.
- Use **multiple-choice format** where possible — present 2–4 options.
- Provide your **recommended answer** for each question, with brief reasoning.
- If the codebase already answers a question, state your finding instead of asking.

**This step is strictly exploratory.** Do NOT write files, create issues, run implementation commands, or begin any implementation.

At the end of Q&A:

1. Summarize all decisions reached.
2. Ask once: **"Ready to propose design approaches?"** If yes, continue. If no, stop.

## Step 5 — Propose approaches

Present 2–3 distinct design approaches. For each approach:

- Name and one-sentence summary
- Key trade-offs (pros/cons)
- Estimated complexity

End with a clear recommendation and brief rationale. Ask the user to select an approach (or propose a hybrid). Iterate if needed.

## Step 6 — Design sections

Present the design in sections. Get explicit user approval after each section before proceeding to the next. Suggested sections (adapt to the feature):

1. **Architecture overview** — system diagram or description, key components
2. **Data model / schema** — entities, relationships, contracts
3. **API / interface design** — public seams, signatures, payloads
4. **Implementation plan** — sequencing, dependencies, rollout order
5. **Error handling & edge cases** — failure modes, fallbacks
6. **Testing strategy** — what to test, at which seam, how

For each section, present your proposal and ask: "Does this section look right? Any changes before I continue?"

## Step 7 — Write design.md

After all sections are approved, write the complete technical specification to `.scratch/<slug>/design.md` (creating the directory if needed).

The design document must include:

- Feature slug and one-line purpose at the top
- All sections from Step 6 with full detail
- Code snippets, architecture diagrams (as ASCII or mermaid), type shapes, or schema — wherever they make intent unambiguous
- Decisions and rationale (not just conclusions)
- Out of scope items

**Security**: Only write to paths under `.scratch/` within the current repo. Never write to external paths or remote APIs.

After writing, print the path: `.scratch/<slug>/design.md`

## Step 8 — Spec self-review

Before showing the design to the user, perform an inline review pass. Fix any issues found directly in `.scratch/<slug>/design.md`:

1. **Placeholder scan** — no TODO, TBD, or placeholder text should remain.
2. **Internal consistency** — cross-references between sections should be coherent; no contradictions.
3. **Scope check** — confirm nothing in the spec contradicts the agreed scope from Step 3.
4. **Ambiguity check** — every interface, type shape, and contract must be precise enough for an implementing agent to act on without asking follow-up questions.

If fixes are made, note them briefly to the user.

## Step 9 — User review gate

Ask the user to review `.scratch/<slug>/design.md` before proceeding:

> "I've written the design to `.scratch/<slug>/design.md`. Please review it. Reply 'approved' to continue, or tell me what to change."

Iterate on changes until the user explicitly approves. Do not proceed to Step 10 until you receive approval.

**This is the hard gate.** No implementation, no PRD, no issues until approval is given here.

## Step 10 — Auto-transition to to-prd

Run the `to-prd` skill using the same feature slug captured in Step 1. Do not re-ask the slug. Pass the design.md content as primary context.

At the end of writing the PRD, ask once: **"Ready to break this into issues?"** If yes, continue to Step 11. If no, stop.

## Step 11 — Auto-transition to to-issues

Run the `to-issues` skill using the same feature slug and the PRD just written as primary input. Do not re-ask the slug or whether to run `to-prd` (it was just done).

Complete the issue quiz and write all approved issues to `.scratch/<slug>/issues/`.
