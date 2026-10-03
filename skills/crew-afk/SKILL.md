---
name: crew-afk
description: >
  Implements all ready-for-agent issues by dispatching each to a separate coding-agent CLI process
  in its own worktree, then housekeeping the result. Loops until no issues remain or all stall;
  reviews every branch before merge. Trigger with /crew-afk. Optional: --model <alias|inherit>;
  --prd-audit off|report|fix; --fix-findings actionable|critical|high|medium|none.
allowed-tools: Bash, shell
---

# AFK Issue Sprint

The sprint is a program, not a prompt: launch it, stream its output, report what it
printed. **You do not orchestrate, implement, review, merge or close anything
yourself.**

```bash
CREW_AFK="$(git rev-parse --show-toplevel)/.coding-crew/crew-afk/main.mjs"
[ -f "$CREW_AFK" ] || CREW_AFK="$HOME/.coding-crew/crew-afk/main.mjs"
node "$CREW_AFK" run --platform {{PLATFORM}} "$@"
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
`crew-grill`, `crew-brainstorm`, or `to-issues`. Multiple matches → ask which. Never guess
or create a `.scratch/<slug>` directory: a wrong resolution merges and closes real work.

It owns the whole loop: a worktree and coder per issue, then verify → review → merge → close,
promotion, the opt-in squash, cleanup and the summary — until no issues remain or every
remaining one is blocked.
Workers are separate `{{PLATFORM}}` CLI processes, not in-session subagents, so a hung one
times out without hanging the sprint. The CLI must be on `PATH` and authenticated — if it is
not, stop rather than implementing issues yourself.

A dead run's feature lease needs `--reclaim`.

## Your part

1. Resolve the target first if needed, then launch **in the background** — a dispatch can
   run up to 45 minutes — with `--dry-run` first only if the user asked what it would do.
   Use your tool's own background tracking (Claude Code: `run_in_background: true`), not a
   shell `&`/`disown` — that bypasses the completion notification, so no summary reaches you.
2. **Don't poll and don't relay.** Every line you read or echo costs tokens; the human
   watches the pane host or `orchestrator.log`. Read stderr once, for its first line
   (`PANE-HOST: …`), then wait for the completion notification. If asked for progress,
   answer in one sentence from the latest `[STEP]` lines on **stderr** — never echo them.
   No notification yet? Check at most every few minutes — not at all under
   `PANE-HOST: orca`, which also prompts this pane once the sprint finishes or stalls. On
   exit, print the stdout summary as-is — it is the report; don't rewrite it.
3. If asked, the log is `.scratch/<feature-slug>/traces/orchestrator.log`.
4. Report the exit code and stop: `0` finished, `2` stalled or capped (needs a human), `3` no
   ready issues, `1` setup problem — print its stderr verbatim.

## Failure handling

- `node: command not found` → needs Node ≥ 20, and stop.
- `cannot find crew-afk's scripts/ dir` or `protocol … not found` → not installed here or in
  `$HOME`; install: `TARGET_REPO=$HOME ./install.sh {{PLATFORM}} --skill crew-afk`.
  `node "$CREW_AFK" doctor --platform {{PLATFORM}}` names what's absent.
- Any other non-zero exit → print its output and stop. Never finish the sprint by hand: a
  merge or close outside the pipeline skips the receipt gates keeping an unverified branch
  out of the feature branch.
