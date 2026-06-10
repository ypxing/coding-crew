---
name: plan-sprint
description: Full design pipeline — grill the user about a plan, produce a PRD, then break it into issues. One handoff at the end of grilling triggers the rest automatically. Use when starting a new feature from scratch.
---

Run the full design pipeline in three phases. Pause for user feedback within each phase, but do not ask the user to manually invoke the next skill — transition automatically.

## Phase 1 — Grill

Run the `grill-with-docs` skill in full. At the end:

1. Summarize all implementation decisions (not glossary terms).
2. Save to `.scratch/<feature-slug>/decisions.md` (confirm the slug and get user consent first).
3. Ask once: **"Ready to write the PRD?"** If yes, continue to Phase 2. If no, stop.

## Phase 2 — PRD

Run the `to-prd` skill using the same feature slug and `decisions.md` as primary input. Do not re-ask the slug.

At the end of writing `PRD.md`, ask once: **"Ready to break this into issues?"** If yes, continue to Phase 3. If no, stop.

## Phase 3 — Issues

Run the `to-issues` skill using the same feature slug and the `PRD.md` just written as primary input. Do not re-ask the slug or whether to run `/to-prd` (it was just done).

Complete the issue quiz and write all approved issues to `.scratch/<feature-slug>/issues/`.
