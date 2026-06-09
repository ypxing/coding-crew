# Issue tracker: Local Markdown

Issues and PRDs for this repo live as markdown files in `.scratch/`.

## Conventions

- One feature per directory: `.scratch/<feature-slug>/`
- The PRD is `.scratch/<feature-slug>/PRD.md`
- Implementation issues are `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`
- Triage state is recorded as a `Status:` line near the top of each issue file (see `triage-labels.md` for the role strings)
- Comments and conversation history append to the bottom of the file under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `.scratch/<feature-slug>/` (creating the directory if needed).

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or the issue number directly.

## When a skill says "mark the ticket done"

Before moving, verify all acceptance criteria in the issue file are satisfied:

1. Check each `- [ ]` criterion against the implemented code.
2. If all are met, check them off (`- [x]`) and move the file to `.scratch/<feature-slug>/issues/done/`.
3. If any are unmet, do NOT move the file. Instead, add a `## Unmet criteria` section explaining what's missing and why (descoped, blocked, moved to a new issue), and ask the user how to proceed.
