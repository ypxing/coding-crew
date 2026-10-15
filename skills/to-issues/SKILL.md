---
name: to-issues
description: >
  Breaks a plan, spec or PRD into independently-grabbable issues on the project issue tracker, using
  tracer-bullet vertical slices. Use when the user wants to convert a plan into issues, create implementation
  tickets, or break down work into issues.
---

# To Issues

Break a plan into independently-grabbable issues using vertical slices (tracer bullets).

{{FRAGMENT:tracker-configuration}}

## Process

### 1. Gather context and determine feature slug

Work from whatever is already in the conversation context. If the user passes an issue reference as an argument, it must be a ref the configured tracker accepts (how that tracker writes one is in `<skill-dir>/scripts/tracker/docs/<kind>.md`, `<kind>` from `node "$TRACKER" config`) — the CLI refuses anything else with exit 2. A file the caller names as the source (`add-tests`' `.scratch/<feature-slug>/findings.md`) is the plan. Do NOT fetch from arbitrary user-supplied URLs or an unconfigured remote tracker.

When the plan references an issue, read its full body and its comments, not just the title: `node "$TRACKER" fetch <ref> --comments`.

**A design summary as the source.** When `crew-grill` or `crew-brainstorm` hands over its summary, each part of it holds what nothing else does, and each has one home in what you write:

- **`(auto)` lines** — decisions made on the user's behalf, never put to them: each becomes a `D<n>` line tagged `(auto)`, in the PRD's Decisions or, with no PRD, the issue's `## Decisions`, so a reviewer can still catch it.
- **Established facts** — each goes into the Decisions it supports, with its citation (`path:line`, doc or spec), so the coder does not re-derive it.
- **The cut list** — each item, with why it was cut, goes to the PRD's Out of Scope or, with no PRD, the issue's `## Out of Scope`, so the coder does not re-add it.

**An existing issue as the source.** `/to-issues <ref>` on an existing issue is how it moves from `needs-triage` to `ready-for-agent`: it goes through steps 2–5 like any plan. If it is still one slice after step 4, step 6 rewrites that issue in place; if it splits into several slices, each becomes a new child issue with `## Parent` naming it. An issue with a column-0 `Source:` line outside a code fence (`Source: review (<branch>)` or `Source: <report> (<branch>)`, anywhere in the body) was promoted from review findings already judged: it is not checked against the design standard.

Determine the **feature slug** (the root issue or directory the issues are filed under):

1. If the user provided a path argument, extract the slug from it (e.g. `.scratch/auth-flow/...` → `auth-flow`).
2. Otherwise, run `node "$TRACKER" features` — one `<slug>\t<open|closed>\t<ready-count>` line per feature — and check if one slug clearly matches the topic being discussed.
3. If no match is found, ask the user: "What feature slug should I use?"

Never guess the slug silently — confirm with the user if there's any ambiguity. **Before using a slug `features` lists, ask the user** whether to extend that feature or choose a new slug; a closed feature is still a taken slug. `to-prd` relies on this question and does not ask it again.

**One slice and at most one origin issue, no PRD:** the slug needs no question. Use, in order: a github issue ref's own `Feature: <slug>` line, when its body has one; a local issue ref's feature (`rewrite` writes in place); otherwise one derived from the title (kebab-case, short). Step 5's quiz shows it for the user to override. With two or more slices, or two or more origin issues, the slug is confirmed as above.

### 2. Check for a PRD

Run `node "$TRACKER" prd --feature-slug <feature-slug>`. Exit 0 prints the PRD: use it as the primary source material for decomposition, and save that output to `.scratch/<feature-slug>/.drafts/PRD.md` for step 6's lint. Note the PRD's ref — step 6 cites it in each work issue: `#<n>` when the output opens with `<!-- PRD issue #<n>: … -->`, else `.scratch/<feature-slug>/PRD.md`. Exit 3 means there is none.

With no PRD, work from the conversation context; step 4's slice count decides whether one is needed, and step 4's last paragraph writes it. One slice publishes without a PRD (its issue carries its own `## Decisions`).

### 3. Explore the codebase

Not optional. If you have not already explored the code each slice will touch, do so now. Issue titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

**Ground every assumption.** An issue drafted from the PRD alone can name a function that does not exist or a bug already fixed, and the coder reads the code only after the issue is written. For each thing a slice assumes about the *current* code — an existing module, function, schema or behavior, and for a bug the code path that produces it — confirm it at a `file:line`. Something the slice creates is new, and its issue says so ("adds …"). What exploration contradicts goes to the quiz below, never silently into an issue:

- **Already there** — the behavior exists, or the bug is already fixed: drop the slice, or keep it as a test-only slice if nothing pins the behavior.
- **Wrong assumption** — the PRD or plan assumes something the code rules out (a missing counterpart, a decision an ADR or the code contradicts): ask how to resolve it before drafting.
- **Fails the design standard** — the slice, or the existing issue it came from, fails a criterion of the standard below (no cited problem; one check standing in for two questions; a lookup for a fact already known earlier): name the criterion and its `file:line` evidence, and ask how to reshape it before drafting. An auto-promoted issue (a column-0 `Source:` line, step 1) is exempt.

{{FRAGMENT:design-standard}}

While exploring, look for **prefactoring opportunities** — changes that would make the feature implementation significantly easier. "Make the change easy, then make the easy change." Prefactoring is sequenced first (at the start of the slice, or as its own first slice when the work is split) so the feature work builds on a clean foundation.

Also note any **shared surfaces**: a schema/table, a shared type, or an existing function/module that more than one slice would need to modify. This is a narrower thing than "touches the same file": two slices adding code to separate parts of a file do not interact, while a shared surface is where two slices would plausibly change the *same specific behavior*. Carry any you find into step 4, and apply its edge rule to each one.

### 4. Draft vertical slices

Start from **one slice for the whole PRD**. Split it only for one of these reasons, and name the reason on every split:

1. **Context budget** — one coder cannot hold it in one fresh session. Estimate the slice's peak context: the bytes of the files it reads or edits ÷ ~3.5 tokens, times two (the coder reads each file, and its re-reads, diffs and test output add about as much again), plus the fixed context every coder dispatch loads once (the solve-issue skill, the skills it follows, `CLAUDE.md` or `AGENTS.md`, the PRD, the issue), measured the same way. Split when the estimate is over ~120k tokens, or over 60% of the coder model's context window if that is smaller, into the fewest slices that each come under it. For scale, slices of 7–44 files and ~100–1600 changed lines have each landed in one coder session.
2. **Human boundary** — part is HITL, the rest AFK.
3. **Expand–contract order** — steps from the PRD's `## Compatibility & Migration` (or `<skill-dir>/references/expand-contract.md`) that must land in sequence.

Unrelated modules or test seams are not a reason on their own: they only cost the coder context, which reason 1 covers. One slice may deliver several behaviours. A context-budget split needs the slice it splits to be over the threshold; otherwise merge it back.

Each issue is a **tracer bullet**: a vertical slice that cuts through every integration layer its behaviour needs end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and landed without human interaction. Prefer AFK over HITL where possible.

solve-feature runs a feature's issues one after another on one branch, so every slice costs a fixed overhead on top of its code: a coder dispatch, which loads the fixed context again, plus a run of the project's checks. A `Blocked by` edge only orders that sequence. A split is worth making only when its reason outweighs that overhead.

**Edge rule.** Between slices that remain split, add `Blocked by` only when one of these rows matches:

1. One slice consumes what the other produces (a signature, shape or output) → `Blocked by`.
2. The two change the same meaning (the same behaviour, function or rule) → `Blocked by`.

Otherwise add no edge: edits to separate parts of a file do not interact, and a needless edge only constrains the order for nothing. Same-meaning edits are ordered so the later slice builds on what the earlier one settled instead of guessing at it. An edge can follow any of the three split reasons; only these rows decide it.

<vertical-slice-rules>
- Each behaviour a slice delivers is externally observable, verified at the highest existing seam (the outermost place a test can already exercise it: a CLI invocation, an HTTP call, a script's exit code and output). "Schema / API / UI" is only an example of the layers such a behaviour may cut through, not a required shape — a slice touches whichever layers its behaviours need
- When a slice's behaviour is prose (a skill, prompt or doc), its check is never a grep of the rendered output: its criteria are checkable from the diff, and its behaviour is judged by an eval where a harness exists
- If the work is split, the first slice is the thinnest end-to-end path: the narrowest behaviour that proves the layers connect. Later slices widen it
- A completed slice is demoable or verifiable on its own
- Each slice is sized to fit in a single fresh context window — the context-budget reason above is the only size rule
- A slice with more than 10 acceptance criteria is flagged for the user (step 5), never on its own a rule to split
- Any prefactoring is sequenced first: at the start of the slice, or as the first slice when the work is split
</vertical-slice-rules>

**Wide refactor?** One mechanical change — rename a column, retype a shared symbol — whose blast radius fans across the whole codebase, so no vertical slice can land green on its own: read `<skill-dir>/references/expand-contract.md` before slicing it.

**Expand–contract sequencing** is drawn from the PRD's `## Compatibility & Migration` when it exists: each expand, migrate and contract step it names becomes a slice (or part of one) sequenced in that order, with the contract step blocked by every migrate step. Without that section, do not invent a migration sequence.

**PRD for a split.** After step 4, with two or more slices (or two or more origin issues named in the source) and no PRD from step 2, invoke `to-prd` with the feature slug (so its own slug question is never reached). Then save the PRD it wrote, `node "$TRACKER" prd --feature-slug <feature-slug>`, to `.scratch/<feature-slug>/.drafts/PRD.md`, so the lint's `--prd` and the builder check receive it, and note its ref as step 2 does. Then do step 4.5 against it. Origin issues count because only a PRD's `Origin:` line closes them.

### 4.5. Trace PRD IDs to slices

Before the quiz, build a coverage table: one row per `D<n>` / `B<n>` ID in the PRD (lines starting `- **D<n>** — …` / `- **B<n>** — …`), with the slice(s) that implement it. An ID no slice covers is an empty row, except one whose PRD line ends in `(no slice)`: the PRD says it needs none, so its row reads `(no slice)` and is not asked about in step 5 (`lint-issues.sh` does not warn for it either). With no IDs in the PRD (or no PRD), the table is skipped entirely. Each slice's `## Implements` in step 6 must then name the IDs the table gave it.

### 5. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **What it delivers**: the end-to-end behaviour this slice makes work, from the user's perspective
- **Estimated peak context**: the step 4 estimate, in tokens

Show the coverage table from step 4.5 (when there is one), then ask only what needs a decision. Walk these in order and omit any that is empty:

1. **Contradicted assumptions** — what the plan assumes, what the code shows at `file:line`, and the slice it affects; resolve each before the rest.
2. **Design-standard failures** — each slice that fails a criterion of the design standard (step 3): the criterion, its evidence at `file:line`, and the reshape you propose.
3. **The PRD's `## Assumptions`** — each one the slices lean on, for the user to confirm or correct. With no PRD, show instead the one slice's drafted acceptance criteria, its `## Decisions`, the assumptions you filled in beyond the source, and the slug: this is the single review on the light path.
4. **PRD IDs no slice covers** — the empty rows of the coverage table: add a slice, fold the ID into one, or confirm it is out of scope.
5. **Slices near the budget or over 10 criteria** — each slice whose estimate is within ~20% of step 4's threshold, or that carries more than 10 acceptance criteria, with its estimate, for the user to confirm it fits one coder session. Neither is a reason to split.
6. **Splits and edges** — one line per split naming its reason from step 4 (context budget with the merged slice's estimate, human boundary, expand–contract order), and one line per `Blocked by` edge naming the edge-rule row that produced it, each naming its slices, for the user to override. Don't ask whether an overlap needs an edge; the rule decided, the user overrides.
7. **HITL choices** — each slice marked HITL, and why a human is needed (that reason becomes the block's `### Why a person`); the rest are AFK.

Then one approve/adjust prompt: approve the breakdown as shown, or say what to adjust. Iterate until the user approves. Do not ask generic questions about granularity, blocking edges, combining slices or HITL/AFK — a breakdown with nothing to list above needs only the approve/adjust prompt.

A return from step 6's builder check asks only the questions it marked yours, in one message ranked by importance, then goes back to step 6 to re-render and re-lint.

### 5.5. Cross-cutting rules from the PRD

Before writing issues, read the PRD's `## Decisions` and `## Testing Decisions` for a rule that binds more than one slice ("every endpoint must …", "all calls retry …"). Each slice carries such a rule in `## Cross-cutting Requirements` only when its own acceptance criteria do not already cover it; otherwise the criterion is the home and the section is omitted. There is no category list to scan.

### 6. Write the issues

**Drafts.** Render every approved slice as a draft in `.scratch/<feature-slug>/.drafts/` — the same files whatever the tracker is: `NN-<slug>.md`, numbered from `01` in dependency order (blockers first), opening with a `# <title>` line and a `Status:` line (`Status: ready-for-agent` unless the user specifies otherwise), then the issue body template below. `## Blocked by` names another draft by its filename, or an issue that already exists by the filename `known` gives it; beside the drafts goes `deps.json` (below). The CLI turns each draft filename into the ref its issue is created under.

**Known issues.** Write the feature's existing issues beside the drafts:

```bash
node "$TRACKER" known --feature-slug <feature-slug> --out .scratch/<feature-slug>/.drafts/known
```

One file per issue already in the feature, named by the ref a `## Blocked by` entry uses for it.

**Dependency map.** Write `.scratch/<feature-slug>/.drafts/deps.json` with the drafts, before the lint below (its `--deps` compares the map with the `## Blocked by` prose) — a flat map from each draft's filename to the filenames of the drafts blocking it, e.g.:

```json
{
  "01-first.md": [],
  "02-second.md": ["01-first.md"],
  "03-third.md": ["01-first.md", "02-second.md"]
}
```

Source it from the same blocking edges the user confirmed in the quiz step — do not re-derive it from the `## Blocked by` prose. `publish-issues` creates the issues in this map's order and records the same edges, under the issues' final refs, where `next` reads them to decide whether an issue is ready to dispatch. Include every draft, even ones with no blockers (`[]`); an edge to an issue that already exists lives only in the draft's `## Blocked by`.

**Lint before publishing.** Run, from the project root:

```bash
bash <skill-dir>/scripts/lint-issues.sh --issue <draft> [--issue <draft> …] \
  [--known <file> …] --deps .scratch/<feature-slug>/.drafts/deps.json [--prd .scratch/<feature-slug>/.drafts/PRD.md]
```

Pass every file `known` wrote as a `--known <file>` (never linted, but a `## Blocked by` ref resolves to it by basename, and an existing `--known` file's `## Implements` counts toward `--prd` coverage, so a PRD ID an earlier issue already implements is not reported uncovered), and `--prd` whenever `.scratch/<feature-slug>/.drafts/PRD.md` exists (step 2's PRD, or the one `to-prd` wrote). Exit 1 means publish nothing: show the `ERROR` lines; the skill returns to the quiz (step 5) to fix them, then render and lint again. Exit 0 prints at most `WARN` lines: show them and continue — publishing continues. The shared-file `WARN` (two issues naming the same file with no `## Blocked by` path between them) is advisory: it is never by itself grounds for a `Blocked by` edge — only the edge rule's rows 1–2 are. Exit 2 is a usage error in how you called it: fix the call.

**Builder check.** After lint exits 0 and before publishing, a fresh subagent reads the drafts cold, the way the coder solve-feature dispatches will: the writer fills omissions from memory, and that is the blind spot this check exists for. Skip it when every draft carries a column-0 `Source:` line (findings already judged, step 1). When the session has no subagent tool, print `builder check skipped: no subagent tool` and publish: never read the drafts yourself in its place.

Give the subagent only the paths of the drafts, `.scratch/<feature-slug>/.drafts/PRD.md` and `known/` when they exist, and read access to the repo. Never give it the conversation, a design summary or the quiz answers. Its prompt:

```text
You are the coder solve-feature will dispatch for these issues. You can read the repo but cannot talk to whoever wrote them. Read each draft in <drafts dir> and <PRD path> if one exists; known/ holds the feature's existing issues. Your job is the omissions and ambiguities you would have to guess at: report only the questions where a wrong guess changes what you build or how a criterion is checked. For each one, give the draft, the question, and why the answer matters. A contradiction between two drafts, or between a draft and the code, is a question like any other. Rank them by importance. Skip anything a draft leaves to the coder, anything you could reasonably decide, and wording. If nothing important is left, say "nothing important left".
```

Sort each question it returns into one of three piles, once:

- **Answered** — the conversation or the code settles it: write the answer into the draft.
- **Minor** — a sensible coder could settle it without changing what gets built: settle it and record one `(auto)` line as the last line of the draft's `## What to build`.
- **Yours** — only the user can answer it, and it changes what gets built: return to step 5 the way a lint `ERROR` does, which asks only these, in one message ranked by importance, then re-render, re-lint and publish.

Print `builder check: N answered, M (auto), K asked`. One round: dispatch no second check after the answers, and re-lint any draft you changed.

**Publish.** Then, from the project root:

```bash
node "$TRACKER" publish-issues --feature-slug <feature-slug> --drafts .scratch/<feature-slug>/.drafts
```

It creates the issues in dependency order and prints one `<draft> <ref>` line per issue; the drafts directory (`known/` and `PRD.md` included) is deleted after a full publish. Two exits are questions for the user, and both write nothing:

- **Exit 4** — the feature has completed issues: stop, and tell the user: "Some issues are already completed. Please reconcile manually (delete or archive the old issues directory) before re-running."
- **Exit 5** — the feature already has open issues, which publishing would overwrite (stderr lists them): show them, warn they will be overwritten, and ask for confirmation. On yes, re-run the same command with `--replace`; on no, stop.

Exit 1 before anything is created means a draft's `## Blocked by` names a file that is neither a draft nor a `known` issue, or (with `--replace`) an open issue `--replace` would delete: fix that draft's `## Blocked by` and `deps.json`, lint again and re-publish. On any other exit 1 the stderr names the issues created before the failure, and the drafts stay in place: report both, fix the cause, and ask the user before re-running — a re-run creates every draft again.

**A source issue that stayed one slice** is rewritten in place instead of published (no `## Parent`): write it as a draft (title, `Status:` line and body, as above) to a file outside `.drafts/` and run

```bash
node "$TRACKER" rewrite <ref> --body-file <file> --status <status> --feature-slug <feature-slug>
```

where `<status>` is the slice's status (`ready-for-agent`, or `ready-for-human`) — the status is what solve-feature's `next` picks by, so a body rewrite alone would leave it `needs-triage` and never dispatched; `rewrite` also files it under the feature. Keep the source's title and its column-0 `Source:` line as `fetch` printed them, so the rewritten issue stays exempt from the design standard (step 1). A source that split into several slices keeps it open and gets one child issue per slice, each with `## Parent`. Use the issue body template below.

**`## Requires`.** When a slice's checks need a service, a credential or a tool the project's install does not guarantee (a LocalStack container, an auth token, a CLI), write one backticked shell command per requirement — exit 0 means satisfied; it runs on the host from the project root, before any coder is dispatched, and may start the service it checks. Run each one while authoring. If one fails, publish the issue as `Status: ready-for-human` instead of `ready-for-agent`, because no coder can supply what it lacks: the failing command and its output go in `### Why a person`, and the fix goes in `### Steps`. A command that can only hold once one of the issue's blockers lands (a Makefile target that blocker adds) is not run now — `solve-issue`'s preflight runs it when the issue's turn comes.

**`ready-for-human` bodies.** Every slice published as `ready-for-human` (a HITL slice from step 5, or a failing `## Requires`) opens with this block:

{{FRAGMENT:human-issue}}

**Acceptance criteria describe this slice's behaviour, not repo-wide hygiene.** A rule every change must follow that a check already enforces — a version bump, a changelog entry, lint — is not a criterion: the verify gate holds it, and as a per-issue criterion each issue on the branch repeats it (a second version bump, a duplicate changelog entry).

A criterion that needs a paid run, a manual measurement or a person is not an acceptance criterion: no unattended coder can meet it, so it stays unmet and the issue never lands. It goes to the PRD's human steps or a `ready-for-human` issue.

**Acceptance-criteria rubric.** The reviewer gates on these, so each criterion is:

- one observable behaviour or consumed contract (a signature, shape or output another issue relies on), checkable from the diff plus the checks — never "tests pass";
- for a negative ("never writes outside X"), accompanied by the mechanism that prevents it — a negative with no named mechanism cannot be checked, so the criterion names the mechanism that prevents it;
- free of internal design choices, which stay in the PRD's Decisions (or the issue's own `## Decisions` when there is no PRD) where the reviewer judges them as findings — unless the choice is itself the requirement (e.g. "one batched call" as a performance bound).

A slice that takes input or calls something external must carry failure-behaviour criteria: invalid input, missing dependency, failing call — what the caller observes in each. This is how the PRD's `## Trust Boundaries & Risks` reaches the gated criteria.

A slice that adds a parser, validator or gate for an input the repo already holds examples of (issue files, configs, fixtures, stored records) carries one criterion that it accepts them, so the new code is tested against what people actually wrote, not only against inputs written from the PRD. Find the examples now and name them in the criterion, to be copied into committed test fixtures — never read from a live or gitignored directory, whose contents differ per machine and are absent in CI. For example: `- [ ] lint-issues.sh exits 0 on fixtures copied from .scratch/add-tests/issues/`. The repo holds no such examples (a new format) → no such criterion. The PRD's `## Compatibility & Migration` names them when it exists.

Number the drafts in dependency order (blockers first), working the **frontier**: any issue whose blockers are all done. For a linear chain that means top-to-bottom; for a DAG with multiple independent roots, number all currently unblocked issues before their dependents.

<issue-template>
# <title>

Status: ready-for-agent

## Context Documents

> **Optional — only include this section if a PRD exists for this feature. Omit entirely if no PRD exists.**

- PRD: <the PRD's ref from step 2 — `#<n>`, or `.scratch/<feature-slug>/PRD.md`>

Read this document before implementing. It contains architecture decisions, integration constraints, and technical context essential for this issue.

## Parent

A reference to the parent issue on the issue tracker (if the source was an existing issue that split into several slices; omit this section otherwise, including when that issue is rewritten in place).

## What to build

A concise description of this vertical slice: the end-to-end behavior, not layer-by-layer implementation. Its first sentence is a one-line summary.

This section may cite grounded paths and signatures (confirmed in step 3). If a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it here and note briefly that it came from a prototype. Trim to the decision-rich parts — not the working demo, just the important bits.

## Decisions

> **Optional — only include this section when no PRD exists. Omit it otherwise.**

- **D<n>** — <decision, reason, `path:line` facts>

## Out of Scope

> **Optional — only include this section when no PRD exists and the source cut something (a design summary's cut list). Omit it otherwise.**

- <what was cut> — <why>

## Implements

The PRD IDs this issue carries (with no PRD, the IDs of its own `## Decisions`) (e.g. `D3, B2`), plus the seam it is verified at (the highest existing test seam that exercises it).

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Cross-cutting Requirements

> **Optional — only include this section for a PRD rule that binds this issue and that its acceptance criteria do not already cover. Omit entirely otherwise.**

Rules from the PRD that apply to this implementation (a few items at most):

- [ ] [PRD rule not already covered by an acceptance criterion]

## Requires

> **Optional — only include this section when the issue's checks need a service, credential or tool the project's own install does not guarantee. Omit entirely otherwise.**

- `<one shell command per requirement, exit 0 = satisfied — e.g. make start-localstack, test -n "$LOCALSTACK_AUTH_TOKEN">`

## Blocked by

- The blocking draft's filename, or an existing issue's `known` filename (if any)

Or "None - can start immediately" if no blockers.

## Interfaces

> **Optional — only include this section if this issue consumes from or is consumed by another issue. Omit entirely otherwise.**

### Consumes:

Exact signatures, types, or contracts expected from the blocking issues listed above. Be precise enough that the agent implementing a blocker knows what shape to expose. Omit when this issue consumes nothing.

### Exposes:

Exact signatures, types, or contracts this issue produces for any downstream issues that depend on it. A root issue (no blockers) that another issue consumes from has `### Exposes:`.

</issue-template>

Do NOT close or modify any parent issue. A single-slice source rewritten in place is not a parent: it gets only the in-place `rewrite` step 6 describes — its body and its status.

**Security**: Only read from and write to paths under `.scratch/` within the current repo, and reach the tracker only through the tracker CLI's ops, which act on the tracker `config.json` configures. Never fetch from arbitrary external URLs, an unconfigured remote API, or paths outside the repository root.
