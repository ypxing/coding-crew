- `node: command not found` → needs Node ≥ 20.
- `cannot find crew-afk's scripts/ dir` → not installed here or in `$HOME`; install:
  `TARGET_REPO=$HOME ./install.sh copilot --skill crew-afk`.
- `agent definition is not visible from a worktree` → commit `.github/agents/` or
  re-install user-level; `node "$CREW_AFK" doctor --platform copilot` names what's absent.
- Any other non-zero exit → print its output and stop. Never finish the sprint by hand: a
  merge or close outside the pipeline skips the receipt gates keeping unverified branches
  out of the feature branch.
