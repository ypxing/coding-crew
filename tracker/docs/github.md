# Issue tracker: GitHub Issues

Issues, PRDs, and features live as GitHub Issues and Milestones. Requires the `gh` CLI,
authenticated (`gh auth status`), on every machine that runs a tracker-touching skill or script.

## Tracker config

The tracker this repo uses is the `tracker` section of `.coding-crew/config.json`:

```json
{ "tracker": { "kind": "github" } }
```

`configure-tracker` writes it when you choose `github` (other sections of the file are kept), and
`node "$TRACKER" config` prints what is in effect. `gh` targets the repo of the current
directory's git remote; there is no override. This doc ships with the tracker CLI in
`.coding-crew/tracker/docs/` and is refreshed by every install — edit `config.json`, not this file.

## Tracker CLI

Skills and crew-afk read and write this tracker only through the tracker CLI, which runs `gh`
for them. To run an op by hand, from the repo root (needs Node and an authenticated `gh`):

```bash
TRACKER="$(git rev-parse --show-toplevel)/.coding-crew/tracker/cli.mjs"
[ -f "$TRACKER" ] || TRACKER="$HOME/.coding-crew/tracker/cli.mjs"   # user-level install
```

```bash
node "$TRACKER" fetch <number> [--comments]               # print one issue (title, body; + comments)
node "$TRACKER" features                                  # list the features: <slug>, open|closed, ready-for-agent count
node "$TRACKER" prd --feature-slug <slug>                 # print the milestone's PRD: issue
node "$TRACKER" known --feature-slug <slug> --out <dir>   # write the milestone's issues, open and closed, into <dir>
node "$TRACKER" publish-issues --feature-slug <slug> --drafts <dir> [--replace]
node "$TRACKER" publish-prd --feature-slug <slug> --title "<feature title>" --body-file <file>
node "$TRACKER" rewrite <number> --body-file <file> --status <status> --feature-slug <slug>
node "$TRACKER" mark-done <number> [--force]
```

