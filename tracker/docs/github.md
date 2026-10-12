# Issue tracker: GitHub Issues

Issues, PRDs, and features live as GitHub Issues: a feature is one root issue and its sub-issues
(see [Workspace](#workspace)). Requires the `gh` CLI (2.102 or later, for `--parent`),
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
node "$TRACKER" prd --feature-slug <slug>                 # print the feature's PRD: issue
node "$TRACKER" known --feature-slug <slug> --out <dir>   # write the feature's issues, open and closed, into <dir>
node "$TRACKER" publish-issues --feature-slug <slug> --drafts <dir> [--replace]
node "$TRACKER" publish-prd --feature-slug <slug> --title "<feature title>" --body-file <file>
node "$TRACKER" rewrite <number> --body-file <file> --status <status> --feature-slug <slug>
node "$TRACKER" mark-done <number> [--force]
node "$TRACKER" feature-issues --feature-slug <slug> [--state open|all]   # the feature's issues as JSON
```

Exit codes, every op: `0` ok, `1` the op failed (stderr carries `gh`'s own error, verbatim), `2` a
usage error or a ref that is not an issue number, `3` not found.

A `gh` call that fails on the network or GitHub's side — `EOF`, a connection reset or refused, a
DNS failure, a timeout, an `HTTP 5xx`, a secondary rate limit — is retried up to 3 times, after
1s, 2s and 4s (a warning line on stderr each time); past that the op fails with the last `gh`
error. Every other failure (auth, not found, a usage error) fails at once. A call that creates
something (`issue create`, `issue comment`, a `gh api` POST) is retried only when it failed
before the request was sent (a connection refused, DNS or TLS-handshake failure), so a retry
never files a duplicate.

`features` prints one tab-separated line per root issue's slug, sorted: the slug, `open` while the
root or any of its sub-issues is open (`closed` otherwise) and the count of open `ready-for-agent`
issues among the root and its sub-issues. A slug on more than one root is listed once, with a
warning on stderr. A closed root whose sub-issues have all closed is listed from its
`sub_issues_summary` without reading them. A failing `gh` exits `1` with `gh`'s stderr verbatim.

`publish-issues`, `publish-prd` and `rewrite` file their issues in the feature: the first issue
filed for a slug with no root becomes its root (the CLI adds the `Feature:` line), and every later
one is created as a sub-issue of that root (`gh issue create --parent <root>`). A closed root is
never reopened; new issues are filed under it as it is. `publish-issues` creates one issue per
draft, labelled by its `Status:` line, in dependency order, rewriting each draft's `## Blocked by`
to `Issue #<n>` with the number its blocker got and mirroring those edges as native GitHub
dependencies (best-effort: a failed link only warns; dispatch reads the body's `## Blocked by`).
A feature's issues only accumulate, so it never exits `4` or `5`. `publish-prd` creates the
`PRD: <feature title>` issue — as the root when the slug has none, else as a sub-issue of the
root — or edits the feature's existing one, keeping its `Feature:` line. It pins nothing: the
root's sub-issue progress bar is the feature's overview. Work issues cite it as `PRD: #<n>`.
`rewrite` replaces a single-slice source issue's body, sets `<status>` as its only triage label
(it replaces any other triage label the issue carries: `needs-triage`, `needs-info`,
`ready-for-agent`, `ready-for-human`) and files it in the feature: as its root when the slug has
none (the `Feature:` line added, and kept on every later rewrite of the root), else under the
root with `gh issue edit --parent`. It exits `1`, editing nothing, when the issue is already a
sub-issue of another issue or carries another slug's `Feature:` line: it never moves an issue out
of another feature. One exception: an issue that becomes the root keeps a parent with no
`Feature:` line (a human's epic, say), since making it the root moves nothing.

`feature-issues` prints the feature's issues — the root and its sub-issues, all of them or only
the open ones — as one JSON array of `{number, title, state, labels}`, `[]` for a slug with no
root. `close-shipped.sh` and `issue-labels.sh sweep` read a feature only through it.

Every op that reads a feature exits `1` naming them when its slug is ambiguous: two open issues
carrying the same `Feature:` line, or none open and two or more closed. Remove the line from all
but one of them.

`done` means implemented and merged into the feature branch, not shipped. `mark-done` re-fetches
the body live and refuses with exit `4` while an `- [ ]` in `## Acceptance criteria` (or
`## Cross-cutting Requirements`) is unchecked, or exit `3` when an orchestrator owns the close —
report your status and stop in either case. Never close the issue by hand instead.

On success `mark-done` swaps `ready-for-agent` for `awaiting-merge` (creating that label if the repo
lacks it) and leaves the issue **open**. Put `Closes #<number>` in the body of the PR that
carries the work: GitHub closes the issue when that PR merges into the default branch. With
`afk.openPr: true` (or `--open-pr`) crew-afk pushes the feature branch and opens or updates that
PR itself, writing these lines for every open `awaiting-merge` issue of the feature, plus `Closes #<prd>` for the
`PRD:` issue once no open work issue is left in it; without it,
the end-of-sprint summary prints them for you to paste. (A PR into any other branch does not
trigger the keyword — close those by hand.)

GitHub only closes an issue whose `Closes #n` line it linked when the PR was opened, and it can
fail to link one. So crew-afk does not rely on it: right after taking the feature lease, each run
runs `close-shipped.sh <feature-slug> <feature-branch>`, which reads the bodies of the feature
branch's PRs merged into the default branch itself and closes (`completed`, with a comment naming
the PR) every open `awaiting-merge` issue of the feature that a closing keyword names — `#n`,
`owner/repo#n` or the issue URL. Once no open work issue of the feature is left it closes the
`PRD:` issue too. A slug with no root has nothing to close (`SHIPPED: 0`). Run it by hand from the repo root to close them right
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
never labelled. The new holder of a feature's lease also removes `in-progress` from every issue of
the feature (the root and its sub-issues, open or closed) right after acquiring it: only a dead run can have left one. A failed label write only
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

A feature is one **root issue** and its native **sub-issues**, one level deep. The root is the
feature's `PRD:` issue, or for a single-slice feature the work issue itself; its body carries a
column-0 line naming the feature slug:

```
Feature: <slug>
```

The tracker CLI writes that line (on the issue it creates as a root, and on every rewrite or
re-publish of it) — never a skill — and finds a feature by it, scanning the repo's
issues through the REST list API (open ones first, then all), paginated. It scans once per process
(a crew-afk run reads its feature on every pass): later reads re-read the root it found, and scan
again only once that issue is gone or no longer carries the line. Slices, promoted
review-fix issues and integration-fix issues are all sub-issues of the root (`--parent <root>`).
A feature's issues are the root plus its sub-issues, read from
`repos/{owner}/{repo}/issues/<root>/sub_issues`, paginated, so no page is cut short; a slug with
no root reads as an empty feature. GitHub caps a parent at 100 sub-issues: past that, filing
another issue in the feature fails (`gh issue create --parent` exits non-zero), so close the
feature and start a new slug well before it. The PRD is identified by title convention
(`PRD: <feature title>`), not a local file, whether it is the root or a sub-issue of a work-issue
root. Work issues use the same markdown body conventions as local issues (`## Blocked by`,
`## Acceptance criteria`, `## Requires`, `Source:`).
`## Requires` is one backticked shell command per bullet, exit 0 = satisfied, naming what the
issue's checks need that the install does not guarantee; crew-afk runs each once, from the
project root, before the issue's first dispatch, and a failing one blocks the issue.

No filename exists to derive a slug or branch from, so both are derived deterministically from
the issue every time: kebab-case the title for the slug, and include the issue number in the
branch name for uniqueness: `crew/<featureSlug>/<number>-<slug>`. Nothing to cache — GitHub
issue numbers are stable, unambiguous identifiers, unlike local filenames.

Comments and conversation history append to the issue as ordinary `gh issue comment` timeline
entries — a live activity feed, not an in-place-edited section like local's `## Comments`.

## Moving off milestones

Earlier versions grouped a feature under a GitHub milestone named for its slug. That is gone, with
no fallback read: after `install.sh --update`, a feature still filed under a milestone is invisible
to crew-afk (it reads as empty) until you move it by hand. For each feature still in progress:

1. Pick its root — the `PRD:` issue, or for a single-slice feature the work issue — and add the
   slug line to the root's body, on a line of its own at column 0:

   ```
   Feature: <slug>
   ```

2. Make every issue of the milestone a sub-issue of the root — closed ones too, not just open
   ones: a `## Blocked by` issue resolves only when it is in the feature and `done`, so an open
   issue whose blocker closed but was left behind stays blocked forever:

   ```bash
   gh issue list --milestone <slug> --state all --limit 1000 --json number -q '.[].number' |
     while read -r n; do [ "$n" = <root> ] || gh issue edit "$n" --parent <root>; done
   ```

3. Close the milestone (on GitHub: Issues → Milestones → Close), so it stops collecting issues.

`node "$TRACKER" feature-issues --feature-slug <slug>` then lists the root and every issue you
moved; `node "$TRACKER" features` lists the slug.
