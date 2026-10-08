---
name: crew-grill
description: Full design pipeline — grill the user about a plan (lite by default; add "with docs" to also update CONTEXT.md and ADRs via domain-modeling), then hand the result to to-issues, which writes a PRD only when the work splits. Use when starting a new feature from scratch.
---

Run the full design pipeline in two phases. Pause for user feedback within each phase, but do not ask the user to manually invoke the next skill — transition automatically.

{{FRAGMENT:tracker-configuration}}

## Phase 1 — Grill

Interview the user relentlessly until you reach shared understanding. Map the plan as a **design tree**: every decision branches into the decisions that hang off it.

### Root: size the problem before any solution

The tree's root is the problem, not the solutions on offer. Before any solution node, establish the **problem size**: how often it happens, what the manual workaround costs today, and what goes wrong if nothing is done. These are mostly facts (git history, the tracker, the code), so Gate 1 applies — look them up (`git log`, merged PRs, the issue list), cite them, and ask only what no source holds. Never ask the user how often something happens when the history can count it. Candidate solutions the user brings with them are inputs to this tree, not its frontier: the smallest change that removes the cost you measured is the baseline every larger option has to beat.

{{FRAGMENT:design-standard}}

{{FRAGMENT:light-path}}

### Rounds and gates

Work in **rounds**. The **frontier** is every decision whose prerequisites are already settled — what you can ask now without guessing at answers you haven't heard. A question that depends on another still-open question belongs to a later round, not this one.

Every frontier node passes two gates, in order. Gate 1 asks whether the question deserves to exist at all; Gate 2 asks who owns it. Most bad questions die at Gate 1, and Gate 2 cannot catch them — routing decides who owns a genuine fork, it never asks whether the node is a fork at all.

### Gate 1 — Competence: does this question deserve to exist?

Facts are your job, never the user's. Test every node with:

> Would a staff engineer on this team need to ask this — or would they be embarrassed to?

They'd be embarrassed to ask anything that is:

- **Discoverable** — answerable from the codebase, the project's own docs, a dependency's or vendor's documentation, or the open web.
- **Already answered** — stated earlier in this conversation, or in the plan, PRD, or issue you were handed.
- **Testable** — settled by a read-only experiment: run the test, grep the tree, check what the API actually does.
- **Conventional** — settled by a dominant ecosystem convention, or by one clear in-repo precedent.
- **Analysis** — "will this scale?", "which is faster?", "is this safe?" The user's answer would be a guess; the reasoning is yours to do.
- **Deferrable** — not needed to write the PRD, surfaces naturally at implementation time, and cheap to reverse then.
- **Rubber-stamp** — you recommend X, X is plainly right, and you are asking permission rather than asking for a decision.

