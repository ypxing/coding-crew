### Findings rubric

Classify every review finding as exactly one of:

- **Actionable** — the concern is valid, and the fix is local, unambiguous, and changes no public contract (an exported API, CLI flag, config key, file format, schema or wire shape). The fix may differ from the one the reviewer proposed.
- **Debatable** — the concern has merit but the proposed change is questionable: the fix is ambiguous, spreads across modules, or changes a public contract, or one of the hard rules below applies. State the counter-argument.
- **Dismiss** — the concern is wrong, stylistic noise, or already handled elsewhere (including fixed in a later commit). Say why.

Hard rules — a finding is **Debatable** whatever its merit or severity when:

1. its fix would contradict an ADR or `CONTEXT.md` — a documented architecture or domain decision; or
2. its fix would touch a protected path: CI config (`.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`), auth or security modules, deployment scripts, `.env` files, or files containing secrets; or
3. its only basis is the design standard — no failure beyond a criterion of `skills/_shared/fragments/design-standard.md` (a design-only finding).

Before judging, read the referenced file at the cited lines, and ask: is the reviewer right? Is their fix the simplest, or is there a more idiomatic one? Does it fit the project's conventions and domain language? Could it introduce a regression? Was it already fixed? Steelman the concern before you dismiss it — never Dismiss a finding because acting on it is inconvenient. Give each finding a one-line rationale.
