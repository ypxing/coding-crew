---
name: crew-afk
description: >
  Implements all ready-for-agent issues in the current repo by dispatching each one to a crew-coder
  subagent (a separate pi process in an isolated git worktree), then housekeeping the result. Loops
  until no issues remain or all are stalled. Reviews every branch before it merges. Use when asked
  to run an AFK sprint or implement all open issues.
  Optional: --model <alias|inherit> to override the coder's default model; --coverage for a PRD
  coverage report; --promote critical-high to promote HIGH review findings as well as CRITICAL.
---

# AFK Issue Sprint — pi

The sprint is a program, not a prompt. You launch it, stream its output, and report what
it printed. **You do not orchestrate, implement, review, merge or close anything yourself.**

```bash
CREW_AFK="$(git rev-parse --show-toplevel)/.coding-crew/crew-afk/main.mjs"
[ -f "$CREW_AFK" ] || CREW_AFK="$HOME/.coding-crew/crew-afk/main.mjs"
node "$CREW_AFK" run --platform pi "$@"
```

Pass the user's arguments straight through **when they already look like CLI syntax**:
`--model <alias|inherit>`, `--coverage`, `--promote critical-high`, `--max-parallel N`,
`--worker-timeout <minutes>`, `--max-rounds N`, `--no-squash`, `--jira TICKET-123`, or a
`.scratch/<feature-slug>/…` path — never rewrite those. Anything else (a bare word, a
likely typo, or a free-form phrase) is resolved first, below — never forwarded raw.

## Resolving the sprint target

If the trailing arguments are not already recognisable CLI syntax, do not run the command
yet. Look up what actually exists first:

```bash
ls -d .scratch/*/ 2>/dev/null
grep -rl "Status: ready-for-agent" .scratch/*/issues/open/*.md 2>/dev/null
```

Match the user's words against those real directory names — exact match, then
fuzzy/substring (a likely typo), then by issue title or content if the input is prose —
and branch on confidence:

- **Exactly one clear match** — resolve to `--feature-slug <slug>`, say what you inferred
  (`Found .scratch/<slug>/ with N open issues — running the sprint there`) so the user can
  correct you before anything launches, then run with that flag.
- **No match** — do not run. Say no such feature exists yet and point at `crew-grill`,
  `crew-brainstorm`, or `to-issues` to create one.
- **More than one plausible match** — do not run. List the candidates and ask which one.

Never create a new `.scratch/<slug>` directory as part of this resolution, and never guess
when the match is uncertain: a wrong resolution here dispatches, merges, and closes real
work against the wrong feature, which costs far more than one clarifying question. The
orchestrator's own argument parser also rejects anything unrecognised (with the same kind
of suggestion) as a second line of defense — but that is a safety net, not a substitute
for resolving intent before running.

It owns the whole loop: session init, issue selection, a worktree and a `crew-coder`
process per ready issue, then per branch `verify → review (acceptance criteria +
findings) → merge → close`, then findings promotion, squash, cleanup and the summary. It
loops until no issues remain or two rounds complete nothing.

## Your part

1. Resolve the sprint target first if the arguments aren't already CLI syntax (above),
   then launch the command **in the background** — a single coder dispatch can run up to
   45 minutes, well past any tool's synchronous timeout — with `--dry-run` first **only**
   if the user asked what it would do.
2. Poll the backgrounded run on a short interval and relay each new line as it arrives.
   Its `[STEP]` lines and throttled heartbeat go to **stderr**, not stdout — read stderr,
   not just stdout, or the sprint will look silent. A `[STEP]` line marks every gate
   transition (worktree, deps, dispatch, verify, review, merge, close); the heartbeat
   covers the gaps during each coder/review/triage dispatch — so the user sees progress
   instead of silence until a round finishes. The summary printed at the end is the
   report — do not rewrite, summarise, or re-derive it from the state file.
3. Mention `.scratch/<feature-slug>/traces/orchestrator.log` only if asked, or if the user
   steps away and wants more than the live stream showed — every tool call is there,
   timestamped and unthrottled.
4. Report the exit code's meaning and stop: `0` finished, `2` stalled (blockers need a
   human), `3` no ready issues, `1` setup problem — print its stderr verbatim and stop.

## Failure handling

- `node: command not found` → tell the user the orchestrator needs Node ≥ 20, and stop.
- `cannot find crew-afk's scripts/ dir` → crew-afk is installed in neither this repo nor
  `$HOME`. Install it user-level, which then works in every repo:
  `TARGET_REPO=$HOME ./install.sh pi --skill crew-afk`.
- Missing `crew-coder` / `crew-code-reviewer` definitions → the same re-install fixes it;
  `node "$CREW_AFK" doctor --platform pi` names what is absent.
- Any other non-zero exit → print its output and stop. Never finish the sprint by hand:
  a merge or close performed outside the pipeline skips the receipt gates that keep an
  unverified branch out of the feature branch.