Ignorance of anything outside the repo is not a reason to ask — it is a reason to go read. Before any question that turns on third-party behaviour (a library's API, a service's limits, a format's spec), look it up; that answer is never the user's to give. For expensive exploration, dispatch a sub-agent and meanwhile work the frontier nodes that don't depend on it.

A node that fails Gate 1 is not a question. Go get the answer, record it as a fact, and keep expanding the tree. A decision with one dominant answer is likewise not a decision — it is a fact lookup plus a default, and it is yours. Genuine forks are the user's.

### Gate 2 — Consequence: whose decision is it?

Of the nodes that survive Gate 1, not every one is the user's to decide. Route each with a single counterfactual:

> If I decide this myself and the user only finds out at review time — would they be annoyed I didn't ask?

| Answer           | Lane       | User sees                                      |
| ---------------- | ---------- | ---------------------------------------------- |
| Annoyed          | **Ask**    | full `❓` + `➡️` treatment, and you wait       |
| Mildly surprised | **Notify** | one FYI line, no response required             |
| Wouldn't care    | **Silent** | nothing — recorded in the Phase 1 summary only |

They'd be **annoyed** about: schema, migrations, and data model; auth, permissions, and PII; anything that costs money or moves scope; user-visible behaviour; **breaking** an external contract we already ship; and **conflicting** in-repo precedent (two live patterns means the user picks the winner, not you). Note the fact/decision split on contracts: *what the wire format requires* is a lookup you owe (Gate 1), *which of our shipped formats we break* is a decision you owe the user.

They **wouldn't care** about: naming, ordering, file placement, and anything already settled by an existing repo pattern or a dominant ecosystem convention. A claimed precedent must cite its source — `path:line` for the repo, the doc or spec for a convention. An uncited precedent is not a precedent, so route it as Notify or Ask. A node whose every answer leads to the same plan is not a decision either: resolve it and leave it Silent.

**Escalation is cheap; silence is expensive.** Torn between Silent and Notify, choose Notify. Torn between Notify and Ask, choose Ask. This trades between lanes only — it never resurrects a node that failed Gate 1.

Do not report Silent decisions in-flight. Listing trivia for the user to check merely trades a questioning burden for a reporting burden. If more than ~3 Notify lines pile up in one round, most of them were really Silent — collapse the excess to a count.

### Ask

Ask only the Ask lane, and only as many questions as the frontier genuinely blocks on — hard ceiling ~4, split the round if you exceed it. Format each:

```
🔎 Decided on your behalf: <decision> → <choice> (<why it's safe to reverse>).

❓ **Q1** — **<decision title>** · checked: <path:line | doc or URL | conversation | tried it>
<body, including options and what each one forecloses>

➡️ <your recommended answer>
```

Every question that decides how much to build — not a fact only the user holds — includes the **do-least option** — the smallest change, down to "do it by hand" or "leave it" — with its cost in the terms of the problem size. Recommending anything larger needs evidence that the do-least option falls short — on the measured problem, or because it would leave what is built worse structured (see the Root section); "it doesn't cover every case" is not that evidence unless the uncovered case is costly. When an option drags in follow-on components or decisions, its body names them ("(b) brings a workflow, a selector and a label protocol"): the Silent decisions it spawns are part of its price, and the user never sees them one by one.

**Sizing and the do-least option never replace asking.** Good questions are the point of the grill: ask every question only the user can answer and that would change the design — who it is for, what is at stake, which constraint is real, which of two live patterns wins. The do-least option is one choice *inside* a question, there to make the price of the larger options visible; it is not a reason to skip the question, and it is not a verdict. What the user stated as a requirement is a given: price it, never relitigate it, and do not recommend against it without new evidence from the repo. Challenge a stated requirement only with a question ("is X enough, or do you need Y?"), never by quietly deciding for them.

The `checked:` clause is Gate 1's receipt: it names what you consulted and, by implication, why that source didn't settle the question. If the clause would read "nothing," the node isn't ready to be asked — it's ready to be researched.

That ceiling is a budget, not a target. Trivia spends slots that consequential questions need — worse, a batch padded with trivia trains the user to skim, so they skim the one that mattered too. Before you send a round, drop its weakest question outright and spend the freed slot deepening the strongest: sub-questions on the consequential fork, and the assumption-probing below.

When an answer rests on an unstated assumption, name it and ask what breaks if it's false before you treat the decision as settled.

Wait for answers before the next round; each round's answers reshape the tree and push the frontier outward. A node you resolved yourself unblocks its children immediately, so keep expanding within the round until a genuine Ask blocks the frontier — then put the whole round at once.

A round that produces zero questions while touching an _annoyed_ topic is worth a second look at both gates — but a node discharged at Gate 1 with a citation is a legitimate zero, not a smell. If the user overrides a decision you made, re-check anything you derived from it.

**This phase is strictly exploratory.** Do NOT touch the product: no source edits, no new modules, no migrations, no dependency installs, no commits, no mutating commands. Read-only exploration is expected. Design artifacts are the one exception — under "with docs" you may write `CONTEXT.md` and ADRs, and only for decisions the user has already confirmed.

Phase 1 ends when the frontier is empty: every branch of the design tree visited, nothing left silently assumed.

If the user's invocation included "with docs" or "with documents", also invoke the `domain-modeling` skill inline as decisions crystallise: update `CONTEXT.md` when terms are resolved, and offer ADRs when decisions meet the ADR threshold (hard to reverse, surprising without context, result of a real trade-off).

Before the summary, run a **subtraction pass** over what the design contains: for each decision and component, name the part of the measured problem, or the structural property of what is built now (see the Root section), that breaks if it is removed. "Another component needs it" is not an answer — follow the chain to its root and judge the root against the problem size; when a chain's root only saves what the do-least option covers cheaply, show the chain with its total price and ask once whether to keep it, even if the user approved the root earlier. "Nothing breaks" is a claim of fact: check it like one (Gate 1) and cite it, or keep the item. If nothing breaks, propose cutting it. Show the cut list in the summary, so the user can restore anything they want back; what stays cut goes to the PRD's Out of Scope, with the reason. Alternatives never proposed are not cuts — they go straight to Out of Scope.

{{FRAGMENT:verification-pass}}

Then:

1. Summarize all implementation decisions (not glossary terms) including the rationale for each — why that option was chosen over alternatives. Include the Silent and Notify decisions you made on the user's behalf, one compact line each, tagged `(auto)`. This is the audit point for everything you did not ask about.
2. List the **facts you established** at Gate 1 that the design now rests on — the ones the verification pass re-checked — each with its citation (`path:line`, doc, or spec). These cost real research and an implementing agent would otherwise re-derive them — or worse, re-ask them. A fact the user contradicts here is cheaper to fix now than a decision built on it later.
3. Hand off: run the `to-issues` skill, passing this summary (decisions, `(auto)` lines, facts, cut list). `to-issues` alone decides whether a PRD is written, and its issues or PRD must keep what only this summary holds: carry the `(auto)` decisions through, since they were never put to the user and a reviewer can catch them only there; carry the established facts and their citations through as well; the cut list goes to Out of Scope, each item with why it was cut, so an implementer does not re-add it. Do not ask the user for the next step.

## Phase 2 — Issues

Run the `to-issues` skill with the Phase 1 summary as its source. Complete its issue quiz and let it publish the approved issues.
