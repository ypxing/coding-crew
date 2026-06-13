Status: done

## Parent

PRD: `.scratch/no-commit-feature/PRD.md`

## What to build

Add `--commit` and `--no-commit` flag support to the `solve-issue` skill. When `--no-commit` is used, the skill stages changes but skips the commit and "mark done" steps, allowing users to review before committing manually.

Implement three-level precedence:
1. CLI flags override everything
2. Config file value (`docs/agents/sprint-config.md`) if no flag
3. Default to `yes` if neither exists

Modify Step 6 to always stage files, then conditionally commit. Modify Step 7 to only mark done if a commit was made. Support re-running after manual commit to mark the issue done.

## Acceptance criteria

- [ ] Step 6 parses flags and config file using correct precedence
- [ ] Step 6 always stages modified files (`git add <files>`)
- [ ] Step 6 conditionally commits based on parsed preference
- [ ] Step 7 skips "mark done" when `--no-commit` was used
- [ ] Re-running after manual commit detects committed state and marks done
- [ ] If checks fail, nothing is staged (current behavior preserved)
- [ ] Documentation includes examples of both flag usages

## Blocked by

- `.scratch/no-commit-feature/issues/01-create-sprint-config-file.md` (needs config file to parse)
