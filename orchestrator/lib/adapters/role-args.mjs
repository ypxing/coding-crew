/** Per-platform, per-role extra CLI args: the settings that used to live in the agent files' frontmatter. */
// The reviewer and triage are read-only (their removed agent files listed only read tools).
const CLAUDE_READ_ONLY = ["--disallowedTools", "Edit", "Write", "NotebookEdit"];
const COPILOT_READ_ONLY = ["--deny-tool", "write"];

export const ROLE_ARGS = {
  // The coder works alone in its worktree: no sub-agents.
  claude: { coder: ["--disallowedTools", "Agent"], reviewer: CLAUDE_READ_ONLY, triage: CLAUDE_READ_ONLY },
  copilot: { reviewer: COPILOT_READ_ONLY, triage: COPILOT_READ_ONLY },
};
