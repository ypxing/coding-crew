# crew-afk orchestrator (code) — maintainer notes

Maintainer notes for `orchestrator/`. Not installed into consumer repos. Plan and
rationale: `docs/crew-afk-as-code-plan.md`.

## What it is

The crew-afk sprint loop as a program instead of as a prompt. JS owns **control flow**,
the existing bash scripts in `skills/crew-afk/scripts/` keep the **effects**, and the
model is used at exactly four points: the coder, the reviewer, the opt-in coverage
validation, and nothing else.

```
orchestrator/
  main.mjs            CLI: run | plan | status | doctor
  lib/tracker.mjs     issue discovery, Status/Blocked-by, slug, section splice
  lib/report.mjs      worker + reviewer report parsing, schema pre-filter
  lib/sprint.mjs      sprint.env + sprint-state.json, through session-init.sh / state.sh
  lib/effects.mjs     the only place that spawns a subprocess (+ --dry-run recording, pool)
  lib/worktree.mjs    one git worktree per issue, for every platform
  lib/prompts.mjs     worker prompt, resume notes, review prompt, promoted criteria
  lib/dispatch.mjs    four platform adapters + the fake seam + preflight
  lib/pipeline.mjs    the per-branch gate chain
  lib/loop.mjs        rounds, stall, Phase 1 → flush → Phase 2, wrap-up
(the node:test suite lives in tests/orchestrator/, outside the installed tree)
```

## Running it

```bash
node orchestrator/main.mjs plan   --platform pi          # read-only, zero tokens
node orchestrator/main.mjs doctor --platform claude      # CLI + agent definitions present?
node orchestrator/main.mjs run    --platform pi --model sonnet --coverage
node orchestrator/main.mjs run    --platform pi --no-deps   # skip both ensure-deps.sh calls
node orchestrator/main.mjs status                        # sprint.env + sprint-state.json
```

Exit codes: `0` clean, `2` stalled, `3` nothing to do, `1` setup error.

`CREW_SCRIPTS` points at the bash mechanism layer; otherwise it is resolved from the
installed skill dirs, then from this repo's `skills/crew-afk/scripts/`.

## The pipeline, as code

`Sprint.init` runs `session-init.sh`, then `ensure-deps.sh --dir $MAIN_ROOT` — once per sprint,
serially, before any worker or worktree exists, so N parallel installs are not N cold downloads.

`runWorker` (concurrent, bounded by `--max-parallel`) → `runHousekeeping` (sequential,
because merges touch the main checkout):

0. **worktree, include, deps** — `ensureWorktree()`, `applyWorktreeInclude()`, then
   `ensure-deps.sh --dir <worktree> --slug <slug>`. That position is the whole point: after the
   include, so an inherited `node_modules` is seen by the presence guard and costs nothing, and
   before **both** consumers of the deps — the worker, and `verify-worktree.sh` at step 2, which
   runs the project's own tests and has no dep recovery path of its own because a gate cannot
   invoke a skill. Advisory: the `DEPS:` line is logged and never branched on, so a failed install
   cannot demote an issue by itself — the verify gate already fails closed on the consequence.
1. **schema pre-filter** — `fail` or `test: not_run` demotes `complete`; lint/typecheck
   `not_run` is a recorded coverage gap. Same policy as `verify-worktree.sh`.
2. **verify** — `verify-worktree.sh`, which writes the verification receipt.
3. **review** — `crew-code-reviewer`, which returns the `AC:` verdict *and* findings.
4. **AC receipt** — written only on `AC: all-met`, only for this issue's own slug.
5. **promote** — `promote-findings.sh guard` then `defer`, threshold from `sprint.env`.
6. **merge**, and only on its success **close**, then `state.sh complete`.

Anything else demotes to `partial`/`blocked`, retains the branch, and rewrites
`## Progress` / appends to `## Blocked`. Nothing merges on an absent check.

`--no-deps` removes both `ensure-deps.sh` call sites and nothing else — the same escape hatch, for
the same reason, as `CREW_RECEIPTS=off`. Both calls go through `effects.bash()`, so `--dry-run`
records them in order rather than running them.

## Testing without spending tokens