Exit codes, every op: `0` ok, `1` the op failed (stderr carries `gh`'s own error, verbatim), `2` a
usage error or a ref that is not an issue number, `3` not found.

`features` prints one tab-separated line per milestone, open and closed, sorted by title: the
milestone title (the feature slug), its state (`open` or `closed`) and the count of its open
`ready-for-agent` issues. A failing `gh` exits `1` with `gh`'s stderr verbatim.

`publish-issues`, `publish-prd` and `rewrite` file their issues under the milestone named for the feature slug, creating
the milestone — or reopening a closed one — first. `publish-issues` creates one issue per draft,
labelled by its `Status:` line, in dependency order, rewriting each draft's `## Blocked by` to
`Issue #<n>` with the number its blocker got and mirroring those edges as native GitHub
dependencies (best-effort: a failed link only warns; dispatch reads the body's `## Blocked by`).
A milestone only accumulates, so it never exits `4` or `5`. `publish-prd` creates the
`PRD: <feature title>` issue, or edits the milestone's existing one, then best-effort pins it
(GitHub caps pinned issues at 3 a repo, so a pin failure only warns). Work issues cite it as
`PRD: #<n>`. `rewrite` replaces a single-slice source issue's body and swaps `needs-triage` for
`<status>`.

`done` means implemented and merged into the feature branch, not shipped. `mark-done` re-fetches
the body live and refuses with exit `4` while an `- [ ]` in `## Acceptance criteria` (or
`## Cross-cutting Requirements`) is unchecked, or exit `3` when an orchestrator owns the close —
report your status and stop in either case. Never close the issue by hand instead.

On success `mark-done` swaps `ready-for-agent` for `awaiting-merge` (creating that label if the repo
lacks it) and leaves the issue **open**. Put `Closes #<number>` in the body of the PR that
carries the work: GitHub closes the issue when that PR merges into the default branch. With
`afk.openPr: true` (or `--open-pr`) crew-afk pushes the feature branch and opens or updates that
PR itself, writing these lines for every `awaiting-merge` issue in the milestone, plus `Closes #<prd>` for the
`PRD:` issue once no open work issue is left in it; without it,
the end-of-sprint summary prints them for you to paste. (A PR into any other branch does not
trigger the keyword — close those by hand.)

GitHub only closes an issue whose `Closes #n` line it linked when the PR was opened, and it can
fail to link one. So crew-afk does not rely on it: right after taking the feature lease, each run
runs `close-shipped.sh <feature-slug> <feature-branch>`, which reads the bodies of the feature
branch's PRs merged into the default branch itself and closes (`completed`, with a comment naming
the PR) every open `awaiting-merge` issue in the milestone that a closing keyword names — `#n`,
`owner/repo#n` or the issue URL. Once no open work issue is left in the milestone it closes the
`PRD:` issue too. The milestone stays open. Run it by hand from the repo root to close them right
after a merge: `bash .claude/skills/crew-afk/scripts/close-shipped.sh <feature-slug> <feature-branch>`
(the skill's install path varies by platform). A failure only warns.

## Reopen an issue

To undo `mark-done` (or put a finished issue back in a human's hands), swap the labels:

```bash
gh issue edit <number> --remove-label awaiting-merge --add-label ready-for-human
```

Use `ready-for-agent` instead of `ready-for-human` to hand it to crew-afk again. An issue already
closed by its merged PR is reopened first: `gh issue reopen <number>`.

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

Statuses other than `done` are labels a person sets in GitHub; `wontfix` closes the issue with a
reason instead of setting a label:

```bash
gh issue close <number> --reason not-planned   # wontfix
```

## In-progress issues

While a crew-afk run works an issue it carries the `in-progress` label, so a human on GitHub can
see it. It is **display only**: the feature lease, not this label, decides what is dispatched, and
a human adding or removing it changes nothing. The run adds it when it claims the issue (before the
worker is dispatched) and removes it when the issue merges — in the same `gh issue edit` that adds
`awaiting-merge` (`mark-done` does this; running it by hand on an issue without the label still
succeeds) — or is blocked (swapped for `blocked`). An issue the run still holds at its end
(partial, round cap, stall) is released before the summary. A `## Requires` failure is
never labelled. The new holder of a feature's lease also removes `in-progress` from every issue in
the milestone right after acquiring it: only a dead run can have left one. A failed label write only
warns.

## Feature lease ref namespace

The feature lease is a ref `refs/crew-lock/<feature-slug>` on `origin`, pointing at an annotated
tag. **Verified live against github.com (2026-09-30):** GitHub accepts create, compare-and-swap
reclaim and compare-and-swap delete of an annotated tag pushed to `refs/crew-lock/<slug>`, and
rejects a stale-sha reclaim or delete, so no fallback is needed there. To re-check (it pushes and
deletes a throwaway ref on `origin`, so it is opt-in):

```bash
CREW_LEASE_LIVE=1 scripts/verify-lease-live.sh     # or: CREW_LEASE_LIVE=1 bats tests/crew-afk-lease.bats
```

A host or ruleset that refuses the namespace makes `lease.sh` exit 4 and the acquire error says so
and names the fallback: `export CREW_LEASE_NAMESPACE=refs/tags/crew-lock` (read by `lease.sh` and
`lease.mjs` alike; the manual release command follows it).

## Blocked issues

When crew-afk stops on an issue that needs a human (retry limit, cost limit, not fixable, an
environment criterion, a dirty main tree, a review that did not run), it posts a `## Blocked`
comment and adds the `blocked` label **next to** `ready-for-agent` (creating the label if the
repo lacks it). Every later run skips an issue labelled `blocked`, and issues whose
`## Blocked by` names it keep waiting — `blocked` is not `done`. A failed label write only warns.
A failed `## Requires` probe is not labelled; it is re-probed every run.

To put a blocked issue back in the queue, once its cause is fixed:

```bash
gh issue edit <number> --remove-label blocked
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
