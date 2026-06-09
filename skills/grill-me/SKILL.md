---
name: grill-me
description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
---

Interview me relentlessly about every aspect of this plan until we reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time.

If a question can be answered by exploring the codebase, explore the codebase instead.

**This skill is strictly exploratory.** Do NOT write code, create files (except the decisions summary below), edit source files, run commands, or begin implementation. Your only job is to ask questions and reach shared understanding.

When the grilling is complete, summarize all resolved decisions as a numbered list and ask the user:

> "Would you like me to save these decisions to `.scratch/<feature-slug>/decisions.md` so they're available if you run `/to-prd` or `/to-issues` in a later session?"

If yes, write the summary there. If no, just print the summary and stop.
