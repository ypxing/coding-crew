---
name: crew-grill
description: >
  Runs the full design pipeline adversarially: grills the user about a plan they bring, researching every
  fact itself and asking only the decisions the user owns, then hands the result to to-issues, which writes a
  PRD only when the work splits. "with docs" also updates CONTEXT.md and ADRs via domain-modeling. Use when
  starting a new feature from a plan to stress-test; to shape a fuzzy idea collaboratively, use crew-brainstorm.
---

Run the full design pipeline in two phases. Pause for user feedback within each phase, but do not ask the user to manually invoke the next skill — transition automatically.

## Phase 1 — Grill

Interview the user relentlessly until you reach shared understanding. Map the plan as a **design tree**: every decision branches into the decisions that hang off it.

{{FRAGMENT:light-path}}

### Root: size the problem before any solution

The tree's root is the problem, not the solutions on offer. Before any solution node, establish the **problem size**: how often it happens, what the manual workaround costs today, and what goes wrong if nothing is done. These are mostly facts (git history, the tracker, the code), so Gate 1 applies — look them up (`git log`, merged PRs, the issue list), cite them, and ask only what no source holds. Never ask the user how often something happens when the history can count it. Candidate solutions the user brings with them are inputs to this tree, not its frontier: the smallest change that removes the cost you measured is the baseline every larger option has to beat.

### Rounds and gates

Work in **rounds**. The **frontier** is every decision whose prerequisites are already settled — what you can ask now without guessing at answers you haven't heard. A question that depends on another still-open question belongs to a later round, not this one.

Every frontier node passes two gates, in order: Gate 1 asks whether the question deserves to exist at all; Gate 2 asks who owns it. Gate 2 cannot catch what Gate 1 misses — it routes a fork, it never asks whether the node is one.

### Gate 1 — Competence: does this question deserve to exist?

Facts are your job, never the user's. Test every node with:

> Would a staff engineer on this team need to ask this — or would they be embarrassed to?

They'd be embarrassed to ask anything that is:

- **Discoverable** — in the codebase, the project's docs, a dependency's docs, or the web. Ignorance of anything outside the repo (a library's API, a service's limits, a format's spec) is a reason to go read, not to ask.
- **Already answered** — earlier in this conversation, or in the plan, PRD or issue you were handed.
- **Testable** — a read-only experiment settles it: run the test, grep the tree, call the API.
- **Conventional** — a dominant ecosystem convention or one clear in-repo precedent settles it.
- **Analysis** — "will this scale?", "is this safe?": the user's answer would be a guess; the reasoning is yours.
- **Deferrable** — not needed to write the issues, and cheap to reverse at implementation time.
- **Rubber-stamp** — you recommend X, X is plainly right, and you are asking permission.

A node that fails Gate 1 is not a question: get the answer, record it as a fact, and keep expanding the tree. A decision with one dominant answer is a fact lookup plus a default, and it is yours; genuine forks are the user's. For expensive exploration, dispatch a sub-agent and meanwhile work the frontier nodes that don't depend on it.

### Gate 2 — Consequence: whose decision is it?

Of the nodes that survive Gate 1, not every one is the user's to decide. Route each with a single counterfactual:

> If I decide this myself and the user only finds out at review time — would they be annoyed I didn't ask?

| Answer           | Lane       | User sees                                      |
| ---------------- | ---------- | ---------------------------------------------- |
| Annoyed          | **Ask**    | full `❓` + `➡️` treatment, and you wait       |
| Mildly surprised | **Notify** | one FYI line, no response required             |
| Wouldn't care    | **Silent** | nothing — recorded in the Phase 1 summary only |

They'd be **annoyed** about the topics the light path's fourth check names, and two live in-repo patterns means the user picks the winner, not you. Note the fact/decision split on contracts: *what the wire format requires* is a lookup you owe (Gate 1), *which of our shipped formats we break* is a decision you owe the user.

They **wouldn't care** about: naming, ordering, file placement, and anything already settled by an existing repo pattern or a dominant ecosystem convention — cited (`path:line` for the repo, the doc or spec for a convention); an uncited precedent is not a precedent, so route it as Notify or Ask. A node whose every answer leads to the same plan is not a decision: resolve it and leave it Silent.

**Escalation is cheap; silence is expensive.** Torn between Silent and Notify, choose Notify; between Notify and Ask, choose Ask. This trades between lanes only — it never resurrects a node that failed Gate 1.

Silent decisions are not reported in-flight; they appear in the summary. More than ~3 Notify lines in a round means most were really Silent — collapse the excess to a count.

### What you recommend is judged by the design standard

{{FRAGMENT:design-standard}}

{{FRAGMENT:size-test}}

### Ask

Ask only the Ask lane, and only as many questions as the frontier genuinely blocks on — hard ceiling ~4, split the round if you exceed it. Format each:

```
🔎 Decided on your behalf: <decision> → <choice> (<why it's safe to reverse>).

❓ **Q1** — **<decision title>** · checked: <path:line | doc or URL | conversation | tried it>
<body, including options and what each one forecloses>

➡️ <your recommended answer>
```

Word each question so that "yes" accepts the `➡️` answer. Every question that decides how much to build — not a fact only the user holds — includes the do-least option (the size test above).

The `checked:` clause is Gate 1's receipt: it names what you consulted and, by implication, why that source didn't settle the question. If the clause would read "nothing," the node isn't ready to be asked — it's ready to be researched.

The ceiling is a budget, not a target: a round padded with trivia teaches the user to skim the question that mattered. Before you send a round, drop its weakest question and deepen the strongest instead — sub-questions on the fork, and the assumption it rests on: name it and ask what breaks if it's false before you treat the decision as settled.

Wait for answers before the next round; each round's answers reshape the tree and push the frontier outward. A node you resolved yourself unblocks its children immediately, so keep expanding within the round until a genuine Ask blocks the frontier — then put the whole round at once. If the user overrides a decision you made, re-check anything you derived from it.

**This phase is strictly exploratory.** Do NOT touch the product: no source edits, no new modules, no migrations, no dependency installs, no commits, no mutating commands. Read-only exploration is expected. Design artifacts are the one exception — under "with docs" you may write `CONTEXT.md` and ADRs, and only for decisions the user has already confirmed.

Phase 1 ends when the frontier is empty: every branch of the design tree visited, nothing left silently assumed.

If the user's invocation included "with docs" or "with documents", also invoke the `domain-modeling` skill inline as decisions crystallise: update `CONTEXT.md` when terms are resolved, and offer ADRs when decisions meet the ADR threshold (hard to reverse, surprising without context, result of a real trade-off).

Before the summary, run the subtraction pass (the size test above), then the verification pass:

{{FRAGMENT:verification-pass}}

Then:

1. Summarize all implementation decisions (not glossary terms) including the rationale for each — why that option was chosen over alternatives. Include the Silent and Notify decisions you made on the user's behalf, one compact line each, tagged `(auto)`. This is the audit point for everything you did not ask about.
2. List the **facts you established** at Gate 1 that the design now rests on — the ones the verification pass re-checked — each with its citation (`path:line`, doc, or spec). These cost real research and whoever implements would otherwise re-derive them — or worse, re-ask them. A fact the user contradicts here is cheaper to fix now than a decision built on it later.

Then go straight to Phase 2; do not ask the user for the next step.

## Phase 2 — Issues

Run the `to-issues` skill with the Phase 1 summary as its source: decisions, `(auto)` lines, facts and cut list. `to-issues` alone decides whether a PRD is written, and carries each part of the summary into its issues or PRD (its step 1). Complete its issue quiz and let it publish the approved issues.
