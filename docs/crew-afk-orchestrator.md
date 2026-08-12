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
node orchestrator/main.mjs status                        # sprint.env + sprint-state.json
```

Exit codes: `0` clean, `2` stalled, `3` nothing to do, `1` setup error.

`CREW_SCRIPTS` points at the bash mechanism layer; otherwise it is resolved from the
installed skill dirs, then from this repo's `skills/crew-afk/scripts/`.

## The pipeline, as code

`runWorker` (concurrent, bounded by `--max-parallel`) → `runHousekeeping` (sequential,
because merges touch the main checkout):

1. **schema pre-filter** — `fail` or `test: not_run` demotes `complete`; lint/typecheck
   `not_run` is a recorded coverage gap. Same policy as `verify-worktree.sh`.
2. **verify** — `verify-worktree.sh`, which writes the verification receipt.
3. **review** — `crew-code-reviewer`, which returns the `AC:` verdict *and* findings.
4. **AC receipt** — written only on `AC: all-met`, only for this issue's own slug.
5. **promote** — `promote-findings.sh guard` then `defer`, threshold from `sprint.env`.
6. **merge**, and only on its success **close**, then `state.sh complete`.

Anything else demotes to `partial`/`blocked`, retains the branch, and rewrites
`## Progress` / appends to `## Blocked`. Nothing merges on an absent check.

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

- **Phase 0/1 done**: pure core, four adapters, pipeline, loop, `plan`; 32 node tests.
- **Phase 2 done for pi**: installed to `.coding-crew/crew-afk/` via the skill `assets`
  entry, pi's `SKILL.md` is a 390-word launcher, `fragments/pi/` deleted, prose-parity
  assertions moved onto the code, and a real unattended pi sprint verified end to end
  (worker → verify → review → receipts → merge → close → squash → cleanup → summary).
- **Next (Phase 3/4)**: codex, then claude, then copilot. Each is an adapter that already
  exists plus one body swap; the cutover moves that platform's name out of
  `AFK_PROSE_VARIANTS` in `tests/helpers/render.bash` and deletes its fragments.
- **Deferred**: adding the `FINDING:` line and the `<slug>.report.json` sidecar to the
  agent protocols. The code asks for both in the prompts it builds and falls back
  cleanly, so this is a robustness upgrade rather than a prerequisite.
