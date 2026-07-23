---
name: crew-grill
description: Full design pipeline — grill the user about a plan (lite by default; add "with docs" to also update CONTEXT.md and ADRs via domain-modeling), produce a PRD, then break it into issues. Use when starting a new feature from scratch.
---

Run the full design pipeline in three phases. Pause for user feedback within each phase, but do not ask the user to manually invoke the next skill — transition automatically.

## Phase 1 — Grill

Interview the user relentlessly about every aspect of their plan until reaching shared understanding. Walk down each branch of the decision tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each question before continuing. Asking multiple questions at once is bewildering.

If a *fact* can be found by exploring the codebase, look it up rather than asking. The *decisions*, though, belong to the user — put each one and wait for their answer.

**This phase is strictly exploratory.** Do NOT write code, create files, edit source files, run commands, or begin implementation. Your only job is to ask questions and reach shared understanding.

If the user's invocation included "with docs" or "with documents", also invoke the `domain-modeling` skill inline as decisions crystallise: update `CONTEXT.md` when terms are resolved, and offer ADRs when decisions meet the ADR threshold (hard to reverse, surprising without context, result of a real trade-off).

At the end of the grilling:

1. Summarize all implementation decisions (not glossary terms) including the rationale for each — why that option was chosen over alternatives.
2. Ask once: **"Ready to write the PRD?"** If yes, continue to Phase 2. If no, stop.

## Phase 2 — PRD

Run the `to-prd` skill. Pass the decisions summary from Phase 1 as input — the PRD must include an **Decisions** section capturing each decision and its rationale, so implementation agents can read `PRD.md` as the single source of truth for both requirements and architectural choices.

At the end of writing `PRD.md`, ask once: **"Ready to break this into issues?"** If yes, continue to Phase 3. If no, stop.

## Phase 3 — Issues

Run the `to-issues` skill using the `PRD.md` just written as primary input. Do not re-ask the slug or whether to run `/to-prd` (it was just done).

Complete the issue quiz and write all approved issues to `.scratch/<feature-slug>/issues/`.
