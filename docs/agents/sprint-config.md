# Sprint Configuration

Controls default behavior for agent skills in this project.

## Commit behavior

auto_commit: yes

When set to `yes`, agent skills (`solve-issue`, `afk-sprint`, `address-pr-comments`, `address-code-review`) automatically commit changes after successful completion. When set to `no`, skills stage changes but leave them uncommitted for manual review.

**Note**: Claude Code always commits regardless of this setting. Worktree isolation requires commits to share dependencies between parallel tasks. This setting only affects GitHub Copilot CLI.

## CLI flags

Skills accept `--commit` and `--no-commit` flags to override this default on a per-invocation basis.

Precedence (highest to lowest):
1. CLI flags (`--commit` or `--no-commit`)
2. This config file (`auto_commit: yes/no`)
3. Hardcoded default: `yes`
