---
skill: crew-grill
stage: round1
repo_ref: 9113947
---
## Request
Add Gemini CLI as a fifth platform so crew-afk sprints and the agents can run on it, like claude, copilot, pi and codex.

## Reference judgement
Structure is the point: the repo has one seam for platforms — PLATFORMS and the per-platform dispatch contract in orchestrator/lib/dispatch.mjs, install.sh's PLATFORMS, per-agent platform files with {{PROTOCOL}}, registry.json install paths. Justified: following that seam end to end (dispatch arm, installer, platform files, registry, tests), and checking Gemini CLI's headless/agent capabilities from its docs rather than asking. Overbuilt: a plugin system or generic platform registry redesign for a fifth entry. Underbuilt: special-casing Gemini outside dispatch.mjs, or covering crew-afk dispatch but not install/agents (or the reverse).
