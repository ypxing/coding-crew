Status: done

## Parent

PRD: `.scratch/no-commit-feature/PRD.md`

## What to build

Create the sprint configuration template file that projects install to control commit behavior defaults. This file allows project maintainers to set `auto_commit: yes` or `auto_commit: no` once, so team members don't need to remember flags on every invocation.

The file should:
- Be installed to `docs/agents/sprint-config.md` in consuming projects
- Default to `auto_commit: yes` for backward compatibility
- Include a note explaining that Claude Code ignores this setting (worktree isolation requires commits)
- Be registered in `registry.json` so `install.sh` copies it during agent installation

## Acceptance criteria

- [ ] `docs/agents/sprint-config.md` exists with `auto_commit: yes` default
- [ ] File includes clear note about Claude Code platform behavior
- [ ] `registry.json` includes entry under `"docs"` section for `sprint-config.md`
- [ ] Registry entry specifies install path as `docs/agents/sprint-config.md`
- [ ] File format matches other docs (issue-tracker.md, triage-labels.md) in style

## Blocked by

None - can start immediately
