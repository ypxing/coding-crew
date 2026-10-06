---
name: write-pr
description: Write a short pull request title and body a human reviewer can act on — Why (2–4 sentences), What changes (3–6 high-level bullets), Risk (one line) and Tested (one line). Use when opening or updating a PR, or when asked to write or improve a PR description. Trigger with /write-pr.
argument-hint: "Optional base ref or PR number (defaults to the current branch against the repo's default branch)"
---

# Write PR

The reader is a reviewer deciding whether to merge. They have the diff; the body tells them why
the change exists, what it changes at a high level, and what a bad merge would cost — briefly.

## 1. Gather

- **The intent.** A PRD, issue or plan the caller names, or that the commits reference
  (`Closes #n`, an issue slug, a `.scratch/<feature>/` path) — read it. The body explains the
  change in its terms.
- **The range.** `git log --oneline <base>..HEAD` and `git diff --stat <base>..HEAD`, where
  `<base>` is the given ref, else `git merge-base HEAD origin/<default branch>`. Read the diff
  itself only when there is neither a PRD nor an issue to say what the change is for.
- **The checks.** Check results the caller hands you.
- **The vocabulary.** `CONTEXT.md` (or `GLOSSARY.md`) at the repo root, when present: use its
  terms.

Never invent a result. A check you did not see run is not one.

## 2. Write

Use this template. No preamble, no section beyond these.

```markdown
# <title>

## Why

<2–4 sentences from the PRD or issue: the problem, and what this change does about it>

## What changes

- <3–6 high-level bullets — behaviour and shape, not a file inventory>

<optional: at most one small diagram, when a bullet cannot carry the point>

## Risk

<one line: whether a revert fully undoes it, and what breaks if it is wrong>

**Tested:** <one line: the checks that ran and their result, or "not run">
```

### Title

What the change does for its user, in their terms — not the branch name, a slug, or an issue
number. Imperative, at most 72 characters: `Run the full test suite once per branch, not per issue`,
not `single-full-check`.

### What changes

Each bullet is one thing a reviewer would notice — a behaviour, a contract, a moved
responsibility — not one per file. A diagram earns its place only when the change is a flow or a
shape a sentence cannot hold; keep it to the few nodes the point needs.

Describe what the range does, not what the PRD asked for: a bullet that names a file, doc or
setting needs a matching path in the `--stat`, and a PRD decision with nothing there is left out,
not claimed done.

### Risk

One line. Say whether a revert fully undoes it (it does not when it migrates data, deletes,
publishes, or changes a public contract consumers adopt), then what breaks if it is wrong:
consumers, installs, CI, a platform, data — or `none beyond this module`.

## 3. Deliver

- **The caller named an output** (a file, or "print it"): write exactly the `# <title>` line
  and the body there — no fence around them, nothing before the title — and stop. Do not
  commit, push or call `gh`.
- **Otherwise:** show the title and body, then offer to apply them with
  `gh pr create --title <title> --body-file <file>` (no PR for the branch yet) or
  `gh pr edit <pr> --title <title> --body-file <file>`, the body without its `# <title>` line. Keep every `Closes #n` line the
  current body has — they close the issues on merge. A `<!-- crew-afk:begin -->` …
  `<!-- crew-afk:end -->` block is crew-afk's and is rewritten on its next run: put your body
  in it, between the markers, above its `Closes` lines.
