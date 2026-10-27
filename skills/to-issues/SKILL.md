---
name: to-issues
description: >
  Breaks a plan, spec or PRD into independently-grabbable issues on the project issue tracker, using
  tracer-bullet vertical slices. Use when the user wants to convert a plan into issues, create implementation
  tickets, or break down work into issues.
---

# To Issues

Break a plan into independently-grabbable issues using vertical slices (tracer bullets). An issue is read cold by an implementer who cannot talk to whoever wrote it: everything they would have to guess at is written down, and nothing they can decide themselves is.

<!-- fragment:missing-library -->
**Shared scripts.** The scripts this skill runs live in the `coding-crew-lib` skill, installed beside it at
`<skill-dir>/../coding-crew-lib` (`<skill-dir>` being the directory you read this file from). Before the first
command that runs one, check that directory exists. If it does not, stop and tell the user to install it at this
skill's scope, `npx skills add ypxing/coding-crew -s coding-crew-lib` (adding `-g` when this skill is installed at
user level), or to re-run coding-crew's `install.sh`.
<!-- /fragment:missing-library -->

<!-- fragment:tracker-configuration -->
## Tracker Configuration

Every tracker op runs through the tracker CLI, `TRACKER=<skill-dir>/../coding-crew-lib/scripts/tracker/cli.mjs` (`<skill-dir>` being the
directory you read this file from), as `node "$TRACKER" <op> …`; nothing else reads or writes the tracker. Before the
first op run `node "$TRACKER" config` (prints `tracker=<kind>` and `configured=yes|no`). On `configured=no` on an
interactive run, invoke the `configure-tracker` skill, then continue; on a non-interactive run (a headless/`-p`
invocation or a subagent) never ask: proceed as `local`. The tracker's refs, statuses and labels are in
`<skill-dir>/../coding-crew-lib/scripts/tracker/docs/<kind>.md`.

Exit codes, every op: 0 ok; 3 not found; on 1 (the op failed) or 2 (a usage error or an invalid ref), report the
stderr verbatim, fix its cause (an input, auth, the network) and re-run the op, never performing it with the tracker's
own tool. `publish-issues` adds 4 and 5, which the skill that publishes handles.
<!-- /fragment:tracker-configuration -->

**Non-interactive run.** A run whose prompt says it is non-interactive asks nothing: read
`<skill-dir>/references/non-interactive.md` before step 1.

## Process

### 1. Gather context and determine feature slug

