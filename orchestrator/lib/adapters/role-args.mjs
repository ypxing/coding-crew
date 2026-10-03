/** Per-platform, per-role extra CLI args: the settings that used to live in the agent files' frontmatter. */
export const ROLE_ARGS = {
  // The coder works alone in its worktree: no sub-agents.
  claude: { coder: ["--disallowedTools", "Agent"] },
  copilot: {},
  // pi names an allowlist; it ignores tool names it does not know, so these are pi's own.
  pi: {
    coder: ["--tools", "read,bash,edit,write"],
    reviewer: ["--tools", "read,bash"],
    triage: ["--tools", "read,bash"],
  },
  // Reasoning effort: review and triage are correctness judgements, the coder is steadier work.
  codex: {
    coder: ["-c", 'model_reasoning_effort="medium"'],
    reviewer: ["-c", 'model_reasoning_effort="high"'],
    triage: ["-c", 'model_reasoning_effort="high"'],
  },
};

/** codex's sandbox per role; a role not named here gets workspace-write. */
export const CODEX_SANDBOX = { coder: "workspace-write", reviewer: "read-only", triage: "read-only" };
