# Step 6: from approved slices to published issues

Read this when step 5's quiz has approved the breakdown. Every command runs from the project root (from a folder that is no git repo, `cd <repo> &&` first); `$TRACKER` is the tracker CLI path the Tracker Configuration section gives. With more than one repo, read **More than one repo** at the end first: it runs each section below per repo.

## Drafts

Render every approved slice as a draft in `.coding-crew/scratch/<feature-slug>/.drafts/` — the same files whatever the tracker is: `NN-<slug>.md`, numbered from `01` in dependency order (blockers first), opening with a `# <title>` line and a `Status:` line (`Status: ready-for-agent` unless the user specifies otherwise), then the issue body template from SKILL.md. `## Blocked by` names another draft by its filename, or an issue that already exists by the filename `known` gives it (below). The CLI turns each draft filename into the ref its issue is created under.

Number the drafts working the **frontier**: any issue whose blockers are all done. For a linear chain that means top-to-bottom; for a DAG with multiple independent roots, number all currently unblocked issues before their dependents. Last HITL slices take the highest numbers, even when unblocked from the start (SKILL.md **Placement**).

## Known issues

Write the feature's existing issues beside the drafts:

```bash
node "$TRACKER" known --feature-slug <feature-slug> --out .coding-crew/scratch/<feature-slug>/.drafts/known
```

One file per issue already in the feature, named by the ref a `## Blocked by` entry uses for it.

## Dependency map

Write `.coding-crew/scratch/<feature-slug>/.drafts/deps.json` with the drafts — a flat map from each draft's filename to the filenames of the drafts blocking it, e.g.:

```json
{
  "01-first.md": [],
  "02-second.md": ["01-first.md"],
  "03-third.md": ["01-first.md", "02-second.md"]
}
```

Source it from the same blocking edges the user confirmed in the quiz — do not re-derive it from the `## Blocked by` prose. `publish-issues` creates the issues in this map's order and records the same edges, under the issues' final refs, where the dispatcher's `next` reads them to decide whether an issue is ready. Include every draft, even ones with no blockers (`[]`); an edge to an issue that already exists lives only in the draft's `## Blocked by`.

## Refusals

`publish-issues` refuses an unknown blocker, a cycle, or drift between `deps.json` and `## Blocked by`, and its stderr names the draft; return to step 5 with that message.

## Builder check

Before publishing, a fresh subagent reads the drafts cold, the way their implementer will: the writer fills omissions from memory, and that is the blind spot this check exists for. Skip it when every draft carries a column-0 `Source:` line (findings already judged, step 1). When the session has no subagent tool, print `builder check skipped: no subagent tool` and publish: never read the drafts yourself in its place.

Give the subagent only the paths of the drafts, `.coding-crew/scratch/<feature-slug>/.drafts/PRD.md` and `known/` when they exist, and read access to the repo (with more than one repo: every repo's drafts directory, and read access to every named repo, so it can catch a contract the two sides state differently). Never give it the conversation, a design summary or the quiz answers. Its prompt:

```text
You are the engineer who will implement these issues. You can read the repo but cannot talk to whoever wrote them. Read each draft in <drafts dir> and <PRD path> if one exists; known/ holds the feature's existing issues. Your job is the omissions and ambiguities you would have to guess at: report only the questions where a wrong guess changes what you build or how a criterion is checked. For each one, give the draft, the question, and why the answer matters. A contradiction between two drafts, or between a draft and the code, is a question like any other. Rank them by importance. Skip anything a draft leaves to the implementer, anything you could reasonably decide, and wording. If nothing important is left, say "nothing important left".
```

Sort each question it returns into one of three piles, once:

- **Answered** — the conversation or the code settles it: write the answer into the draft.
- **Minor** — a sensible implementer could settle it without changing what gets built: settle it and record one `(auto)` line as the last line of the draft's `## What to build`.
- **Yours** — only the user can answer it, and it changes what gets built: return to step 5, which asks only these, in one message ranked by importance, then re-render and publish. On a non-interactive run they go back to the caller as open questions, and nothing is published.

Print `builder check: N answered, M (auto), K asked`. One round: dispatch no second check after the answers.

## Publish

```bash
node "$TRACKER" publish-issues --feature-slug <feature-slug> --drafts .coding-crew/scratch/<feature-slug>/.drafts
```

It creates the issues in dependency order and prints one `<draft> <ref>` line per issue; the drafts directory (`known/` and `PRD.md` included) is deleted after a full publish. Finish by telling the user the feature slug, the PRD's ref when one was written, and those `<draft> <ref>` lines, with each `ready-for-human` issue marked as one a person must act on: the slug is what every later step takes. Two exits are questions for the user (for the caller, on a non-interactive run: never re-run with `--replace` then), and both write nothing:

- **Exit 4** — the feature has completed issues: stop, and tell the user: "Some issues are already completed. Please reconcile manually (delete or archive the old issues directory) before re-running."
- **Exit 5** — the feature already has open issues, which publishing would overwrite (stderr lists them): show them, warn they will be overwritten, and ask for confirmation. On yes, re-run the same command with `--replace`; on no, stop.

Exit 1 before anything is created is a refusal above, or (with `--replace`) a draft blocked by an open issue `--replace` would delete: fix that draft's `## Blocked by` and `deps.json`, and re-publish. On any other exit 1 the stderr names the issues created before the failure, and the drafts stay in place: report both, fix the cause, and ask the user before re-running — a re-run creates every draft again.

## A source issue that stayed one slice

It is rewritten in place instead of published (no `## Parent`): write it as a draft (title, `Status:` line and body, as above) to a file outside `.drafts/` and run

```bash
node "$TRACKER" rewrite <ref> --body-file <file> --status <status> --feature-slug <feature-slug>
```

where `<status>` is the slice's status (`ready-for-agent`, or `ready-for-human`). Pass the status: it is what dispatch picks an issue by, so a body-only rewrite would leave it `needs-triage`; `rewrite` also files the issue under the feature. Keep the source's title and its column-0 `Source:` line as `fetch` printed them, so the rewritten issue stays exempt from the design standard (step 1). A source that split into several slices keeps it open and gets one child issue per slice, each with `## Parent`.

Do NOT close or modify any parent issue. A single-slice source rewritten in place is not a parent: it gets only this `rewrite` — its body and its status.

## More than one repo

Each slice is published into the tracker of the repo it changes, under the same feature slug in every repo. In this order:

1. **In every repo, from that repo's root** (`cd <checkout> && …`): `node "$TRACKER" config` — step 1 configured every repo before its slug check, so it prints `configured=yes`; on `configured=no` on an interactive run, invoke `configure-tracker` after `cd <checkout>`, so the repo's issues do not silently land in a `local` tracker; then that repo's drafts, `known/` and `deps.json` under its own `.coding-crew/scratch/<feature-slug>/.drafts/`, holding only its own slices, numbered from `01`. The home repo's `.drafts/` also holds `PRD.md`.
2. **One builder check** over every repo's drafts (above), not one per repo.
3. **`publish-issues` in each repo**, from its root, home repo first, then in the build order the cross-repo prerequisites give (the order each `## What to build` names).

When a repo's `publish-issues` refuses or fails after an earlier repo published, fix and re-publish only that repo, as **Refusals** and **Publish** say; never re-run a repo already published, and tell the user which repos are published and which is not. The finish message lists the repos in build order, each with its `<draft> <ref>` lines.
