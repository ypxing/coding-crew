# Issue tracker: GitHub Issues

Issues, PRDs, and features live as GitHub Issues and Milestones. Requires the `gh` CLI,
authenticated (`gh auth status`), on every machine that runs a tracker-touching skill or script.

## Tracker config (optional front matter)

This file opens with YAML front matter declaring which tracker backend the whole pipeline
should use, and (optionally) which repo to target:

```yaml
---
tracker: github         # or "local"
repo: owner/name        # optional override — omit to let `gh` infer it from the git remote
---
```

`configure-tracker` writes this block when you choose `github`. `orchestrator/lib/
tracker-config.mjs`'s `readTrackerConfig(mainRoot)` and `scripts/tracker/tracker-config.sh`'s
`read_tracker_config` are the two readers of this front matter. `repo` is a pure override: `gh`
already infers the repo from the current directory's git remote when `--repo` is omitted, so
leave it out unless issues are tracked in a different repo than the code.

## Operation: list

Find all open issues ready for an agent, scoped to the feature's milestone, in one call
(never a ref-per-issue fetch):

```bash
gh issue list [--repo owner/name] --milestone <feature-slug> --state all \
  --json number,title,body,labels,state --label ready-for-agent
```

`--state all` is deliberate even for "list ready issues": blocker resolution needs to know
whether a referenced issue is already closed, not just which issues are open.

## Operation: fetch

Read one issue by number. The caller normally already has the number from `list`:

```bash
gh issue view <number> [--repo owner/name] --json number,title,body,labels,state
```

## Operation: publish

Create a new issue or PRD issue, both scoped to the feature's milestone (created lazily, on
first write, if it doesn't already exist):

```bash
# Milestone, created only if a list-first check shows it's missing (idempotent):
gh api repos/{owner}/{repo}/milestones -f title=<feature-slug>

# PRD — identified by title convention plus milestone scope, not a label:
gh issue create [--repo owner/name] --title "PRD: <feature title>" \
  --body-file <prd-file> --milestone <feature-slug>
# Best-effort pin — GitHub caps pinned issues at 3/repo, so a pin failure must not fail publish:
gh issue pin <number> [--repo owner/name] || true

# Work issue — the body file must itself contain the same `## Blocked by`/`Source:` prose
# local issues use; that prose is the dependency graph for this backend (no sidecar file):
gh issue create [--repo owner/name] --title "<title>" --body-file <body-file> \
  --label <status> --milestone <feature-slug>
# Then mirror its `## Blocked by` as native GitHub dependencies (best-effort; never fails publish):
node "$(git rev-parse --show-toplevel)/.coding-crew/crew-afk/lib/trackers/github.mjs" link-blockers --issue <number-just-created> [--main-root <dir>]
```

After each `gh issue create` of a work issue, to-issues runs `link-blockers` with the new issue's
number. It creates one native `blocked_by` relationship per `## Blocked by` number; a failed link
warns on stderr. Dispatch still reads only the body's `## Blocked by`.

Revising the PRD in place: `gh issue edit <n> --body-file <prd-file>`. Work issues cite the PRD
as `PRD: #<n>` in their body.

## Operation: mark-done

`done` means implemented and merged into the feature branch, not shipped. Delegate to the
tracker's script — do not hand-run `gh issue edit` or `gh issue close`:

```bash
MD="$(git rev-parse --show-toplevel)/.coding-crew/scripts/mark-issue-done.sh"
[ -f "$MD" ] || MD="$HOME/.coding-crew/scripts/mark-issue-done.sh"   # user-level install
bash "$MD" <number>
```

Before calling it, verify every `- [ ]` in `## Acceptance criteria` (and `## Cross-cutting
Requirements`, if present) against the implemented code and check off the ones it satisfies. The
script re-fetches the body live and refuses with exit `4` while one is unchecked, or exit `3`
when an orchestrator owns the close — report your status and stop in either case.

On success it swaps `ready-for-agent` for `awaiting-merge` (creating that label if the repo
lacks it) and leaves the issue **open**. Put `Closes #<number>` in the body of the PR that
carries the work: GitHub closes the issue when that PR merges into the default branch. With
`afk.openPr: true` (or `--open-pr`) crew-afk pushes the feature branch and opens or updates that
PR itself, writing these lines for every `awaiting-merge` issue in the milestone; without it,
the end-of-sprint summary prints them for you to paste. (A PR into any other branch does not
trigger the keyword — close those by hand.)

