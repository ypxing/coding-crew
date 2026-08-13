# Plan: crew-afk as code (one orchestrator, one state machine)

Status: **Done — Phases 0–5 landed.** Every platform is a launcher over one program; the
shared-body scaffolding is retired. See `docs/crew-afk-orchestrator.md` for what exists and
`CHANGELOG.md` for the cutovers. Maintainer notes — not installed into consumer repos.

## 1. The question

Today `crew-afk` is a **prompt that describes a state machine**, plus 14 bash scripts that own the
individual effects. The prompt is ~2,700 words (Claude) + ~2,400 words (shared dispatch body) + 21
fragments, rendered per platform by `scripts/render-skill.sh`. Can the orchestrator itself be a
program (JS), with the LLM used only where judgement is actually required?

**Yes, and the repo has already been walking there.** `session-init.sh`, `state.sh`, `trace.sh`,
`receipts.sh`, `promote-findings.sh`, `cleanup-worktrees.sh` and `crew-summary.sh` each exist because
a piece of prose failed in a real sprint. What is left in prose is exactly the part that is hardest
to make reliable by prose: **control flow.** Observed failures already include re-deriving the feature
slug with an alphabetical glob, merging a branch whose `VERIFY` was `fail`, closing an issue off a
sibling's branch, and skipping cleanup because a round ran long. Every one of those is a control-flow
bug, and receipts only fail *closed* — they cannot make a step happen.

## 2. What is actually LLM work

After migration, exactly four dispatch points need a model. Everything else is mechanical.

