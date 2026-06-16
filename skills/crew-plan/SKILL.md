---
name: crew-plan
description: Full design pipeline — grill the user about a plan (crew-grill-me by default; crew-grill-with-docs if invoked with "with docs"), produce a PRD, then break it into issues. Use when starting a new feature from scratch.
---

Run the full design pipeline in three phases. Pause for user feedback within each phase, but do not ask the user to manually invoke the next skill — transition automatically.

## Phase 1 — Grill

If the user's invocation included "with docs" or "with documents", run the `crew-grill-with-docs` skill; otherwise run the `crew-grill-me` skill. At the end:

1. Summarize all implementation decisions (not glossary terms).
2. Save to `.scratch/<feature-slug>/decisions.md` (confirm the slug and get user consent first).
3. Ask once: **"Ready to write the PRD?"** If yes, continue to Phase 2. If no, stop.

## Phase 2 — PRD

Before running `crew-to-prd`, check whether `.scratch/<feature-slug>/decisions.md` exists and read it if so — it contains the resolved decisions from Phase 1 and must be used as primary input even if the grilling session is not fresh in context.

Run the `crew-to-prd` skill using the same feature slug and `decisions.md` as primary input. Do not re-ask the slug.

At the end of writing `PRD.md`, ask once: **"Ready to break this into issues?"** If yes, continue to Phase 3. If no, stop.

## Phase 3 — Issues

Run the `crew-to-issues` skill using the same feature slug and the `PRD.md` just written as primary input. Do not re-ask the slug or whether to run `/crew-to-prd` (it was just done).

Complete the issue quiz and write all approved issues to `.scratch/<feature-slug>/issues/`.
