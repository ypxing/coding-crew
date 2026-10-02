---
name: to-issues
description: Break a plan, spec, or PRD into independently-grabbable issues on the project issue tracker using tracer-bullet vertical slices. Use when user wants to convert a plan into issues, create implementation tickets, or break down work into issues.
---

# To Issues

Break a plan into independently-grabbable issues using vertical slices (tracer bullets).

{{FRAGMENT:tracker-configuration}}

## Process

### 1. Gather context and determine feature slug

Work from whatever is already in the conversation context. If the user passes an issue reference as an argument, it must be a local file path (e.g. `.scratch/feature/issues/01-slug.md`) or an issue number within `.scratch/` — or, under a configured `github` tracker, an issue number resolved via that tracker's `fetch` operation. Do NOT fetch from arbitrary user-supplied URLs or an unconfigured remote tracker; reads and writes through the *configured* tracker's own operations (as defined in `issue-tracker.md`) are permitted.

When the plan references an issue, read its full body and its comments, not just the title: under `github`, run `gh issue view <n> --comments` (the `fetch` operation returns no comments); under `local`, read the file.

Determine the **feature slug** (the directory name under `.scratch/`):

1. If the user provided a path argument, extract the slug from it (e.g. `.scratch/auth-flow/...` → `auth-flow`).
2. Otherwise, list existing directories under `.scratch/` and check if one clearly matches the topic being discussed.
3. If no match is found, ask the user: "What feature slug should I use? (This becomes the `.scratch/<slug>/` directory name.)"

Never guess the slug silently — confirm with the user if there's any ambiguity.

### 2. Check for a PRD

