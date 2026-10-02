---
name: write-pr
description: Write a pull request body a human reviewer can act on — Summary (the smallest diagram, diff-sketch or tree that makes the change clear), Evidence (before/after), Merge Danger (door and blast radius). Use when opening or updating a PR, or when asked to write or improve a PR description. Trigger with /write-pr.
argument-hint: "Optional base ref or PR number (defaults to the current branch against the repo's default branch)"
---

# Write PR

Adapted from mattpocock/skills' `pr` skill (after Dex Horthy's `show-me`, humanlayer/skills).

The reader is a reviewer deciding whether to merge. They have the diff; the body tells them what
shape the change has, why they can believe it works, and what breaks if it is wrong.

## 1. Gather

- **The range.** `git log --oneline <base>..HEAD` and `git diff --stat <base>..HEAD`, where
  `<base>` is the given ref, else `git merge-base HEAD origin/<default branch>`. Read the diff
  itself for the files that carry the change, not every file.
- **The intent.** A PRD, issue or plan the caller names, or that the commits reference
  (`Closes #n`, an issue slug, a `.scratch/<feature>/` path) — read it. The body explains the
  change in its terms.
- **The evidence.** Check results the caller hands you, and the tests the range adds or changes.
- **The vocabulary.** `CONTEXT.md` (or `GLOSSARY.md`) at the repo root, when present: use its
  terms.

Never invent evidence. A check you did not see run is not evidence.

## 2. Write

Use this template. Skip preambles; keep prose brief.

```markdown
## Summary

<one or two sentences: what changes, and why>

<diagram, diff-sketch, or tree>

## Evidence

- **Before:** <output / failing test / behaviour>
  **After:** <output / passing test / behaviour>

## Merge Danger

**Door:** <one-way or two-way>

<optional: why>

**Blast Radius:** <one word>

<optional: what a bad merge would break>
```

### Summary

Pick the **smallest** view that makes the key point clear — usually one, rarely more than two:

- Logic or an algorithm → pseudocode.
- Runtime control flow → a call tree (`caller` / indented `callee`).
- File responsibility or a broad refactor → a shallow file tree with one-line `# roles`.
- Interaction or data flow between components → a Mermaid `sequenceDiagram` or `flowchart`.
- What changes in a shape that already exists → a ` ```diff ` block of that shape (call tree,
  file tree, state machine, config) with `+`/`-` lines, not a code diff.
- The whole block, only when most of it is new or a reader needs the exact target shape.

Keep only the calls, files, states and boundaries the point needs. A large change is shown as its
two or three moving parts, not as an inventory of every file.

### Evidence

Show a before and after. Best first: a screenshot (a visual change, when the environment can take
one); execution — the exact test that failed before and passes now (as pseudocode when long), or
console output; a check run, named with its result. When there is no before (a new capability),
show the after alone. When there is no evidence, say so in one line rather than padding.

### Merge Danger

- **Door:** two-way when a revert fully undoes it; one-way when it migrates data, deletes,
  publishes, changes a public contract consumers adopt, or is otherwise hard to walk back.
- **Blast Radius:** one word — e.g. `none`, `local`, `module`, `consumers`, `everyone` — then,
  if not obvious, what would break: consumers, installs, CI, a platform, data.

## 3. Deliver

- **The caller named an output** (a file, or "print it"): write exactly the body there — no
  fence around it, nothing before `## Summary` — and stop. Do not commit, push or call `gh`.
- **Otherwise:** show the body, then offer to apply it with `gh pr create --body-file <file>` (no
  PR for the branch yet) or `gh pr edit <pr> --body-file <file>`. Keep every `Closes #n` line the
  current body has — they close the issues on merge. A `<!-- crew-afk:begin -->` …
  `<!-- crew-afk:end -->` block is crew-afk's and is rewritten on its next run: put your body
  in it, between the markers, above its `Closes` lines.
