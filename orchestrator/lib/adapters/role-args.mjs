/** Per-platform, per-role extra CLI args: the settings that used to live in the agent files' frontmatter. */
export const ROLE_ARGS = {
  // The coder works alone in its worktree: no sub-agents.
  claude: { coder: ["--disallowedTools", "Agent"] },
  copilot: {},
};
