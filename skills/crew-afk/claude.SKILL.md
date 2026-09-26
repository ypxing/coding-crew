---
name: crew-afk
description: >
  Implements all ready-for-agent issues by dispatching each to a crew-coder subagent (a `claude -p`
  process per worktree), then housekeeping the result. Loops until no issues remain or all stall;
  reviews every branch before merge. Trigger with /crew-afk. Optional: --model <alias|inherit>;
  --prd-audit off|report|fix; --fix-findings critical|high|medium|none.
tools:
  - Bash
---

# AFK Issue Sprint — Claude Code

The sprint is a program, not a prompt: launch it, stream its output, report what it
printed. **You do not orchestrate, implement, review, merge or close anything
yourself.**

```bash
CREW_AFK="$(git rev-parse --show-toplevel)/.coding-crew/crew-afk/main.mjs"
[ -f "$CREW_AFK" ] || CREW_AFK="$HOME/.coding-crew/crew-afk/main.mjs"
node "$CREW_AFK" run --platform claude "$@"
```

Pass CLI-looking arguments through — `--model`, `--prd-audit`, `--fix-findings`,
`--max-parallel N`, `--jira TICKET-123`, a `.scratch/<feature-slug>/…` path — never rewrite
those. A bare word, typo, or phrase is resolved first, below.

## Resolving the sprint target

If the trailing arguments aren't CLI syntax, look up what exists first:

```bash
ls -d .scratch/*/ 2>/dev/null
grep -rl "Status: ready-for-agent" .scratch/*/issues/open/*.md 2>/dev/null
# tracker: github — gh issue list --milestone <slug> --label ready-for-agent
```

Match against those names (exact, fuzzy/typo, then issue content). One match →
`--feature-slug <slug>`, say what you inferred, then run. No match → don't run; point at
`crew-grill`, `crew-brainstorm`, or `to-issues`. Multiple matches → ask which. Never
create a new `.scratch/<slug>` directory, and never guess — a wrong resolution dispatches,
merges, and closes real work against the wrong feature.

It owns the whole loop: worktree and `crew-coder` process per issue, then verify → review →
merge → close, then promotion, squash, cleanup and summary — until no issues remain or
every remaining one is blocked (retries spent, or a dependency's). Workers are
`claude -p --agent crew-coder` processes, 3 at a time, not `Agent` calls, so a hung one
times out without hanging the sprint.

## Your part

1. Resolve the target first if needed, then launch **in the background** — a dispatch can
   run up to 45 minutes — with `--dry-run` first only if the user asked what it would do.
   Use the Bash tool's own background tracking (`run_in_background: true`), not a manual
   shell `&`/`disown` with redirected output — that bypasses the completion notification
   and no summary reaches you when the sprint finishes.
2. **Don't poll and don't relay.** Every line you read or echo costs tokens; the human
   watches the pane host or `orchestrator.log`. Read stderr once, for its first line
   (`PANE-HOST: …`), then wait for the completion notification. If asked for progress,
   answer in one sentence from the latest `[STEP]` lines on **stderr** — never echo them.
   No notification yet? Check at most every few minutes — not at all under
   `PANE-HOST: orca`, which also prompts this pane once the sprint finishes or stalls. On
   exit, print the stdout summary as-is — it is the report; don't rewrite it.
3. Mention `.scratch/<feature-slug>/traces/orchestrator.log` if asked.
4. Report the exit code and stop: `0` finished, `2` stalled (needs a human), `3` no ready
   issues, `1` setup problem — print its stderr verbatim.

## Failure handling

- `node: command not found` → needs Node ≥ 20, and stop.
- `cannot find crew-afk's scripts/ dir` → not installed here or in `$HOME`; install:
  `TARGET_REPO=$HOME ./install.sh claude --skill crew-afk`.
- Missing `crew-coder` / `crew-reviewer` → same re-install fixes it;
  `node "$CREW_AFK" doctor --platform claude` names what's absent.
- Any other non-zero exit → print its output and stop. Never finish the sprint by hand: a
  merge or close outside the pipeline skips the receipt gates keeping an unverified branch
  out of the feature branch.
