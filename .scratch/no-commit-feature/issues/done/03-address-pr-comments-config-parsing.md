Status: done

## Parent

PRD: `.scratch/no-commit-feature/PRD.md`

## What to build

Add `--commit` and `--no-commit` flag support to the `address-pr-comments` skill. When `--no-commit` is used, the skill stages fixes but skips the commit step, allowing users to review the agent's PR comment responses before committing.

Implement the same three-level precedence as solve-issue: flags → config → default (yes).

Modify Step 5 to always stage touched files, then conditionally create the commit with the standard message format.

## Acceptance criteria

- [ ] Step 5 parses flags and config file using correct precedence
- [ ] Step 5 always stages files touched during Step 4
- [ ] Step 5 conditionally commits based on parsed preference
- [ ] When committing, uses standard message: "address PR review comments" with bullet list
- [ ] When not committing, leaves changes staged for manual review
- [ ] Documentation includes examples of both flag usages

## Blocked by

- `.scratch/no-commit-feature/issues/01-create-sprint-config-file.md` (needs config file to parse)
