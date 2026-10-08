---
mode: feature
base_sha: 8fc0b3539d05
head_sha: cc405b3b97fe
slug: lightweight-flow
via: origin/feature/lightweight-flow
---
Replay of the first feature review of #355 (lightweight-flow, `dispatch/feature-d1`, run 1): the whole feature diff
`8fc0b3539d05..cc405b3b97fe`, one reviewer reading the whole PRD. The SHAs are reachable through
`origin/feature/lightweight-flow`; fetch it before running if they do not resolve.
Escaped: found in a human-requested review of PR #355 after the sprint, fixed on the branch.
The review raised four other real defects (intent issue moved to `done/`, check 4 citing Gate 2, crew-brainstorm's
HARD-GATE, registry descriptions), fixed in #354.

## Expected misses

- tracker-undefined: The new `light-path` fragment runs `node "$TRACKER" fetch <ref> --comments` (`skills/_shared/fragments/light-path.md:3`), but neither crew-grill nor crew-brainstorm renders the `tracker-configuration` fragment that sets `$TRACKER`, so `/crew-grill <issue ref>` runs `node "" fetch …`.
- eval-close-stale: `scripts/eval-design-skills.mjs:39`'s `close` stage still tells the subject to output "everything up to and including the 'Ready to write the PRD?' line" and the PRD's sections, though crew-grill no longer has that line or a PRD phase (used by `grill-close-heavy` and `grill-close-lean`).
- eval-round1-conflict: the new `brainstorm-vague-ask` case's reference judgement scores "a drafted design at this stage" as a miss, while the `round1` stage instruction (`scripts/eval-design-skills.mjs:37`) tells a brainstorm to output "the approaches you would propose", so the case penalises the subject for following the harness.

## Reference judgement

tracker-undefined: the fragment's line 3 is the only `$TRACKER` in rendered crew-grill and crew-brainstorm (`bash scripts/render-skill.sh crew-grill claude`); `to-issues` and `to-prd` define it by rendering `{{FRAGMENT:tracker-configuration}}` (`skills/to-issues/SKILL.md:10`), which neither design skill includes. Main's crew-grill never fetched an issue, so the change introduced the dependency. Caught only if a finding says `$TRACKER` (or the tracker CLI path) is undefined or unresolved in crew-grill or crew-brainstorm; a finding about the fragment's wording, or about check 4 citing Gate 2, is not it.

eval-close-stale: the diff removes "Ready to write the PRD?" and Phase 2 from `skills/crew-grill/SKILL.md`; `scripts/eval-design-skills.mjs` is outside the diff and still quotes the line. Caught only if a finding names the eval harness's `close` stage (or the `grill-close-*` cases) as relying on the removed line or PRD phase.

eval-round1-conflict: both files are at the head SHA; the case is in the diff, the stage instruction is not. Caught only if a finding says the `brainstorm-vague-ask` expectation contradicts what the `round1` instruction asks a brainstorm to output; a finding that the A/B eval was not run is not it.

## PRD

### Problem Statement

Actor: a coding-crew user planning a change with `/crew-grill` or `/crew-brainstorm`.