Under a `local` tracker, check whether a PRD exists at `.scratch/<feature-slug>/PRD.md`. If one exists, read it and use it as the primary source material for decomposition. Under a configured `github` tracker, check instead (via that tracker's `list`/`fetch` operations) whether a `PRD: <feature title>` issue already exists in the feature's milestone; if so, fetch and read its body the same way. Either way, note the PRD's number/path — step 6 cites it in each work issue.

If no PRD exists, ask the user:

> "I don't see a PRD for this feature. Would you like me to run `/to-prd` first to formalize the spec, or should I work from the current conversation context?"

If the user chooses to run `/to-prd`, invoke it (using the same feature slug), then continue with the resulting PRD. If the user declines, proceed with conversation context as before.


### 3. Explore the codebase

Not optional. If you have not already explored the code each slice will touch, do so now. Issue titles and descriptions should use the project's domain glossary vocabulary, and respect ADRs in the area you're touching.

**Ground every assumption.** An issue drafted from the PRD alone can name a function that does not exist or a bug already fixed, and the coder reads the code only after the issue is written. For each thing a slice assumes about the *current* code — an existing module, function, schema or behavior, and for a bug the code path that produces it — confirm it at a `file:line`. Something the slice creates is new, and its issue says so ("adds …"). What exploration contradicts goes to the quiz below, never silently into an issue:

- **Already there** — the behavior exists, or the bug is already fixed: drop the slice, or keep it as a test-only slice if nothing pins the behavior.
- **Wrong assumption** — the PRD or plan assumes something the code rules out (a missing counterpart, a decision an ADR or the code contradicts): ask how to resolve it before drafting.

While exploring, look for **prefactoring opportunities** — changes that would make the feature implementation significantly easier. "Make the change easy, then make the easy change." Prefactoring issues must be sliced and sequenced first so downstream feature issues can build on a clean foundation.

Also note any **shared surfaces**: a schema/table, a shared type, or an existing function/module that more than one slice would need to modify. This is a narrower thing than "touches the same file" — two slices adding independent, non-overlapping code to the same file is the normal shape of vertical slicing and merges cleanly; a shared surface is where two slices would plausibly change the *same specific behavior*. Carry any you find into the quiz step below; don't turn them into blocking edges yourself — whether a shared surface needs sequencing or is safe to leave parallel is a judgment call for the quiz, not something to guess silently here.

### 4. Draft vertical slices

Break the plan into **tracer bullet** issues. Each issue is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- A slice is one externally observable behaviour, verified at the highest existing seam (the outermost place a test can already exercise it: a CLI invocation, an HTTP call, a rendered output, a bats run). "Schema / API / UI" is only an example of the layers such a behaviour may cut through, not a required shape — a slice touches whichever layers its behaviour needs
- The first slice is the thinnest end-to-end path: the narrowest behaviour that proves the layers connect. Later slices widen it
- A completed slice is demoable or verifiable on its own
- Each slice is sized to fit in a single fresh context window — if a slice requires multiple agent sessions it must be split further
- Merge rule: merge two slices when they share a test seam and neither is reviewable or demoable alone. Do not split below that floor — a fragment nobody can review or demo on its own is not a slice
- Aim for 3–8 acceptance criteria per slice (a soft target, not a gate): fewer usually means a fragment to merge, more usually means two behaviours to split
- Any prefactoring should be sequenced first
</vertical-slice-rules>

**Wide refactor?** One mechanical change — rename a column, retype a shared symbol — whose blast radius fans across the whole codebase, so no vertical slice can land green on its own: read `references/expand-contract.md` before slicing it.

**Expand–contract sequencing** is drawn from the PRD's `## Compatibility & Migration` when it exists: each expand, migrate and contract step it names becomes a slice (or part of one) sequenced in that order, with the contract step blocked by every migrate step. Without that section, do not invent a migration sequence.

### 4.5. Trace PRD IDs to slices

Before the quiz, build a coverage table: one row per `D<n>` / `B<n>` ID in the PRD (lines starting `- **D<n>** — …` / `- **B<n>** — …`), with the slice(s) that implement it. An ID no slice covers is an empty row. With no IDs in the PRD (or no PRD), the table is skipped entirely. Each slice's `## Implements` in step 6 must then name the IDs the table gave it.

### 5. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **What it delivers**: the end-to-end behaviour this slice makes work, from the user's perspective

Show the coverage table from step 4.5 (when there is one), then ask only what needs a decision. Walk these in order and omit any that is empty:

1. **Contradicted assumptions** — what the plan assumes, what the code shows at `file:line`, and the slice it affects; resolve each before the rest.
2. **The PRD's `## Assumptions`** — each one the slices lean on, for the user to confirm or correct.
3. **PRD IDs no slice covers** — the empty rows of the coverage table: add a slice, fold the ID into one, or confirm it is out of scope.
4. **Slices outside the criteria range** — any slice that would carry fewer than 3 or more than 8 acceptance criteria: merge it, split it, or keep it as is.
5. **Shared surfaces** — one line per surface from step 3, naming the slices that touch it: is the overlap additive (safe to leave parallel), or does it need a `Blocked by` edge (or a merge)? Don't add the edge yourself; this is exactly the call a file-overlap heuristic gets wrong, because it can't tell "two slices editing the same file in unrelated ways" from "two slices that will conflict."
6. **HITL choices** — each slice marked HITL, and why a human is needed (that reason becomes the block's `### Why a person`); the rest are AFK.

Then one approve/adjust prompt: approve the breakdown as shown, or say what to adjust. Iterate until the user approves. Do not ask generic questions about granularity, blocking edges, merging or HITL/AFK — a breakdown with nothing to list above needs only the approve/adjust prompt.

### 5.5. Cross-cutting rules from the PRD

Before writing issues, read the PRD's `## Decisions` and `## Testing Decisions` for a rule that binds more than one slice ("every endpoint must …", "all calls retry …"). Each slice carries such a rule in `## Cross-cutting Requirements` only when its own acceptance criteria do not already cover it; otherwise the criterion is the home and the section is omitted. There is no category list to scan.

### 6. Write the issues

**Local tracker, issues directory non-empty?** If `.scratch/<feature-slug>/issues/` already contains issue files, read `references/rerun.md` before writing anything. Otherwise proceed.

**Lint before any `publish`.** Render every issue body (the template below) first — under `local`, write them to their final `.scratch/<feature-slug>/issues/` paths; under `github`, write them as files under `.scratch/<feature-slug>/.lint/` and delete that directory afterwards — and run, from the project root:

```bash
bash <skill-dir>/scripts/lint-issues.sh --issue <body-file> [--issue <body-file> …] \
  [--deps .scratch/<feature-slug>/issues/issues-deps.json] [--prd <PRD file>]
```

Add `--deps` under `local` only (write the step 7 map first, so the linter can compare it with the `## Blocked by` prose), and `--prd` only when a PRD exists (a local path; under `github` save the PRD body to a file under `.scratch/<feature-slug>/.lint/` first). Exit 1 means publish nothing: show the `ERROR` lines; the skill returns to the quiz (step 5) to fix them, then render and lint again. Exit 0 prints at most `WARN` lines: show them and continue — publishing continues. Exit 2 is a usage error in how you called it: fix the call.

**Under `github`** the blockers' issue numbers do not exist until `publish`, so for the lint run name each body file `<n>-<slug>.md` and write its `## Blocked by` refs as `Issue #<n>`, numbering the new slices from one past the repo's highest issue number (`gh issue list --state all --limit 1 --json number`); pass each issue already in the milestone that a new slice is blocked by as `--known <number>-<slug>.md` (a name only — never opened or linted). At `publish`, replace each `Issue #<n>` with the number `gh issue create` returned for that slice — the only edit after the lint.

For each approved slice, execute the `publish` operation from `issue-tracker.md` to create a new issue file. Use the issue body template below. Add `Status: ready-for-agent` unless the user specifies otherwise.

**`## Requires`.** When a slice's checks need a service, a credential or a tool the project's install does not guarantee (a LocalStack container, an auth token, a CLI), write one backticked shell command per requirement — exit 0 means satisfied; it runs on the host from the project root, before any coder is dispatched, and may start the service it checks. Run each one while authoring. If one fails, publish the issue as `Status: ready-for-human` instead of `ready-for-agent`, because no coder can supply what it lacks: the failing command and its output go in `### Why a person`, and the fix goes in `### Steps`. A command that can only hold once one of the issue's blockers lands (a Makefile target that blocker adds) is not run now — crew-afk probes it when the issue unblocks.

**`ready-for-human` bodies.** Every slice published as `ready-for-human` (a HITL slice from step 5, or a failing `## Requires`) opens with this block:

{{FRAGMENT:human-issue}}

**Acceptance criteria describe this slice's behaviour, not repo-wide hygiene.** A rule every change must follow that a check already enforces — a version bump, a changelog entry, lint — is not a criterion: the verify gate holds it, and as a per-issue criterion two parallel issues satisfy it with the same edit, which then merges away on one of them.

**Acceptance-criteria rubric.** The reviewer gates on these, so each criterion is:

- one observable behaviour or consumed contract (a signature, shape or output another issue relies on), checkable from the diff plus the checks — never "tests pass";
- for a negative ("never writes outside X"), accompanied by the mechanism that prevents it — a negative with no named mechanism cannot be checked, so the criterion names the mechanism that prevents it;
- free of internal design choices, which stay in the PRD's Decisions where the reviewer judges them as findings — unless the choice is itself the requirement (e.g. "one batched call" as a performance bound).

A slice that takes input or calls something external must carry failure-behaviour criteria: invalid input, missing dependency, failing call — what the caller observes in each. This is how the PRD's `## Trust Boundaries & Risks` reaches the gated criteria.

A slice that adds a parser, validator or gate for an input the repo already holds examples of (issue files, configs, fixtures, stored records) carries one criterion that it accepts them, so the new code is tested against what people actually wrote, not only against inputs written from the PRD. Find the examples now and name them in the criterion, to be copied into committed test fixtures — never read from a live or gitignored directory, whose contents differ per machine and are absent in CI. For example: `- [ ] lint-issues.sh exits 0 on fixtures copied from .scratch/add-tests/issues/`. The repo holds no such examples (a new format) → no such criterion. The PRD's `## Compatibility & Migration` names them when it exists.

Write issues in dependency order (blockers first) so you can reference earlier issue numbers in the "Blocked by" field. Work the **frontier**: any issue whose blockers are all done. For a linear chain that means top-to-bottom; for a DAG with multiple independent roots, publish all currently unblocked issues before their dependents.

**Tracker is `github`?** Read `references/github-publish.md` for how `publish` creates the issues, writes `## Blocked by` and cites the PRD; the local-only re-run handling does not apply.

<issue-template>
Status: ready-for-agent

## Context Documents

> **Optional — only include this section if a PRD exists for this feature. Omit entirely if no PRD exists.**

- PRD: `.scratch/<feature-slug>/PRD.md` (local tracker; the github form is in `references/github-publish.md`)

Read this document before implementing. It contains architecture decisions, integration constraints, and technical context essential for this issue.

## Parent

A reference to the parent issue on the issue tracker (if the source was an existing issue, otherwise omit this section).

## What to build

A concise description of this vertical slice: the end-to-end behavior, not layer-by-layer implementation. Its first sentence is a one-line summary (`squash-commits.sh:109` takes the commit title from it).

This section may cite grounded paths and signatures (confirmed in step 3). If a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it here and note briefly that it came from a prototype. Trim to the decision-rich parts — not the working demo, just the important bits.

## Implements

The PRD IDs this issue carries (e.g. `D3, B2`), plus the seam it is verified at (the highest existing test seam that exercises it).

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

- A reference to the blocking ticket (if any) — the blocker's filename under `local` (the github form is in `references/github-publish.md`)

Or "None - can start immediately" if no blockers.

## Interfaces

> **Optional — only include this section if this issue consumes from or is consumed by another issue. Omit entirely otherwise.**

### Consumes:

Exact signatures, types, or contracts expected from the blocking issues listed above. Be precise enough that a parallel agent implementing a blocker knows what shape to expose. Omit when this issue consumes nothing.

### Exposes:

Exact signatures, types, or contracts this issue produces for any downstream issues that depend on it. A root issue (no blockers) that another issue consumes from has `### Exposes:`.

</issue-template>

### 7. Write the machine-readable dependency map

**Local tracker only** — a `github`-tracked feature has no sidecar to write: a github issue number is already the blocker's ref, resolved directly from the numbers step 6's `## Blocked by` prose cites, so this step is skipped entirely under that backend.

Write `.scratch/<feature-slug>/issues/issues-deps.json` before the step 6 lint run (the linter's `--deps` compares it with the `## Blocked by` prose) — a flat map from each issue's filename to the filenames of its blockers, e.g.:

```json
{
  "01-first.md": [],
  "02-second.md": ["01-first.md"],
  "03-third.md": ["01-first.md", "02-second.md"]
}
```

Source it from the same blocking edges the user confirmed in the quiz step — do not re-derive it from the `## Blocked by` prose. This file, not the prose, is what the orchestrator uses to decide whether an issue is ready to dispatch; the `## Blocked by` section stays in each issue purely for a human reading that file. Include every issue you are about to publish, even ones with no blockers (`[]`), so the map is authoritative for the whole feature rather than partial.

Do NOT close or modify any parent issue.

**Security**: Only read from and write to paths under `.scratch/` within the current repo, or — under a configured `github` tracker — through that tracker's own defined operations (`gh issue`/`gh api` calls per `issue-tracker.md`). Never fetch from arbitrary external URLs, an unconfigured remote API, or paths outside the repository root, and never target a github repo other than the one `issue-tracker.md` configures.
