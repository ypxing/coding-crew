Status: done

## Parent

PRD: `.scratch/no-commit-feature/PRD.md`

## What to build

Add `--commit` and `--no-commit` flag support to the `address-code-review` skill. When `--no-commit` is used, the skill stages fixes but skips the commit and report archival steps, allowing users to review the agent's fixes before committing.

Implement the same three-level precedence as solve-issue: flags → config → default (yes).

Modify Step 5 to always stage touched files, then conditionally commit. Make Step 5b (report archival) conditional—only archive when a commit was successfully created. This prevents the report from being archived when changes are still under review.

## Acceptance criteria

- [ ] Step 5 parses flags and config file using correct precedence
- [ ] Step 5 always stages files touched during Step 4
- [ ] Step 5 conditionally commits based on parsed preference
- [ ] Step 5b only runs (archives report) when commit preference was `yes` AND commit succeeded
- [ ] When not committing, report stays in place for re-run after manual commit
- [ ] Re-running after manual commit archives the report
- [ ] Documentation includes examples of both flag usages

## Blocked by

- `.scratch/no-commit-feature/issues/01-create-sprint-config-file.md` (needs config file to parse)