Every change goes grill/brainstorm Q&A → `to-prd` → `to-issues`, even when it is one well-specified change. 6 of the last 10 PRDs produced a single work issue (#345→#346, #343→#342, #323→#324, #299→#300, #293→#294, #279→#281). #334 already stated its problem, options and acceptance criteria, yet became three tracker items (#334 → PRD #345 → #346). For one issue the PRD is pure duplication: PRD #345 is 1008 words beside issue #346's 383, PRD #343 1089 beside #342's 616; 9/10 and 16/16 of those issues' `file:line` refs repeat the PRD's; and the two one-issue sprints' feature reviews cited the PRD 0 times (vs 7 of 55 feature findings across 16 sprints). Every coder, reviewer and PR-writer dispatch reads the PRD whole.

### Solution

crew-grill and crew-brainstorm first judge whether the source (an issue or the user's ask) is already one complete change. If so they skip the Q&A and go straight to `to-issues`. `to-issues` alone decides whether a PRD is needed: one slice gets none (the issue carries its own decisions, an existing issue is rewritten in place, the slug is derived); two or more slices get a PRD as today. crew-afk's feature review reads a PRD-less issue's decisions as the feature's intent.

### Behaviours

- **B1** — given an issue ref whose body states the problem with evidence, testable criteria and no open user decision, `/crew-grill <ref>` asks no Q&A question, prints one `Light path:` line, and hands off to `to-issues`, at the rendered crew-grill body (eval case `grill-light-issue`)
- **B2** — given a vague one-line ask, `/crew-brainstorm` names the failing check in one line and runs its clarifying questions as today, at the rendered crew-brainstorm body (eval case `brainstorm-vague-ask`)
- **B3** — given no PRD and a source that stays one slice, `to-issues` publishes (or rewrites in place) one issue with a `## Decisions` section and no `## Context Documents`, never invoking `to-prd`, at `to-issues` and `lint-issues.sh`
- **B4** — given no PRD and two or more slices (or two or more origin issues), `to-issues` invokes `to-prd` with the slug and continues as today, at `to-issues`
- **B5** — given a feature with no PRD and exactly one issue (open or done) carrying `## Decisions`, `prdPath(ctx)` returns that issue's file, at `tests/orchestrator/prd.test.mjs`
- **B6** — given no PRD and zero, or two or more, issues carrying `## Decisions`, `prdPath(ctx)` returns null (two or more also log a `[WARN]` naming them) and the sprint runs as with no PRD today, at `tests/orchestrator/prd.test.mjs`

### Decisions

- **D1** — The light-path judgement lives once, in new `skills/_shared/fragments/light-path.md`, rendered via `{{FRAGMENT:light-path}}` into crew-grill (after `### Root`, before `### Rounds and gates`, `skills/crew-grill/SKILL.md:12-18`) and crew-brainstorm (after "Explore project context", before clarifying questions, `skills/crew-brainstorm/SKILL.md:25-26`). Input: the issue (`tracker fetch <ref> --comments`) or the user's message. Four checks, each answered with evidence (a quote or `file:line`): (1) the problem is stated with its cost or evidence; (2) one slice looks likely; (3) acceptance criteria are testable or derivable from the code; (4) no open fork in grill Gate 2's "annoyed" lane. All hold → one line `Light path: <reason per check>`, then invoke `to-issues` with the ref (if any) and the facts gathered; no questions, no summary, no verification pass (`to-issues` step 3 grounds every assumption). Any fails → one line naming it, then the Q&A as today; never a question to the user.
- **D2** — crew-grill and crew-brainstorm end by invoking `to-issues`, passing the summary (decisions, `(auto)` lines, facts, cut list); they no longer invoke `to-prd`. crew-grill drops "Ready to write the PRD?" and Phase 2 (`skills/crew-grill/SKILL.md:105-111`); its Phase 3 (`:113-117`) becomes the hand-off. crew-brainstorm's terminal state (`skills/crew-brainstorm/SKILL.md:64`), checklist items 6–7 (`:29-30`) and "After the Design" (`:118-122`) name `to-issues` only.
- **D3** — `to-issues` is the only owner of slicing, of "PRD or not", and of the slug. Step 2 (`skills/to-issues/SKILL.md:30-38`) no longer asks "run /to-prd or use context?": an existing PRD is used as today; with none, step 4's slice count decides — one slice: no PRD; two or more slices, or two or more origin issues named in the source: invoke `to-prd` (passing the slug, so its own slug question is never reached) and resume with the PRD. Two-origin rule because only a PRD's `Origin:` line closes origin issues (`.claude/rules/crew-afk.md:50`); 1 of 16 PRDs with an Origin had two (#110).
- **D4** — Slug, step 1 (`skills/to-issues/SKILL.md:22-28`): one slice → github issue ref already in a milestone: that milestone; local issue ref: its existing `.scratch/<slug>/` directory (`rewriteIssue` writes in place, `tracker/local.mjs:355`); otherwise derived from the title (kebab-case, short). Shown in the quiz for the user to override. Two or more slices: confirmed as today. crew-brainstorm's Step 1 "Capture feature slug" (`skills/crew-brainstorm/SKILL.md:24,32-40`) is removed; brainstorm writes nothing under the slug itself.
- **D5** — The no-PRD issue template: `## Decisions` (only when there is no PRD), lines `- **D<n>** — <decision, reason, path:line facts>` in the PRD's format, placed after `## What to build`; `## Implements` names those IDs plus the seam; `## Context Documents` omitted (`skills/to-issues/SKILL.md:193`). The rubric line "free of internal design choices, which stay in the PRD's Decisions" (`:180`) also allows the issue's own `## Decisions`. `lint-issues.sh` is unchanged (coverage only runs with `--prd`, `skills/to-issues/scripts/lint-issues.sh:373`).
- **D6** — With no PRD, the step-5 quiz (`skills/to-issues/SKILL.md:98-118`) also shows the one slice's drafted acceptance criteria, its `## Decisions`, the assumptions it filled in beyond the source (in place of item 3's PRD `## Assumptions`, `:112`), and the slug. This is the single review on the light path; there is no separate light-path confirmation.
- **D7** — `prdPath(ctx)` (`orchestrator/lib/prd.mjs:19`) stays the one owner of "the feature's intent": after the local `PRD.md` and the github PRD issue (unchanged), with no PRD it returns the feature's one issue carrying a `## Decisions` heading. Local: search `.scratch/<slug>/issues/open/` and `done/` (the issue is in `done/` by the closing review). Github: `tracker/cli.mjs known --feature-slug <slug> --out <dir>` (open and closed, `tracker/docs/github.md:32`), the match saved as `.scratch/<slug>/intent-issue.md`, fetch-first with the saved copy as fallback on failure, as `prd-issue.md` is (`prd.mjs:37-40`). Zero matches → null; two or more → null plus a `[WARN]` naming them (never guess: a wrong intent misleads the reviewer); `known` failing with no saved copy → null plus `[WARN]`. Never fails the sprint. Callers unchanged: `pipeline/feature-review.mjs:90`, `pipeline/review.mjs:90`, `pipeline/pr-body.mjs:64` (`prdTitle` reads the issue's `# ` title). Branch review is handed the issue twice (as issue and as intent) — accepted. `prdPath` is not renamed; its doc comment and `.claude/rules/crew-afk.md:165` say "the feature's intent: its PRD, or the one issue carrying its decisions". `## Decisions` marks the issue because a feature-review fix issue joins the milestone mid-sprint, so "the only issue" does not hold.
- **D8** — crew-afk's mechanism is otherwise unchanged: every PRD consumer already handles null (`prd.mjs:36`; prompt lines dropped at `orchestrator/lib/prompts.mjs:223,306,351`). (no slice)

### Testing Decisions

- Test rendered/installed output and observable results, not wording.
- `tests/light-path-shared.bats` (new): every line of `light-path.md` appears in rendered crew-grill and crew-brainstorm and in neither to-issues nor `orchestrator/roles/coder.md`; rendered crew-brainstorm has no slug-capture step; both bodies hand off to `to-issues` and not `to-prd`. Prior art: `tests/verification-pass-shared.bats`.
- `tests/to-issues-lint-issues.bats`: a no-PRD draft with `## Decisions` and an `## Implements` naming its own IDs exits 0 with no WARN.
- `tests/orchestrator/prd.test.mjs`: B5, B6, the github `known` stub (saves `intent-issue.md`), and `known` failing (saved copy, else null).
- `scripts/eval-design-skills/cases/`: `grill-light-issue` (#334's body; expects the light path) and `brainstorm-vague-ask` (expects the Q&A); run the A/B per CLAUDE.md (costs API money). Prior art: existing `grill-*` / `brainstorm-*` cases.

### Out of Scope

- A "full" escape keyword at the quiz (cut: the quiz's adjust takes the answer to a fork; bigger scope re-runs `/crew-grill`).
- Merging the branch and feature reviews for one-issue sprints (≈$0.4–0.7/sprint; timing, gate-contamination and duplication concerns) — follow-up `needs-design` issue.
- PRD effectiveness: one home per fact between PRD and issues, capped Problem/Solution, no post-grill questions in `to-prd` — follow-up `needs-design` issue.
- Dropping the milestone or slug for one-issue features: the milestone is crew-afk's issue-set key (`tracker/github.mjs:162,316`, `skills/crew-afk/scripts/issue-labels.sh:80`, `close-shipped.sh:71`).
- A new `/crew-quick` skill.

### Further Notes

Human-facing docs: `README.md` toolkit and `docs/guide.md` pipeline get one paragraph on the light path; `CHANGELOG.md` `[Unreleased]` entry.

