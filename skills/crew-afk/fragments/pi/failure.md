- `node: command not found` → needs Node ≥ 20, and stop.
- `cannot find crew-afk's scripts/ dir` → not installed here or in `$HOME`; install:
  `TARGET_REPO=$HOME ./install.sh pi --skill crew-afk`.
- Missing `crew-coder` / `crew-reviewer` → same re-install fixes it;
  `node "$CREW_AFK" doctor --platform pi` names what's absent.
- Any other non-zero exit → print its output and stop. Never finish the sprint by hand: a
  merge or close outside the pipeline skips the receipt gates keeping an unverified branch
  out of the feature branch.