Work from whatever is already in the conversation context. If the user passes an issue reference as an argument, it must be a ref the configured tracker accepts (how that tracker writes one is in `<skill-dir>/../coding-crew-lib/scripts/tracker/docs/<kind>.md`, `<kind>` from `node "$TRACKER" config`) — the CLI refuses anything else with exit 2. A file the caller names as the source (`add-tests`' `.coding-crew/scratch/<feature-slug>/findings.md`) is the plan. Do NOT fetch from arbitrary user-supplied URLs or an unconfigured remote tracker.

When the plan references an issue, read its full body and its comments, not just the title: `node "$TRACKER" fetch <ref> --comments`.

**A design summary as the source.** When `crew-grill` or `crew-brainstorm` hands over its summary, each part of it holds what nothing else does, and each has one home in what you write:

- **`(auto)` lines** — decisions made on the user's behalf, never put to them: each becomes a `D<n>` line tagged `(auto)`, in the PRD's Decisions or, with no PRD, the issue's `## Decisions`, so a reviewer can still catch it.
- **Established facts** — each goes into the Decisions it supports, with its citation (`path:line`, doc or spec), so the implementer does not re-derive it.
- **The cut list** — each item, with why it was cut, goes to the PRD's Out of Scope or, with no PRD, the issue's `## Out of Scope`, so the implementer does not re-add it.

**An existing issue as the source.** `/to-issues <ref>` on an existing issue is how it moves from `needs-triage` to `ready-for-agent`: it goes through steps 2–5 like any plan. If it is still one slice after step 4, step 6 rewrites that issue in place; if it splits into several slices, each becomes a new child issue with `## Parent` naming it. An issue with a column-0 `Source:` line outside a code fence (`Source: review (<branch>)` or `Source: <report> (<branch>)`, anywhere in the body) was promoted from review findings already judged: it is not checked against the design standard.

Determine the **feature slug** (the root issue or directory the issues are filed under):

1. If the user provided a path argument, extract the slug from it (e.g. `.coding-crew/scratch/auth-flow/...` → `auth-flow`).
2. Otherwise, run `node "$TRACKER" features` — one `<slug>\t<open|closed>\t<ready-count>` line per feature — and check if one slug clearly matches the topic being discussed.
3. If no match is found, ask the user: "What feature slug should I use?"

Never guess the slug silently — confirm with the user if there's any ambiguity. **Before using a slug `features` lists, ask the user** whether to extend that feature or choose a new slug; a closed feature is still a taken slug. `to-prd` relies on this question and does not ask it again.

**One slice and at most one origin issue, no PRD:** the slug needs no question. Use, in order: a github issue ref's own `Feature: <slug>` line, when its body has one; a local issue ref's feature (`rewrite` writes in place); otherwise one derived from the title (kebab-case, short). Step 5's quiz shows it for the user to override. With two or more slices, or two or more origin issues, the slug is confirmed as above.

### 2. Check for a PRD

Run `node "$TRACKER" prd --feature-slug <feature-slug>`. Exit 0 prints the PRD: use it as the primary source material for decomposition, and save that output to `.coding-crew/scratch/<feature-slug>/.drafts/PRD.md` for step 6's builder check. Note the PRD's ref — step 6 cites it in each work issue: `#<n>` when the output opens with `<!-- PRD issue #<n>: … -->`, else `.coding-crew/scratch/<feature-slug>/PRD.md`. Exit 3 means there is none.

With no PRD, work from the conversation context; step 4's slice count decides whether one is needed, and step 4's last paragraph writes it. One slice publishes without a PRD (its issue carries its own `## Decisions`).

### 3. Explore the codebase

Not optional. If you have not already explored the code each slice will touch, do so now. Issue titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

**Ground every assumption.** An issue drafted from the PRD alone can name a function that does not exist or a bug already fixed, and the implementer reads the code only after the issue is written. For each thing a slice assumes about the *current* code — an existing module, function, schema or behavior, and for a bug the code path that produces it — confirm it at a `file:line`. Something the slice creates is new, and its issue says so ("adds …"). What exploration contradicts goes to the quiz below, never silently into an issue:

- **Already there** — the behavior exists, or the bug is already fixed: drop the slice, or keep it as a test-only slice if nothing pins the behavior.
- **Wrong assumption** — the PRD or plan assumes something the code rules out (a missing counterpart, a decision an ADR or the code contradicts): ask how to resolve it before drafting.
- **Fails the design standard** — the slice, or the existing issue it came from, fails a criterion of the standard below (no cited problem; one check standing in for two questions; a lookup for a fact already known earlier): name the criterion and its `file:line` evidence, and ask how to reshape it before drafting. An auto-promoted issue (a column-0 `Source:` line, step 1) is exempt.

<!-- fragment:design-standard -->
**Design standard.** Size is fine; **unjustified** size is not. Judge every decision and component against five criteria, in priority order — necessary > correct > reusable along real axes > fewest moving parts > says what it does — and when two conflict, the earlier one wins. Each criterion names the evidence that shows it failing; cite that evidence (`file:line`, a count, a quote) rather than a taste.

1. **Necessary** — it removes a measured, cited problem and nothing beyond it. Fails on: no cited problem; a need nobody has yet; completeness for its own sake.
2. **Correct** — it does what it claims against the real code, and its rationale holds. Fails on: a rationale the code contradicts; a mechanism that cannot reach its target case; an edge case (signal, retry, concurrent run, early return) that breaks it.
3. **Reusable along real axes** — a decision lives in one place, behind an abstraction, when it has two or more real callers or implementations now, or when it sits on one of the axes of variation the project's `CLAUDE.md` (or `AGENTS.md`) names; when that file names none, only two or more real callers or implementations now count. A good abstraction hides a decision, has an interface smaller than what it hides, and is named for what it does. It is never built for a caller or axis that does not exist yet. Fails on: the same decision coded in two or more places, or code that branches on which implementation it has; an abstraction with one implementation and no named axis, an unused parameter, or per-caller flags (generality for a hypothetical caller).
4. **Fewest moving parts** — no dependency, network call, state or format the problem does not need. Fails on: a lookup for a fact already known earlier; a dependency, service, cache or file format the problem never asked for.
5. **Says what it does** — names and text match behaviour, and a newcomer can state what it does in one sentence. Fails on: a name that contradicts what it does; one check standing in for two questions.

Simplicity never cuts structure the design needs now: one owner per concern, no duplicated logic, a seam its tests need, the project's layer rules. Well-architected is a justification, overengineered is not. Logic that would otherwise be copied into several places gets one shared owner: that is structure, not a speculative layer, and dropping it to avoid "abstraction" leaves the design under-built.
<!-- /fragment:design-standard -->

While exploring, look for **prefactoring opportunities** — changes that would make the feature implementation significantly easier. "Make the change easy, then make the easy change." Prefactoring is sequenced first (at the start of the slice, or as its own first slice when the work is split) so the feature work builds on a clean foundation.

Also note any **shared surfaces**: a schema/table, a shared type, or an existing function/module that more than one slice would need to modify. This is a narrower thing than "touches the same file": two slices adding code to separate parts of a file do not interact, while a shared surface is where two slices would plausibly change the *same specific behavior*. Carry any you find into step 4, and apply its edge rule to each one.

### 4. Draft vertical slices

An issue is one piece of work that one implementer takes, finishes and gets verified as a unit, and that stands on its own once landed. Shape the slices in three passes:

1. **Draft** them as the work divides on its own, without weighing size: each one a tracer bullet (below), HITL work apart from AFK work, and the steps of an expand–contract migration in their order (**Expand–contract sequencing** below).
2. **Split** a slice that is more than one implementer finishes as one issue, along its own seams. The **reference size** is what one implementer finishes and one reviewer checks as one issue. When the repo you run in has issues finished that way (the tracker's done list, and the change each landed as), their size is the reference; a repo without that history starts from about a dozen files and a few hundred written lines, the largest around 500, which is what one agent session holds while it implements and verifies. Count the lines a slice writes by hand; deletions, mechanical renames, fixtures and generated code cost little, so a slice that removes a thousand lines and writes a hundred is small. A slice around the reference is one issue; one that would write well past the largest is split.
3. **Merge** a slice that exists only to be smaller. For each pair of slices, name what keeping them apart buys. Only three things do: one side needs a person and the other does not (**human boundary**), one must land before the other as a migration step (**expand–contract order**), or together they would write well past the reference size (**size**). A size split shows its arithmetic: the merged pair's files and written lines next to the reference size; a pair whose merged total stays around the reference is one issue, whatever else separates it. Separate files, modules, concerns, behaviours or test seams buy nothing on their own, and are not size. A pair with no reason is merged now, not shown to the user as a choice; when none of the three holds, merge. A split is a pair of slices kept apart, never a property of one slice: every slice that survives names the neighbour it would otherwise merge into and which of the three keeps them apart. A slice with no such line is merged into that neighbour, and a slice well below the reference size is a merge candidate until one of the three keeps it apart. One slice may deliver several behaviours. Repeat until every remaining split names one of the three.

The breakdown shows only the slices that survived pass 3, each split with the reason it named.

Each issue is a **tracer bullet**: a vertical slice that cuts through every integration layer its behaviour needs end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and landed without human interaction. Prefer AFK over HITL where possible.

**Placement.** Every HITL slice is placed **first** or **last**, by what it is for; Kind A/B (step 6) says who does the work, placement says when:

- **first** — only when an agent cannot write or test the code without it: a credential the tests call with, a service the code talks to, a decision that changes the code's shape. The slices that need it are `Blocked by` it.
- **last** — everything a person does to what was built: a validation (a paid run, a measurement) or setting the values the code reads. No AFK slice is `Blocked by` a last slice; a last slice may itself be `Blocked by` the AFK slices it acts on (edge rule row 1). Its gate is the merge: the PR stays a draft while it is open, because the spec its reviewer reads holds every issue of the feature, open ones included. A value set only after the merge (a repo variable, deploy config) is no slice at all: the AFK slice's `## Decisions` name it and its default.
- **Values the code reads are not a prerequisite.** The AFK slice builds the code reading the value from a named place (a config key, an env var, a repo variable), and its `## Decisions` name that place and the default, or the error, when it is unset; the person's slice that sets the values is last.
- A PRD's "prove X before Y is advertised" (or shipped, or documented) means before the PR merges, never a `Blocked by` edge from Y to X: X is a last slice.

Number the drafts first HITL, then AFK, then last HITL, so a last slice's number comes after every AFK slice's.

**Edge rule.** Between slices that remain split, add `Blocked by` only when one of these rows matches:

1. One slice consumes what the other produces (a signature, shape or output) → `Blocked by`.
2. The two change the same meaning (the same behaviour, function or rule) → `Blocked by`.

Otherwise add no edge: edits to separate parts of a file do not interact, and a needless edge only constrains the order for nothing. Same-meaning edits are ordered so the later slice builds on what the earlier one settled instead of guessing at it. An edge can follow any of the three split reasons; only these rows decide it. One exception overrides them: an AFK slice is never `Blocked by` a last HITL slice (**Placement** above).

<vertical-slice-rules>
- Each behaviour a slice delivers is externally observable, verified at the highest existing seam (the outermost place a test can already exercise it: a CLI invocation, an HTTP call, a script's exit code and output). "Schema / API / UI" is only an example of the layers such a behaviour may cut through, not a required shape — a slice touches whichever layers its behaviours need
- When a slice's behaviour is prose (a skill, prompt or doc), its check is never a grep of the rendered output: its criteria are checkable from the diff, and its behaviour is judged by an eval where a harness exists
- If the work is split, the first slice is the thinnest end-to-end path: the narrowest behaviour that proves the layers connect. Later slices widen it
- A completed slice is demoable or verifiable on its own
- Each slice is one implementer's issue, judged against the reference size — passes 2 and 3 above are the only size rule
- A slice with more than 10 acceptance criteria is flagged for the user (step 5). Neither that nor any other rule in this list is on its own a reason to split
- Any prefactoring is sequenced first: at the start of the slice, or as the first slice when the work is split
</vertical-slice-rules>

**Wide refactor?** One mechanical change — rename a column, retype a shared symbol — whose blast radius fans across the whole codebase, so no vertical slice can land green on its own: read `<skill-dir>/references/expand-contract.md` before slicing it.

**Expand–contract sequencing** is drawn from the PRD's `## Compatibility & Migration` when it exists: each expand, migrate and contract step it names becomes a slice (or part of one) sequenced in that order, with the contract step blocked by every migrate step. Without that section, do not invent a migration sequence.

**PRD for a split.** After step 4, with two or more slices (or two or more origin issues named in the source) and no PRD from step 2, invoke `to-prd` with the feature slug (so its own slug question is never reached). Then save the PRD it wrote, `node "$TRACKER" prd --feature-slug <feature-slug>`, to `.coding-crew/scratch/<feature-slug>/.drafts/PRD.md`, so the builder check receives it, and note its ref as step 2 does. Then do step 4.5 against it. Origin issues count because only a PRD's `Origin:` line closes them.

### 4.5. Trace PRD IDs to slices

Before the quiz, build a coverage table: one row per `D<n>` / `B<n>` ID in the PRD (lines starting `- **D<n>** — …` / `- **B<n>** — …`), with the slice(s) that implement it. An ID no slice covers is an empty row, except one whose PRD line ends in `(no slice)`: the PRD says it needs none, so its row reads `(no slice)` and is not asked about in step 5. With no IDs in the PRD (or no PRD), the table is skipped entirely. Each slice's `## Implements` in step 6 must then name the IDs the table gave it.

### 5. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: AFK, HITL (first) or HITL (last)
- **Blocked by**: which other slices (if any) must complete first
- **What it delivers**: the end-to-end behaviour this slice makes work, from the user's perspective
- **Size**: the files it reads or edits and the lines you expect to write (deletions apart)
- **Apart from**: the neighbouring slice it would otherwise merge into, and which of pass 3's three reasons keeps them apart (size shows the merged pair's written lines against the reference)

Show the coverage table from step 4.5 (when there is one), then ask only what needs a decision. Walk these in order and omit any that is empty:

1. **Contradicted assumptions** — what the plan assumes, what the code shows at `file:line`, and the slice it affects; resolve each before the rest.
2. **Design-standard failures** — each slice that fails a criterion of the design standard (step 3): the criterion, its evidence at `file:line`, and the reshape you propose.
3. **The PRD's `## Assumptions`** — each one the slices lean on, for the user to confirm or correct. With no PRD, show instead the one slice's drafted acceptance criteria, its `## Decisions`, the assumptions you filled in beyond the source, and the slug: this is the single review on the light path.
4. **PRD IDs no slice covers** — the empty rows of the coverage table: add a slice, fold the ID into one, or confirm it is out of scope.
5. **Large slices** — each slice near the largest finished as one issue, or that carries more than 10 acceptance criteria, with its files and written lines, for the user to confirm it stays one issue. Neither is a reason to split.
6. **Splits and edges** — one line per pair kept apart, naming both slices and the reason from step 4's pass 3 (size — with the merged pair's files and written lines against the reference size; human boundary; expand–contract order), and one line per `Blocked by` edge naming the edge-rule row that produced it and its slices, for the user to override. A pair with no reason is not listed: go back to pass 3 and merge it. Don't ask whether an overlap needs an edge; the rule decided, the user overrides.
7. **HITL choices** — each slice marked HITL, why a human is needed (that reason becomes the block's `### Why a person`) and its placement, first or last, with the reason **Placement** gives; the rest are AFK.

Then one approve/adjust prompt: approve the breakdown as shown, or say what to adjust. Iterate until the user approves. Do not ask generic questions about granularity, blocking edges, combining slices or HITL/AFK — a breakdown with nothing to list above needs only the approve/adjust prompt.

A return from step 6 — a `publish-issues` refusal, or the builder check's questions marked yours — asks only those questions, in one message ranked by importance, then goes back to step 6 to re-render.

### 5.5. Cross-cutting rules from the PRD

Before writing issues, read the PRD's `## Decisions` and `## Testing Decisions` for a rule that binds more than one slice ("every endpoint must …", "all calls retry …"). Each slice carries such a rule in `## Cross-cutting Requirements` only when its own acceptance criteria do not already cover it; otherwise the criterion is the home and the section is omitted. There is no category list to scan.

### 6. Write the issues

Write each approved slice with the template below and the rules that follow it, then take it through `<skill-dir>/references/publish.md`, in this order: drafts in `.coding-crew/scratch/<feature-slug>/.drafts/` → the feature's known issues → `deps.json` → the builder check → `publish-issues` (or `rewrite`, for a source issue that stayed one slice). A `publish-issues` refusal or a builder-check question only the user can answer returns to step 5 with just that question.

**A `ready-for-human` issue opens with a `## For a human` block**, placed right after `## What to build`. A person reads it cold, so write plain language that needs neither the PRD nor the codebase. It has exactly five `###` parts, in this order:

1. `### Why a person` — why no agent can do this (a permission, a credential, a judgement call).
2. `### What changes` — what is true today and what will be true after, in concrete names and values.
3. `### Steps` — numbered. Each step says what to do, then a `Check:` line (how to see it worked) and an `Undo:` line (how to reverse it). Write `n/a — <why>` when a step has no check or no undo. Put commands and file contents in fenced blocks.
4. `### If skipped or done wrong` — what breaks, in the reader's terms.
5. `### Done when` — the observable end state.

Write acceptance criteria unticked (`- [ ]`): the person ticks each one as they finish it, so a box ticked at publish says "done" before anything was done.

**Kind A — the whole task is a person's.**

- Drop `## Implements`, `## Interfaces` and the "Read this document before implementing" line; no agent will read this issue.
- End `### Steps` with a fixed last step, "Mark it done", that reads: "Tell your coding agent: run the coding-crew tracker CLI (`coding-crew-lib/scripts/tracker/cli.mjs` in the folder the coding-crew skills are installed in) with `mark-done <n>`". On the local tracker, write the issue file path instead of `<n>`. Never write an absolute path: it does not exist on the reader's machine.
- That step's `Check:` is that the command exits 0 and prints no `REFUSED` line.
- Its `Undo:` is the same request with "Reopen an issue" from the tracker doc `docs/<kind>.md` beside that `cli.mjs`, `<kind>` being the `tracker=` value the same CLI's `config` prints.
- Name neither the tracker nor its labels or files in the step.

**Kind B — agent work blocked on a person.** Keep the agent brief (`## What to build`, `## Implements`, acceptance criteria, …) below the block, and make the last step of `### Steps` relabel the issue `ready-for-agent` by following "Reopen an issue" in that same tracker doc, with `ready-for-agent` as the status, so an agent run picks it up.

Trimmed example (Kind A):

````markdown
Status: ready-for-human

## What to build

Make the `main` branch ruleset require green test checks before a pull request merges.

## For a human

### Why a person

Only a repository admin can edit rulesets, and the change is made on GitHub itself. An agent has no admin token and must not have one.

### What changes

Today the ruleset has no `required_status_checks` rule, so a PR can merge while its tests are red. After this change it has one, listing the four test jobs.

### Steps

1. Save the current ruleset. Check: the file is not empty. Undo: n/a — this step only reads.

   ```bash
   gh api repos/OWNER/REPO/rulesets/ID > ruleset.backup.json
   ```

2. Apply the edited ruleset. Check: the command prints JSON with no `message` error. Undo: send `ruleset.backup.json` back with the same command.

   ```bash
   gh api -X PUT repos/OWNER/REPO/rulesets/ID --input ruleset.json
   ```

3. Mark it done, once every acceptance criterion below is ticked. Tell your coding agent: run the coding-crew tracker CLI (`coding-crew-lib/scripts/tracker/cli.mjs` in the folder the coding-crew skills are installed in) with `mark-done 42`. Check: the command exits 0 and prints no `REFUSED` line. Undo: tell your coding agent to follow "Reopen an issue" in the tracker doc `docs/<kind>.md` beside that `cli.mjs`, `<kind>` being the `tracker=` value the CLI's `config` prints.

### If skipped or done wrong

If skipped, a PR can merge with red tests. If `ruleset.json` leaves out an existing rule, that rule is silently removed.

### Done when

Reading the ruleset back lists `required_status_checks`, and a PR with a failing check cannot be merged.

## Acceptance criteria

- [ ] The ruleset has a `required_status_checks` rule
````

**Acceptance criteria describe this slice's behaviour, not repo-wide hygiene.** A rule every change must follow that a check already enforces — a version bump, a changelog entry, lint — is not a criterion: the check holds it, and as a per-issue criterion each issue on the branch repeats it (a second version bump, a duplicate changelog entry).

A criterion that needs a paid run, a manual measurement or a person is not an acceptance criterion: nobody working unattended can meet it, so it stays unmet and the issue never lands. It goes to a `ready-for-human` issue (its `### Steps` say what the person does), or, when no issue owns it, to the PRD's Further Notes.

**Acceptance-criteria rubric.** Whoever reviews the result gates on these, so each criterion is:

- one observable behaviour or consumed contract (a signature, shape or output another issue relies on), checkable from the diff plus the checks — never "tests pass";
- for a negative ("never writes outside X"), accompanied by the mechanism that prevents it — a negative with no named mechanism cannot be checked, so the criterion names the mechanism that prevents it;
- free of internal design choices, which stay in the PRD's Decisions (or the issue's own `## Decisions` when there is no PRD) where the reviewer judges them as findings — unless the choice is itself the requirement (e.g. "one batched call" as a performance bound).

A slice that takes input or calls something external must carry failure-behaviour criteria: invalid input, missing dependency, failing call — what the caller observes in each. This is how the PRD's `## Trust Boundaries & Risks` reaches the gated criteria.

A slice that adds a parser, validator or gate for an input the repo already holds examples of (issue files, configs, fixtures, stored records) carries one criterion that it accepts them, so the new code is tested against what people actually wrote, not only against inputs written from the PRD. Find the examples now and name them in the criterion, to be copied into committed test fixtures — never read from a live or gitignored directory, whose contents differ per machine and are absent in CI. For example: `- [ ] publish-issues succeeds on drafts copied from .coding-crew/scratch/add-tests/issues/`. The repo holds no such examples (a new format) → no such criterion. The PRD's `## Compatibility & Migration` names them when it exists.

<issue-template>
# <title>

Status: ready-for-agent

## Context Documents

> **Optional — only include this section if a PRD exists for this feature. Omit entirely if no PRD exists.**

- PRD: <the PRD's ref from step 2 — `#<n>`, or `.coding-crew/scratch/<feature-slug>/PRD.md`>

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

## Blocked by

- The blocking draft's filename, or an existing issue's `known` filename (if any)

Or "None - can start immediately" if no blockers.

## Interfaces

> **Optional — only include this section if this issue consumes from or is consumed by another issue. Omit entirely otherwise.**

### Consumes:

Exact signatures, types, or contracts expected from the blocking issues listed above. Be precise enough that whoever implements a blocker knows what shape to expose. Omit when this issue consumes nothing.

### Exposes:

Exact signatures, types, or contracts this issue produces for any downstream issues that depend on it. A root issue (no blockers) that another issue consumes from has `### Exposes:`.

</issue-template>

**Security**: Only read from and write to paths under `.coding-crew/scratch/` within the current repo, and reach the tracker only through the tracker CLI's ops, which act on the tracker `config.json` configures. Never fetch from arbitrary external URLs, an unconfigured remote API, or paths outside the repository root.
