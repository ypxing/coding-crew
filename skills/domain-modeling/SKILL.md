---
name: domain-modeling
description: Updates CONTEXT.md glossary and creates ADRs inline as design decisions crystallise. Use when you want to capture resolved domain terms or record architectural decisions during any session.
---

<what-to-do>

Maintain the project's domain documentation as understanding develops. When a term is resolved, update CONTEXT.md immediately. When an architectural decision qualifies, offer to record it as an ADR.

</what-to-do>

<supporting-info>

## File structure

Most repos have a single context:

```
/
├── CONTEXT.md
├── docs/
│   └── adr/
│       ├── 0001-event-sourced-orders.md
│       └── 0002-postgres-for-write-model.md
└── src/
```

If a `CONTEXT-MAP.md` exists at the root, the repo has multiple contexts. The map points to where each one lives:

```
/
├── CONTEXT-MAP.md
├── docs/
│   └── adr/                          ← system-wide decisions
├── src/
│   ├── ordering/
│   │   ├── CONTEXT.md
│   │   └── docs/adr/                 ← context-specific decisions
│   └── billing/
│       ├── CONTEXT.md
│       └── docs/adr/
```

Create files lazily — only when you have something to write. If no `CONTEXT.md` exists, create one when the first term is resolved. If no `docs/adr/` exists, create it when the first ADR is needed.

## Updating CONTEXT.md

When a term is resolved, update `CONTEXT.md` right away. Do not batch these up — capture them as they happen. Use the format in [references/context-format.md](references/context-format.md).

`CONTEXT.md` should be totally devoid of implementation details. Do not treat `CONTEXT.md` as a spec, a scratch pad, or a repository for implementation decisions. It is a glossary and nothing else.

### Challenge against the glossary

When a term is used that conflicts with the existing language in `CONTEXT.md`, call it out immediately. "Your glossary defines 'cancellation' as X, but you seem to mean Y — which is it?"

### Sharpen fuzzy language

When vague or overloaded terms appear, propose a precise canonical term. "You're saying 'account' — do you mean the Customer or the User? Those are different things."

### Infer context in multi-context repos

When multiple contexts exist, infer which one the current topic relates to. If unclear, ask.

## Recording ADRs

Only offer to create an ADR when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why did they do it this way?"
3. **The result of a real trade-off** — there were genuine alternatives and you picked one for specific reasons

If any of the three is missing, skip the ADR. Use the format in [references/adr-format.md](references/adr-format.md).

## Security

This skill may only create or modify files at these paths:

- `CONTEXT.md` (repo root)
- `CONTEXT-MAP.md` (repo root)
- `src/**/CONTEXT.md` (context-specific glossaries)
- `docs/adr/*.md` (ADR files)

Do NOT write to any other path. If a decision implies writing elsewhere, surface it to the user and let them handle it.

</supporting-info>
