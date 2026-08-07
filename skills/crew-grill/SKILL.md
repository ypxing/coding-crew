---
name: crew-grill
description: Full design pipeline — grill the user about a plan (lite by default; add "with docs" to also update CONTEXT.md and ADRs via domain-modeling), produce a PRD, then break it into issues. Use when starting a new feature from scratch.
---

Run the full design pipeline in three phases. Pause for user feedback within each phase, but do not ask the user to manually invoke the next skill — transition automatically.

## Phase 1 — Grill

Interview the user relentlessly until you reach shared understanding. Map the plan as a **design tree**: every decision branches into the decisions that hang off it.

Work in **rounds**. The **frontier** is every decision whose prerequisites are already settled — what you can ask now without guessing at answers you haven't heard. A question that depends on another still-open question belongs to a later round, not this one.

Ask the frontier a few questions at a time (split it if it exceeds ~4), each formatted:

```
❓ **Q1** — **<decision title>**: <body, including options>

➡️ <your recommended answer>
```

Wait for answers before the next round; each round's answers reshape the tree and push the frontier outward.

When an answer rests on an unstated assumption, name it and ask what breaks if it's false before you treat the decision as settled.

Facts are your job, never the user's. Look up anything discoverable in the codebase; for expensive exploration, dispatch a sub-agent and meanwhile ask the frontier questions that don't depend on it. The *decisions* are the user's — put each one and wait.

**This phase is strictly exploratory.** Do NOT touch the product: no source edits, no new modules, no migrations, no dependency installs, no commits, no mutating commands. Read-only exploration is expected. Design artifacts are the one exception — under "with docs" you may write `CONTEXT.md` and ADRs, and only for decisions the user has already confirmed.

Phase 1 ends when the frontier is empty: every branch of the design tree visited, nothing left silently assumed.

If the user's invocation included "with docs" or "with documents", also invoke the `domain-modeling` skill inline as decisions crystallise: update `CONTEXT.md` when terms are resolved, and offer ADRs when decisions meet the ADR threshold (hard to reverse, surprising without context, result of a real trade-off).

Then:

1. Summarize all implementation decisions (not glossary terms) including the rationale for each — why that option was chosen over alternatives.
2. Ask once: **"Ready to write the PRD?"** If yes, continue to Phase 2. If no, stop.

## Phase 2 — PRD

Run the `to-prd` skill. Pass the decisions summary from Phase 1 as input — the PRD must include an **Decisions** section capturing each decision and its rationale, so implementation agents can read `PRD.md` as the single source of truth for both requirements and architectural choices.

At the end of writing `PRD.md`, ask once: **"Ready to break this into issues?"** If yes, continue to Phase 3. If no, stop.

## Phase 3 — Issues

Run the `to-issues` skill using the `PRD.md` just written as primary input. Do not re-ask the slug or whether to run `/to-prd` (it was just done).

Complete the issue quiz and write all approved issues to `.scratch/<feature-slug>/issues/`.