`CREW_FAKE_DISPATCH=<script>` replaces every model dispatch (`preflight` also relaxes).
`tests/orchestrator/fixtures/fake-dispatch.sh` reads per-slug files out of `$CREW_FAKE_DIR`
(`<slug>.worker`, `<slug>.review`, `<slug>.exit`, `<slug>.nocommit`) so a test can drive
any path: clean merge, failing check, unmet criteria, empty review, dead dispatch,
CRITICAL promotion into Phase 2, stall.

`tests/orchestrator.bats` runs the whole node suite through bats, so CI shards it with
everything else.

```bash
node --test tests/orchestrator/*.test.mjs
bats tests/orchestrator.bats
```

## Status

- **Phase 0/1 done**: pure core, four adapters, pipeline, loop, `plan`; 62 node tests.
- **Phase 2 done for pi**: installed to `.coding-crew/crew-afk/` via the skill `assets`
  entry, pi's `SKILL.md` is a 390-word launcher, `fragments/pi/` deleted, prose-parity
  assertions moved onto the code, and a real unattended pi sprint verified end to end
  (worker → verify → review → receipts → merge → close → squash → cleanup → summary).
- **Phase 3 done for codex**: `codex.SKILL.md` is a 434-word launcher,
  `fragments/codex/` deleted, `codex` moved into `AFK_LAUNCHER_VARIANTS`, the fragment
  assertions replaced by `tests/orchestrator/dispatch.test.mjs`, and a real unattended
  codex sprint verified end to end. Two real bugs surfaced only by running it, both fixed
  and both platform-general in consequence:
  - `dispatch-codex-agent.sh` now names the worktree's **git common dir** as a writable
    sandbox root (`-c sandbox_workspace_write.writable_roots=[…]`). Codex's
    `workspace-write` sandbox keeps `.git` read-only even when its parent is passed with
    `--add-dir`, and a linked worktree's index lives at
    `<main>/.git/worktrees/<name>/index.lock` — so a worker could edit files but never
    commit them (`Operation not permitted`), which the pipeline read, correctly, as
    `blocked`. Every codex sprint stalled at round 1.
  - The review prompt now **states which checks the pipeline already ran**
    (`parseVerifyChecks()` reads `verify-worktree.sh`'s own output). A criterion phrased
    "…and `npm test` passes" has no file and line, so a read-only reviewer answered
    `AC: unmet — not executed in this inspection-only review` and the branch was retained
    every round, forever. `not_run` is still evidence of nothing, and the code half of
    every criterion is still judged from the diff. The same rule is in
    `agents/crew-code-reviewer/protocol.md`, so the reviewer states the same rule wherever
    the review prompt comes from.
- **Phase 4 done for copilot**: `copilot.SKILL.md` is a 477-word launcher,
  `fragments/copilot/` and the now-consumer-less `dispatch.SKILL.md` are **deleted**, so no
  platform ships a prose orchestrator and `AFK_PROSE_VARIANTS` is empty. Copilot's coder
  report contract moved to the parser's shape (the sidecar, as the last action), and its
  fragment assertions moved onto the adapter (nine new cases in `dispatch.test.mjs`).
  Decisions, each probed against Copilot CLI 1.0.79 rather than assumed:
  - `copilot -p --agent <name>` resolves `.github/agents/<name>.agent.md`, enforces its
    `tools:` list even under `--allow-all-tools`, and exits 1 with
    `No such agent: <name>, available: …`. So the prepended agent body is **gone** — it
    duplicated a definition the CLI loads itself and could not have rescued a name the CLI
    refuses. `--agent` takes a name, never a path.
  - **It resolves that directory from its own working directory and does not walk up** — the
    one place copilot differs from claude. A worker's cwd is its worktree, so only a
    definition tracked in `HEAD` (or installed under `~/.copilot/agents/`) is visible;
    an untracked project install is installed and unreachable. `preflight()` checks exactly
    that and names both fixes, because the alternative is every worker dying on
    `No such agent` after the sprint has started — and a dead dispatch is where the prose
    orchestrator used to start implementing issues itself.
  - `--allow-all-tools` stays (an unattended sprint cannot answer a permission prompt): it
    removes the prompt, not the definition's allowlist. `--available-tools` cannot be written
    in advance for a worker that runs the consuming project's own checks.
  - `--add-dir <main root>` is explicit: the worker reads the issue file and writes
    `<slug>.report.json` under `.scratch/` outside its worktree.
  - `--model` is a **real flag** now rather than accepted-and-ignored, because a worker is its
    own process rather than an in-session `task`. `--max-parallel` stays at 2: the plan tier
    (Free 2 … Enterprise 32) capped in-session subagents, and what binds a process pool is the
    account's request rate, which the CLI does not expose.
- **Phase 3 also done for claude**: `claude.SKILL.md` is a 449-word launcher, the 2,700-word
  prose body (`skills/crew-afk/SKILL.md`) is **deleted**, `claude` moved into
  `AFK_LAUNCHER_VARIANTS`, and its prose assertions moved onto the code — seven new cases in
  `tests/orchestrator/sprint.test.mjs` (gate order from the trace log, the review report path
  and the no-verified-branch skip, retention surviving cleanup + the resume prompt, a merged
  branch losing both worktree and ref, the model in the summary, coverage opt-in and its
  position in the wrap-up) and six in `dispatch.test.mjs`. Decisions, with the probes behind
  them, are recorded in the issue:
  - `claude -p --agent <name>` **does** resolve the project-level `.claude/agents/`
    definition, enforces its `tools:` list, and exits 1 on an unknown name. So the
    belt-and-braces `--append-system-prompt <body>` is **gone**: it re-sent the coder's whole
    definition inside every worker's system prompt and overrode the loaded one on conflict.
  - `--permission-mode bypassPermissions` stays (an unattended sprint cannot stop on a
    permission prompt), because it removes the prompt, not the allowlist — the definition's
    `tools:` list still binds, so the reviewer is still read-only.
  - `isolation: worktree` is removed from `agents/crew-coder/claude.agent.md`. `worktree.mjs`
    creates the worktree for every platform now; the key would have described a mechanism no
    sprint runs, and would nest a second runtime worktree inside the orchestrator's.
  - **The bug only a real sprint could find, and it is platform-general**: round 1 was lost to
    `no Status: line in the worker report`. The work was committed, but `claude -p` prints only
    the final message and that message ended with a sentence of summary, so nothing parsed and
    the issue was `blocked` for a round. The sidecar was offered as an *alternative* ("may be
    written … instead"); it is now the ask — `prompts.mjs` and every launcher coder require
    writing `<slug>.report.json` **as the last action**, because a file write does not depend
    on how a message ends. A re-run finished in one round.
- **Contracts now live in the agent definitions, not only in the prompts**: the launcher
  platforms' `crew-coder` variants state the `<slug>.report.json` sidecar / fenced-JSON
  block, and `agents/crew-code-reviewer/protocol.md` states the
  `FINDING: <SEV> | <file:line> | <criterion>` line. `tests/orchestrator/contract.test.mjs`
  reads `AFK_LAUNCHER_VARIANTS` and asserts the declared field names are the ones
  `report.mjs` indexes, round-trips the definition's own JSON template through the parser,
  keeps the markdown fallback covered, and requires the sidecar write to be asked for "as
  your last action". claude's older shape (`checks` as an array of `{command, result}`, read
  by the prose orchestrator) was migrated at its cutover, and copilot's — which had no
  machine-readable block at all, never having been a launcher platform — at its own. That is
  what the test existed to force: a silent contradiction there demotes clean branches to
  `partial` for "tests not run".

## Why `state.sh`, `trace.sh` and `receipts.sh` stay in bash

Folding them into JS was considered at the end of the migration (Phase 5) and rejected. They
are pure `jq` bookkeeping, so the fold would be cheap — and that is the whole argument for it.
Against it: a stalled or crashed sprint is inspected and repaired from a shell, and these three
are how. `state.sh get retained`, `receipts.sh` (its `.ok` files are plain text naming a commit)
and the `TRACE_LOG` are what a human reads to answer "what did this sprint actually do, and what
is safe to re-run" — without starting a Node process, and without the orchestrator being alive.
`cleanup-worktrees.sh` is out-of-band for the same reason.

The boundary that matters is already held: **JS owns control flow, bash owns effects.** These
scripts are effects (write a receipt, append a trace line, mutate `sprint-state.json`) with one
caller each. Moving them inside would trade an inspectable seam for no behaviour change, and the
failures this migration was built to fix were all control flow, none of them here.