## Operation: status-update

Non-terminal statuses swap the label:

```bash
gh issue edit <number> [--repo owner/name] --add-label <new-status> --remove-label <old-status>
```

`done` is the `mark-done` label swap above (`awaiting-merge`, issue left open for the PR to
close). `wontfix` closes the issue with a reason instead of setting a label:

```bash
gh issue close <number> [--repo owner/name] --reason not-planned   # wontfix
```

## Labels

The agents speak in terms of six canonical triage labels. Five are real GitHub labels; `wontfix`
maps to a close-reason.

| Canonical label   | GitHub representation                                    | Meaning                                  |
| ----------------- | --------------------------------------------------------- | ----------------------------------------- |
| `needs-triage`    | label `needs-triage`                                       | Maintainer needs to evaluate this issue   |
| `needs-info`      | label `needs-info`                                         | Waiting on reporter for more information  |
| `ready-for-agent` | label `ready-for-agent`                                     | Fully specified, ready for an AFK agent   |
| `ready-for-human` | label `ready-for-human`                                     | Requires human implementation             |
| `done`            | label `awaiting-merge` while open; closed (`completed`) once its PR merges | Implemented; shipped once closed |
| `wontfix`         | close-reason `not-planned` (`gh issue close --reason not-planned`) — **not a label** | Will not be actioned |

`done` has two representations on purpose: "merged into the feature branch" and "shipped" are
different facts, and only a PR merge establishes the second. Closing at the first would show
issues as completed on GitHub while their code exists only in a local branch. Both read as
`done` for dispatch and for `## Blocked by` resolution. `configure-tracker`'s github setup
idempotently creates the real labels (including `blocked` and `in-progress`) before first publish, since `gh issue create --label x`
fails outright if `x` isn't already a repo label; `mark-done` also creates `awaiting-merge` and
`in-progress` on demand, for repos configured before they existed.

## In-progress issues

While a crew-afk run works an issue it carries the `in-progress` label, so a human on GitHub can
see it. It is **display only**: the feature lease, not this label, decides what is dispatched, and
a human adding or removing it changes nothing. The run adds it when it claims the issue (before the
worker is dispatched) and removes it when the issue merges — in the same `gh issue edit` that adds
`awaiting-merge` (`mark-done` does this; running it by hand on an issue without the label still
succeeds) — or is blocked (swapped for `blocked`). An issue the run still holds at its end
(partial, `--max-rounds` cap, stall) is released before the summary. A `## Requires` failure is
never labelled. The new holder of a feature's lease also removes `in-progress` from every issue in
the milestone right after acquiring it: only a dead run can have left one. A failed label write only
warns.

## Blocked issues

When crew-afk stops on an issue that needs a human (retry limit, cost limit, not fixable, an
environment criterion, a dirty main tree, a review that did not run), it posts a `## Blocked`
comment and adds the `blocked` label **next to** `ready-for-agent` (creating the label if the
repo lacks it). Every later run skips an issue labelled `blocked`, and issues whose
`## Blocked by` names it keep waiting — `blocked` is not `done`. A failed label write only warns.
A failed `## Requires` probe is not labelled; it is re-probed every run.

To put a blocked issue back in the queue, once its cause is fixed:

```bash
gh issue edit <number> [--repo owner/name] --remove-label blocked
```

The sprint summary prints that command for each issue blocked in the run.

## Workspace

A feature maps to a GitHub **Milestone** named for the feature slug. The feature's PRD is an
issue inside that milestone, identified by title convention (`PRD: <feature title>`), not a
local file. Work issues are regular issues in the same milestone, using the same markdown body
conventions as local issues (`## Blocked by`, `## Acceptance criteria`, `## Requires`, `Source:`).
`## Requires` is one backticked shell command per bullet, exit 0 = satisfied, naming what the
issue's checks need that the install does not guarantee; crew-afk runs each once, from the
project root, before the issue's first dispatch, and a failing one blocks the issue.

No filename exists to derive a slug or branch from, so both are derived deterministically from
the issue every time: kebab-case the title for the slug, and include the issue number in the
branch name for uniqueness: `crew/<featureSlug>/<number>-<slug>`. Nothing to cache — GitHub
issue numbers are stable, unambiguous identifiers, unlike local filenames.

Comments and conversation history append to the issue as ordinary `gh issue comment` timeline
entries — a live activity feed, not an in-place-edited section like local's `## Comments`.
