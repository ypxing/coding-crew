{{FRAGMENT:frontmatter}}

{{FRAGMENT:heading}}

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
`crew-grill`, `crew-brainstorm`, or `to-issues`. Multiple matches → ask which. Never
create a new `.scratch/<slug>` directory, and never guess — a wrong resolution dispatches,
merges, and closes real work against the wrong feature.

{{FRAGMENT:loop-owner}}

A dead run's feature lease needs `--reclaim`.

## Your part

{{FRAGMENT:launch}}

2. **Don't poll and don't relay.** Every line you read or echo costs tokens; the human
   watches the pane host or `orchestrator.log`. Read stderr once, for its first line
   (`PANE-HOST: …`), then wait for the completion notification. If asked for progress,
   answer in one sentence from the latest `[STEP]` lines on **stderr** — never echo them.
   No notification yet? Check at most every few minutes — not at all under
   `PANE-HOST: orca`, which also prompts this pane once the sprint finishes or stalls. On
   exit, print the stdout summary as-is — it is the report; don't rewrite it.
3. Mention `.scratch/<feature-slug>/traces/orchestrator.log` if asked.
{{FRAGMENT:exit-codes}}

## Failure handling

{{FRAGMENT:failure}}
