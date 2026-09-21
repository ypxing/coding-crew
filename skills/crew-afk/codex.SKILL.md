---
name: crew-afk
description: >
  Implements all ready-for-agent issues by dispatching each to a crew-coder subagent (a separate
  `codex exec` process per worktree), then housekeeping the result. Loops until no issues remain
  or all stall; reviews every branch before merge. Optional: --model <alias|inherit>; --coverage;
  --promote critical-high.
---

# AFK Issue Sprint — Codex

The sprint is a program, not a prompt: launch it, stream its output, report what it
printed. **You do not orchestrate, implement, review, merge or close anything
yourself.**

```bash
CREW_AFK="$(git rev-parse --show-toplevel)/.coding-crew/crew-afk/main.mjs"
[ -f "$CREW_AFK" ] || CREW_AFK="$HOME/.coding-crew/crew-afk/main.mjs"
node "$CREW_AFK" run --platform codex "$@"
```

Pass CLI-looking arguments straight through — `--model`, `--coverage`, `--max-parallel N`,
`--jira TICKET-123`, a `.scratch/<feature-slug>/…` path — never rewrite those. A bare
word, typo, or free-form phrase is resolved first, below.

## Resolving the sprint target

If the trailing arguments aren't CLI syntax, look up what exists first:

```bash
ls -d .scratch/*/ 2>/dev/null
grep -rl "Status: ready-for-agent" .scratch/*/issues/open/*.md 2>/dev/null
```

Match against those names (exact, fuzzy/typo, then issue content). One match →
`--feature-slug <slug>`, say what you inferred, then run. No match → don't run; point at
`crew-grill`, `crew-brainstorm`, or `to-issues`. Multiple matches → ask which one. Never
create a new `.scratch/<slug>` directory, and never guess — a wrong resolution dispatches,
merges, and closes real work against the wrong feature.

It owns the whole loop: a worktree and `crew-coder` process per issue, then verify →
review → merge → close, then promotion, squash, cleanup and the summary — until no issues
remain or every remaining one is blocked (its retries spent, or a dependency of one that is).

**Requires the local Codex CLI.** Every worker is a `codex exec` child process against a
local clone, so `codex` must be on `PATH` and already authenticated — if not, say so and
stop rather than implementing issues yourself.

## Your part

1. Resolve the target first if needed, then launch **in the background** — a dispatch can
   run up to 45 minutes — with `--dry-run` first only if the user asked what it would do.
2. Poll and relay each new line; `[STEP]` lines and a throttled heartbeat go to
   **stderr**, so read that too. **If `HERDR_ENV=1`, skip polling** — this pane is
   prompted directly once the sprint finishes or stalls. The printed summary is the
   report — don't rewrite it.
3. Mention `.scratch/<feature-slug>/traces/orchestrator.log` if asked.
4. Report the exit code and stop: `0` finished, `2` stalled (blockers need a human), `3`
   no ready issues, `1` setup problem — print its stderr verbatim.

## Failure handling

- `node: command not found` → needs Node ≥ 20, and stop.
- `cannot find crew-afk's scripts/ dir` → not installed here or in `$HOME`; install:
  `TARGET_REPO=$HOME ./install.sh codex --skill crew-afk`.
- Missing `crew-coder` / `crew-code-reviewer` → same re-install fixes it;
  `node "$CREW_AFK" doctor --platform codex` names what's absent.
- Any other non-zero exit → print its output and stop. Never finish the sprint by hand: a
  merge or close outside the pipeline skips the receipt gates keeping an unverified branch
  out of the feature branch.