| Step | Today | After |
| --- | --- | --- |
| Session init, `sprint.env`, model resolve, preflight | prose calls script | code |
| List issues, parse `Status:`, resolve `## Blocked by` | **LLM reads every issue file** | code |
| Worktree add + `.worktreeinclude` symlinks | prose (inline bash in prompt) | code |
| Resume-note composition | prose (3 template branches) | code |
| Prompt-file assembly + verbatim criteria extraction | LLM copy/paste | code |
| Parallel dispatch, batching, `wait` | prose (`&` + `wait`, no timeout) | code (pool + timeout + retry) |
| Report parse + schema pre-filter (`fail`, `not_run`) | **LLM reads free-form markdown** | code (structured contract) |
| verify → review → AC receipt → promote → merge → close | prose ordering | code (one chain, one place) |
| `## Progress` rewrite / `## Blocked` append | LLM edits issue file | code (splice worker's section) |
| Round counting, stall detection, Phase 1→2 flush re-entry | prose | code |
| Wrap-up: squash, coverage, cleanup, summary | prose | code |
| **crew-coder implementation** | subprocess | subprocess (unchanged) |
| **crew-code-reviewer** | subprocess | subprocess (unchanged) |
| **PRD coverage validation** | "run this prompt in your own session" | its own dispatch |
| **Findings → acceptance criteria restatement** | orchestrator writes criteria file | reviewer emits it (contract change) or a small dispatch |

The orchestrator LLM's remaining job becomes: **launch the program, stream its output, report its
last lines.** Its context cost drops from "5,000-word body + every worker report + every review" to
roughly nothing.

## 3. Shape

Two options for the runtime.

**Option A (recommended): a standalone zero-dependency Node CLI**, platform-neutral, installed once.

```
orchestrator/                      # source in this repo
  main.mjs                         # arg parse, subcommands: run | plan | status | resume | cleanup
  loop.mjs                         # rounds, stall detection, Phase 1 → flush → Phase 2 re-entry
  pipeline.mjs                     # per-branch gate chain (verify → review → ac → promote → merge → close)
  tracker.mjs                      # issue discovery, Status/Blocked-by, section splice (Progress/Blocked)
  report.mjs                       # worker + reviewer report parsing, schema pre-filter
  sprint.mjs                       # sprint.env, sprint-state.json, per-issue phase, resume
  effects.mjs                      # typed wrapper over the existing bash scripts (+ trace)
  dispatch/{pi,codex,claude,copilot,fake}.mjs
```

Installed to `.coding-crew/crew-afk/` (platform-neutral, always overwritten, removed on uninstall —
the same rule as `.coding-crew/code-review/` and `.coding-crew/scripts/`, and for the same reason: a
stale orchestrator is worse than none). Entry point:

```bash
node "$ROOT/.coding-crew/crew-afk/main.mjs" run --platform pi --model sonnet --coverage
```

The skill body shrinks to a **launcher** — under ~200 words: resolve root, check `node`, run the
command, stream output, print the last lines verbatim, stop. `dispatch.SKILL.md`, all 21 fragments,
`render-skill.sh` for this skill, and the prose-parity test suite all retire with it.

**Option B: a pi extension / custom tool** (`examples/extensions` style, in-session TUI rendering).
Better UX on pi, but it is pi-only and re-creates the parity problem for the other three platforms.
Recommendation: build A; optionally wrap it later in a thin pi extension for rendering.

### 3a. All four platforms dispatch headlessly (verified locally)

The one real unknown in this plan — whether every platform can launch a *named custom agent* as a
non-interactive child process — resolves **yes** on all four. Verified against the CLIs on this
machine:

| Platform | Version | Non-interactive | Named agent | cwd | Capture | Model |
| --- | --- | --- | --- | --- | --- | --- |
| pi | in use today | `-p` | `--append-system-prompt` (from `.pi/agents/*.md`) | spawn cwd | stdout / `tee` | `--model` |
| codex | in use today | `exec` | `developer_instructions` prepended (from `.codex/agents/*.toml`) | `--cd`, `--add-dir` | `--output-last-message` | `--model`, `model_reasoning_effort` |
| claude | 2.1.221 | `-p` / `--print` | `--agent <name>`, or `--agents <json>`, or `--append-system-prompt` | spawn cwd, `--add-dir` | `--output-format json` | `--model` |
| copilot | 1.0.79 | `-p` / `--prompt` | `--agent <name>` | `-C <dir>`, `--add-dir` | `-s/--silent` (response only) | `--model` |

Consequences:

- **One dispatch contract, four ~30–50 line adapters.** Each maps (agent, cwd, prompt file, out file,
  model, tool allowlist) onto its CLI. Nothing else in the state machine is platform-aware.
- **The isolation model becomes uniform.** Every platform gets a real `git worktree` plus a child
  process, because the orchestrator creates it — no more three-way split (claude runtime worktrees,
  copilot sharing the parent root, pi/codex subprocesses). Copilot's per-issue isolation stops
  depending on a `Working directory:` line in a prompt that the model has to obey.
- **Better capture**: claude `--output-format json` is structured; copilot `--silent` prints the
  response only. Report parsing no longer has to strip TUI decoration.
- **Two residual unknowns, both with cheap fallbacks:** whether `--agent <name>` resolves the
  *project-level* definition (`.claude/agents/`, `.github/agents/`) in non-interactive mode. Claude's
  fallback is `--append-system-prompt` or `--agents <json>` built from the installed file; copilot has
  no system-prompt flag, so its fallback is prepending the agent body to the prompt, exactly as
  `dispatch-codex-agent.sh` already does for codex. Confirm with one throwaway dispatch per platform.
- **Permissions must be explicit per adapter** or an unattended sprint stalls on a confirmation
  prompt: copilot `--allow-all-tools`, claude `--permission-mode bypassPermissions` (or a narrow
  `--allowedTools`), codex `sandbox_mode`, pi `--tools`. One field per adapter instead of a paragraph
  per body.

**Bash stays.** JS owns *control flow*; bash keeps *effects*. `verify-worktree.sh` (363 lines of
check discovery), `merge-branches.sh`, `squash-commits.sh`, `cleanup-worktrees.sh`,
`promote-findings.sh` are tested, standalone-runnable out of band, and rewriting them in JS buys
nothing. `state.sh` / `trace.sh` / `receipts.sh` are pure `jq` bookkeeping and *may* fold into JS
later — but keeping them means a human can still inspect and repair a sprint from a shell.

## 4. Contracts to tighten (the enabling work)

Code cannot parse what free-form markdown does not promise. Two agent-protocol edits:

1. **Worker report.** `crew-coder` additionally writes `<slug>.report.json`:
   `{status, branch, working_directory, checks:{test,lint,typecheck: pass|fail|not_run}, criteria:[{text,met}], progress, notes, commits}`.
   The markdown report stays for humans. Parser: JSON first, markdown heuristic fallback for one
   release, and an unparseable report is `blocked / report-unparseable` — never a silent `complete`.
2. **Reviewer report.** Keep the `AC:` line (already machine-read). Add one machine-readable line per
   finding: `FINDING: CRITICAL | path/file.ts:42 | <verifiable criterion sentence>`. That makes the
   promotion criteria file mechanical and removes the last LLM step inside the pipeline.

Both are small edits to `agents/*/protocol.md` and are worth doing **before** the loop moves, because
they are testable on the current prose orchestrator.

## 5. Capabilities that only exist once it is code

Worth listing, because they justify the work beyond tidiness:

- **Per-worker timeout + kill.** Today a hung `pi -p` blocks `wait` forever and the sprint never ends.
- **Real concurrency control** (`--max-parallel`, platform default caps) instead of "batches of 3" in prose.
- **Crash-safe resume.** Per-issue phase in `sprint-state.json` + receipts → `crew-afk resume` picks
  up mid-pipeline; re-running is a no-op.
- **`crew-afk plan` (dry run).** Prints the exact effect sequence for the current repo state, zero
  tokens. This is also the parity/regression harness.
- **Fake dispatch adapter** → the whole state machine is testable, including stall, Phase 2, merge
  conflict, review-not-run, timeout — none of which are testable today without spending a sprint.
- **One event log** (`.scratch/<slug>/events.jsonl`) alongside the human trace log.
- **Structured exit codes** so CI or a wrapper can act on `stalled` vs `blocked` vs `clean`.

## 6. Risks, and what pays for them

| Risk | Mitigation |
| --- | --- |
| **Node becomes a consumer requirement** (repo is currently bash + `jq` only) | Node ≥20, zero dependencies, single-file-ish ESM; launcher preflights `node -v` with a clear error. Alternatives if rejected: Bun/Deno single binary, or a `crew-afk.sh` driver in bash (cheapest on requirements, worst on testability). |
| **Loss of LLM adaptability** on unforeseen states (weird git state, odd verification output) | Fail closed by default, plus `--on-anomaly escalate`: the CLI dispatches a one-shot triage agent with the anomaly and the state file instead of guessing or dying. |
| **Copilot/Claude headless per-agent dispatch** | **Resolved — both support it** (see §3a). Copilot's in-session `task` tool is no longer the only mechanism. |
| **Claude loses runtime `isolation: worktree`** | **Resolved — removed at the claude cutover.** The CLI creates worktrees itself for every platform, which is uniformity, not loss, and it retires the `.claude/worktrees/agent-*` leftovers cleanup has to sweep. |
| **Two orchestrators = drift** — the exact failure this repo fights | Strangler, never parallel maintenance: each platform's prose body is **deleted** in the commit that cuts it over. |
| **~10 test files assert prose** (`crew-afk-state`, `shared-dispatch-body`, word budgets, fragment completeness) | Their subject disappears; they are replaced by `node:test` unit tests + golden `crew-afk plan` transcripts. Every behavioural assertion inside them is migrated first, then the prose assertion is deleted (same discipline as `crew-code-reviewer-references.bats`). |
| **`install.sh` has no `assets` support for skills** (agents only) | Small extension: reuse the `install.assets` mechanism for skill entries. |
| **CLAUDE.md doctrine** ("nothing installs that no agent runs", prose-parity by rendering) | Amend: parity is now by *implementation*, and the installed tree gains an executable orchestrator. |

## 7. Phasing

**Phase 0 — spikes and decisions (small, do first).**
- ~~Confirm headless per-agent dispatch~~ — done, all four (§3a). Remaining: one throwaway dispatch per
  platform to confirm project-level `--agent <name>` resolution and the permission flags.
- Decide runtime (Node vs bash-only) and install path.
- Write the report/finding contracts above and land them on the current prose orchestrator.

**Phase 1 — pure core, no dispatch.** `tracker.mjs`, `report.mjs`, `sprint.mjs`, `pipeline.mjs`
transition table, plus `crew-afk plan`. Unit-tested with fixtures. Nothing installed yet, no body
changes. This is where the bulk of the correctness lives and it costs zero tokens to test.

**Phase 2 — tracer bullet: `crew-afk run` on pi, real dispatch.** pi is already subprocess-based, so
the adapter is `dispatch-agent.sh` with a timeout. Effects delegate to the existing bash scripts.
Cut the pi body over to the launcher and **delete the pi fragments**. First full unattended sprint
end-to-end on this repo's own issues.

**Phase 3 — codex, then claude.** Adapters only (`dispatch-codex-agent.sh` already exists). Each
cutover deletes its prose. ~~codex~~ — done; it also proved that the *sandbox* is part of the
adapter contract (a codex worker cannot commit in a linked worktree unless the main repo's git dir
is an explicit writable root) and that the AC gate has to be told which checks the pipeline already
ran, or a criterion that ends "and the tests pass" is unprovable by a read-only reviewer.
~~claude~~ — done; `--agent <name>` resolves the project-level definition and fails loudly, so the
re-sent agent body is gone, `isolation: worktree` is removed, and the one bug a real sprint found
was platform-general: the structured report has to be a **file the worker writes**, not a block at
the end of a final message that a `-p` run may end with prose instead.

~~**Phase 4 — copilot.**~~ — done; an ordinary adapter (`-p --agent -C --add-dir --allow-all-tools
--silent`), not a special case. The `task`-tool fragments and the plan-tier batching prose retired
with it, `--model` became a real flag, and concurrency is `--max-parallel` (default 2). The bug only
a probe finds: copilot resolves `--agent` from the worker's **own cwd** and does not walk up, so a
definition that is not in `HEAD` (or user-level) is invisible from a worktree — `preflight()` refuses
the sprint and names both fixes, rather than every worker dying on `No such agent` mid-round.

~~**Phase 5 — retire the scaffolding.**~~ — done. Phase 4 took the parts with no subject left
(`dispatch.SKILL.md`, `fragments/`, `tests/shared-dispatch-body.bats`, the prose word budget);
Phase 5 took the `AFK_PROSE_VARIANTS` machinery, the emptied loops across seven suites, the
`configure-tracker-auto.sh` copy no launcher ran, and the `CLAUDE.md` rewrite (one adapter table).
Three pruned assertions had no code equivalent, so they were written first — and one of them found
a real gap in `remind`'s finding count. `state.sh`/`trace.sh`/`receipts.sh` stay in bash: they are
effects with one caller each and the only way to inspect a stalled sprint from a shell.

## 8. Sizing

Replaced: ~5,100 words of orchestrator prose across 2 bodies + 21 fragments, plus ~10 bats files
whose only job is to police that prose. Added: an estimated 1,200–1,800 LOC of dependency-free JS,
of which the four dispatch adapters are ~40 lines each. Retained unchanged: ~2,300 lines of the
existing bash effect scripts.

Phase 0+1 is the honest majority of the design risk; Phase 2 is the first sprint that runs on it.

## 9. Recommendation

Do it, in that order, and treat Phase 0's two contract edits as independently valuable — they make
the current prose orchestrator more reliable even if the rest is never built. Keep the boundary
strict: **JS owns control flow, bash owns effects, the model owns judgement.** The reason to move is
not elegance; it is that the four failure classes already observed in real sprints are all control
flow, and prose cannot be made to fail closed on a step it simply skipped.
