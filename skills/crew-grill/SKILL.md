---
name: crew-grill
description: Full design pipeline — grill the user about a plan (lite by default; add "with docs" to also update CONTEXT.md and ADRs via domain-modeling), produce a PRD, then break it into issues. Use when starting a new feature from scratch.
---

Run the full design pipeline in three phases. Pause for user feedback within each phase, but do not ask the user to manually invoke the next skill — transition automatically.

## Phase 1 — Grill

Interview the user relentlessly until you reach shared understanding. Map the plan as a **design tree**: every decision branches into the decisions that hang off it.

Work in **rounds**. The **frontier** is every decision whose prerequisites are already settled — what you can ask now without guessing at answers you haven't heard. A question that depends on another still-open question belongs to a later round, not this one.

### Route every frontier node before you ask it

Not every node on the frontier is the user's to decide. Route each one with a single counterfactual:

> If I decide this myself and the user only finds out at review time — would they be annoyed I didn't ask?

| Answer           | Lane       | User sees                                      |
| ---------------- | ---------- | ---------------------------------------------- |
| Annoyed          | **Ask**    | full `❓` + `➡️` treatment, and you wait       |
| Mildly surprised | **Notify** | one FYI line, no response required             |
| Wouldn't care    | **Silent** | nothing — recorded in the Phase 1 summary only |

They'd be **annoyed** about: schema, migrations, and data model; wire formats and external contracts; auth, permissions, and PII; anything that costs money or moves scope; user-visible behaviour; and **conflicting** in-repo precedent (two live patterns means the user picks the winner, not you).

They **wouldn't care** about: naming, ordering, file placement, and anything already settled by an existing repo pattern. A claimed repo precedent must cite `path:line` — an uncited precedent is not a precedent, so route it as Notify or Ask.

**Escalation is cheap; silence is expensive.** Torn between Silent and Notify, choose Notify. Torn between Notify and Ask, choose Ask.

Do not report Silent decisions in-flight. Listing trivia for the user to check merely trades a questioning burden for a reporting burden. If more than ~3 Notify lines pile up in one round, most of them were really Silent — collapse the excess to a count.

### Ask

Ask only the Ask lane, a few at a time (split it if it exceeds ~4), each formatted:

```
🔎 Decided on your behalf: <decision> → <choice> (<why it's safe to reverse>).

❓ **Q1** — **<decision title>**: <body, including options>

➡️ <your recommended answer>
```

That ~4 is a fixed budget, and trivia spends slots that consequential questions need — worse, a batch padded with trivia trains the user to skim, so they skim the one that mattered too. Spend the freed budget on **depth** instead of breadth: sub-questions on the consequential fork, and the assumption-probing below.

When an answer rests on an unstated assumption, name it and ask what breaks if it's false before you treat the decision as settled.

Wait for answers before the next round; each round's answers reshape the tree and push the frontier outward. A node you resolved yourself unblocks its children immediately, so keep expanding within the round until a genuine Ask blocks the frontier — then put the whole round at once.

A round that produces zero questions while touching an _annoyed_ topic is a smell: re-examine your routing before continuing. If the user overrides a decision you made, re-check anything you derived from it.

Facts are your job, never the user's. Look up anything discoverable in the codebase; for expensive exploration, dispatch a sub-agent and meanwhile ask the frontier questions that don't depend on it. A decision with one dominant answer is not a decision — it is a fact lookup plus a default, and it is yours. Genuine forks are the user's: put each one and wait.

**This phase is strictly exploratory.** Do NOT touch the product: no source edits, no new modules, no migrations, no dependency installs, no commits, no mutating commands. Read-only exploration is expected. Design artifacts are the one exception — under "with docs" you may write `CONTEXT.md` and ADRs, and only for decisions the user has already confirmed.

Phase 1 ends when the frontier is empty: every branch of the design tree visited, nothing left silently assumed.

If the user's invocation included "with docs" or "with documents", also invoke the `domain-modeling` skill inline as decisions crystallise: update `CONTEXT.md` when terms are resolved, and offer ADRs when decisions meet the ADR threshold (hard to reverse, surprising without context, result of a real trade-off).

Then:

1. Summarize all implementation decisions (not glossary terms) including the rationale for each — why that option was chosen over alternatives. Include the Silent and Notify decisions you made on the user's behalf, one compact line each, tagged `(auto)`. This is the audit point for everything you did not ask about.
2. Ask once: **"Ready to write the PRD?"** If yes, continue to Phase 2. If no, stop.

## Phase 2 — PRD

Run the `to-prd` skill. Pass the decisions summary from Phase 1 as input — the PRD must include an **Decisions** section capturing each decision and its rationale, so implementation agents can read `PRD.md` as the single source of truth for both requirements and architectural choices. Carry the `(auto)` decisions through into that section too: they were never put to the user, so the PRD is the only place a reviewer can catch them.

At the end of writing `PRD.md`, ask once: **"Ready to break this into issues?"** If yes, continue to Phase 3. If no, stop.

## Phase 3 — Issues

Run the `to-issues` skill using the `PRD.md` just written as primary input. Do not re-ask the slug or whether to run `/to-prd` (it was just done).

Complete the issue quiz and write all approved issues to `.scratch/<feature-slug>/issues/`.
